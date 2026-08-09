#!/usr/bin/env pwsh
# start-gpu.ps1 — Run Gemma 4 26B-A4B on NVIDIA/Windows, max-context-first.
# Usage: .\start-gpu.ps1 --ask "PROMPT"

param([string]$ask = "")

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelPath = "E:\Models\gemma-4-26B-A4B-it.Q4_K_S.gguf"
$llamaServer = Join-Path $scriptDir "llama-server.exe"
$serverHost = "127.0.0.1"
$serverPort = 8080
$apiBase = "http://${serverHost}:${serverPort}/v1"

# --- Detect VRAM ---
$vramMB = 0
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $vramMB = [int](nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1)
}

# --- Compute GPU layers (338 MiB/layer, 500 MiB overhead, 16K ctx default) ---
$perLayerMB = 338; $overheadMB = 500; $kvQ4Kib = 15; $contextTokens = 16384
if ($vramMB -gt 0) {
    $needKvMB = [math]::Floor($contextTokens * $kvQ4Kib / 1024)
    $gpuLayers = [math]::Max(1, [math]::Min(30, [math]::Floor(($vramMB - $overheadMB - $needKvMB) / $perLayerMB)))
} else { $gpuLayers = 0 }
$threads = [math]::Max(1, (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors - 1)

Write-Host "=== Gemma 4 GPU Launcher ===" -ForegroundColor Cyan
Write-Host "  VRAM: ${vramMB} MiB | GPU layers: $gpuLayers | Context: ${contextTokens} tok | Threads: $threads"

# --- Start server ---
Write-Host "Starting llama-server ..." -ForegroundColor Yellow
Get-Process -Name llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

$serverArgs = @('-m', $modelPath, '-ngl', "$gpuLayers", '-c', "$contextTokens", '-t', "$threads",
                '--host', $serverHost, '--port', "$serverPort", '--temp', '0',
                '-ctk', 'q4_0', '-ctv', 'q4_0', '-ub', '128', '-fa', 'on')
try {
    $proc = Start-Process -WindowStyle Hidden -FilePath $llamaServer -ArgumentList $serverArgs -PassThru -RedirectStandardOutput (Join-Path $scriptDir "llama_server.log") -RedirectStandardError (Join-Path $scriptDir "llama_server_err.log")
    Write-Host "  server pid: $($proc.Id)" -ForegroundColor Gray
} catch {
    Write-Host "ERROR: Failed to start server: $_" -ForegroundColor Red
    exit 1
}

# --- Wait for health ---
Write-Host "Loading model (first run takes ~90s)..." -ForegroundColor Yellow
$ready = $false
for ($i = 0; $i -lt 180; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://${serverHost}:${serverPort}/health" -TimeoutSec 2
        if ($resp.Content -match '"status":"ok"') { $ready = $true; break }
    } catch { }
    if ($i % 5 -eq 0) { Write-Host "  waiting... (${$i*2}s)" -ForegroundColor Gray }
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    Write-Host "ERROR: Server did not become ready. Check llama_server.log" -ForegroundColor Red
    exit 1
}
Write-Host "  server ready." -ForegroundColor Green

# --- Warmup ---
Write-Host "Warming up expert cache..." -ForegroundColor Yellow
try {
    $w = @{prompt="<start_of_turn>user`nHi<end_of_turn>`n<start_of_turn>model`n";n_predict=1;temperature=0;stream=$false} | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "${apiBase}/chat/completions" -Method Post -ContentType "application/json" -Body $w | Out-Null
} catch { }

# --- Query ---
if ($ask -ne "") {
    Write-Host "Asking: $ask" -ForegroundColor Yellow
    $u = "<start_of_turn>user`n${ask}<end_of_turn>`n<start_of_turn>model`n"
    $body = @{model="gemma-4-26b-a4b-it";messages=@(@{role="user";content=$u});max_completion_tokens=4096;temperature=0.2;stream=$false;stop=@("<end_of_turn>")} | ConvertTo-Json -Depth 5 -Compress
    try {
        $r = Invoke-RestMethod -Uri "${apiBase}/chat/completions" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 300
        Write-Host "=== ANSWER ===" -ForegroundColor Green
        Write-Output $r.choices[0].message.content
    } catch {
        Write-Host "ERROR: Query failed: $_" -ForegroundColor Red
        exit 1
    }
    exit 0
}

Write-Host "Server is ready at $apiBase. Press Ctrl+C to stop." -ForegroundColor Cyan
wait-process -Id $proc.Id
