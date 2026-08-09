#!/usr/bin/env pwsh
# start-gpu.ps1 — Run Gemma 4 26B-A4B on NVIDIA/Windows, max-context-first.
# Usage: .\start-gpu.ps1 --ask "PROMPT" [--verbose]

param(
    [string]$ask = "",
    [switch]$verbose
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelPath = "E:\Models\gemma-4-26B-A4B-it.Q4_K_S.gguf"
$llamaServer = Join-Path $scriptDir "llama-server.exe"
$serverHost = "127.0.0.1"
$serverPort = 8080
$apiBase = "http://${serverHost}:${serverPort}/v1"

function V { param($m) if ($verbose) { Write-Host "  [$((Get-Date).ToString('HH:mm:ss'))] $m" -ForegroundColor DarkGray } }

V "script dir: $scriptDir"
V "ask param: [$ask]"

# --- Detect VRAM ---
$vramMB = 0
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $vramMB = [int](nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1)
}
V "VRAM: ${vramMB} MiB"

# --- Compute GPU layers (338 MiB/layer, 500 MiB overhead, 16K ctx default) ---
$perLayerMB = 338; $overheadMB = 500; $kvQ4Kib = 15; $contextTokens = 16384
if ($vramMB -gt 0) {
    $needKvMB = [math]::Floor($contextTokens * $kvQ4Kib / 1024)
    $gpuLayers = [math]::Max(1, [math]::Min(30, [math]::Floor(($vramMB - $overheadMB - $needKvMB) / $perLayerMB)))
} else {
    $gpuLayers = 0
}
$threads = [math]::Max(1, (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors - 1)
V "gpu layers: $gpuLayers | context: $contextTokens | threads: $threads"

# --- Start server ---
Get-Process -Name llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
V "starting server..."
$serverArgs = @('-m', $modelPath, '-ngl', "$gpuLayers", '-c', "$contextTokens", '-t', "$threads",
                '--host', $serverHost, '--port', "$serverPort", '--temp', '0',
                '-ctk', 'q4_0', '-ctv', 'q4_0', '-ub', '128', '-fa', 'on')
try {
    $serverProc = Start-Process -WindowStyle Hidden -FilePath $llamaServer -ArgumentList $serverArgs -PassThru -RedirectStandardOutput (Join-Path $scriptDir "llama_server.log") -RedirectStandardError (Join-Path $scriptDir "llama_server_err.log")
    V "server pid: $($serverProc.Id)"
} catch {
    Write-Error "Failed to start llama-server: $_"
    exit 1
}

# --- Wait for health ---
$ready = $false
for ($i = 0; $i < 120; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://${serverHost}:${serverPort}/health" -TimeoutSec 2 -UseBasicParsing
        if ($resp.Content -match '"status":"ok"') { $ready = $true; V "ready at $($i*2)s"; break }
    } catch { V "health check $i failed: $($_.Exception.Message)" }
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    Write-Error "Timed out waiting for server. Check $(Join-Path $scriptDir 'llama_server.log')"
    V "last log lines: $(Get-Content (Join-Path $scriptDir 'llama_server.log') -Tail 5 -ErrorAction SilentlyContinue)"
    exit 1
}

# --- Warmup ---
V "warming up expert cache..."
try {
    $warmBody = @{prompt="<start_of_turn>user`nHi<end_of_turn>`n<start_of_turn>model`n";n_predict=1;temperature=0;stream=$false} | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "${apiBase}/chat/completions" -Method Post -ContentType "application/json" -Body $warmBody | Out-Null
    V "warmup done"
} catch { V "warmup failed (non-fatal): $($_.Exception.Message)" }

# --- Query ---
if ($ask -ne "") {
    V "querying with prompt: $ask"
    $userContent = "<start_of_turn>user`n${ask}<end_of_turn>`n<start_of_turn>model`n"
    $qBody = @{model="gemma-4-26b-a4b-it";messages=@(@{role="user";content=$userContent});max_completion_tokens=4096;temperature=0.2;stream=$false;stop=@("<end_of_turn>")} | ConvertTo-Json -Depth 5 -Compress
    V "request body: $qBody"
    try {
        $result = Invoke-RestMethod -Uri "${apiBase}/chat/completions" -Method Post -ContentType "application/json" -Body $qBody -TimeoutSec 300
        V "response: $($result | ConvertTo-Json -Compress -Depth 3)"
        Write-Output $result.choices[0].message.content
    } catch {
        Write-Error "Query failed: $_"
        exit 1
    }
    exit 0
}

Write-Host "Server is ready at $apiBase. Press Ctrl+C to stop."
wait-process -Id $serverProc.Id
