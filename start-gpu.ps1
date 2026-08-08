#!/usr/bin/env pwsh
# start-gpu.ps1 — Run Gemma 4 26B-A4B on NVIDIA/Windows, max-context-first.
# Usage: .\start-gpu.ps1 --ask "PROMPT" | --chat | (none = Pi agent)

param(
    [switch]$chat,
    [string]$ask = "",
    [switch]$cpu,
    [switch]$debug
)

$ErrorActionPreference = "Stop"

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

# --- Compute GPU layers (measured: 338 MiB/layer, 500 MiB overhead) ---
$perLayerMB = 338
$overheadMB = 500
$nativeCtx = 262144
$kvQ4Kib = 15

if ($cpu) {
    $gpuLayers = 0
} elseif ($vramMB -gt 0) {
    $needKvMB = [math]::Floor($nativeCtx * $kvQ4Kib / 1024)
    $layerBudgetMB = $vramMB - $overheadMB - $needKvMB
    $gpuLayers = [math]::Floor($layerBudgetMB / $perLayerMB)
    if ($gpuLayers -gt 30) { $gpuLayers = 30 }
    if ($gpuLayers -lt 1) { $gpuLayers = 1 }
} else {
    $gpuLayers = 0
}

$contextTokens = $nativeCtx
$threads = [math]::Max(1, (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors - 1)

# --- Quiet mode ---
$quiet = ($ask -ne "")

if (-not $quiet) {
    Write-Host "============================================================"
    Write-Host " llama.cpp + Gemma 4  (Windows Native + CUDA GPU)"
    Write-Host "============================================================"
    Write-Host "   backend:    $llamaServer"
    Write-Host "   model:      $modelPath"
    Write-Host "   gpu layers: $gpuLayers  |  context: $contextTokens tok  |  threads: $threads"
    Write-Host "============================================================"
}

# --- Kill existing + start server ---
Get-Process -Name llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

if (-not $quiet) { Write-Host "Launching llama-server ..." }

$serverArgs = @('-m', $modelPath, '-ngl', "$gpuLayers", '-c', "$contextTokens", '-t', "$threads",
                '--host', $serverHost, '--port', "$serverPort", '--temp', '0',
                '-ctk', 'q4_0', '-ctv', 'q4_0', '-ub', '128', '-fa', 'on')

$serverProc = Start-Process -WindowStyle Hidden -FilePath $llamaServer -ArgumentList $serverArgs -PassThru -RedirectStandardOutput (Join-Path $scriptDir "llama_server.log") -RedirectStandardError (Join-Path $scriptDir "llama_server_err.log")

# --- Wait for health ---
if (-not $quiet) { Write-Host "Loading model weights ..." }
$ready = $false
for ($i = 0; $i -lt 180; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://${serverHost}:${serverPort}/health" -TimeoutSec 2 -UseBasicParsing
        if ($resp.Content -match '"status":"ok"') { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    Write-Error "Timed out waiting for llama-server to be ready. Check $(Join-Path $scriptDir 'llama_server.log')"
    exit 1
}

# --- Warmup inference (heat expert cache) ---
if (-not $quiet) { Write-Host "Warming up expert cache ..." }
try {
    $body = @{prompt="The";n_predict=1;temperature=0;stream=$false} | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "${apiBase}/completion" -Method Post -ContentType "application/json" -Body $body | Out-Null
} catch { }

if (-not $quiet) { Write-Host "Server ready on port $serverPort." }

# --- Handle modes ---
if ($ask -ne "") {
    # Gemma 4 expects the chat-template format. Apply it manually so the
    # abliterated GGUF (which may lack an embedded template) behaves.
    $prompt = "<start_of_turn>user`n${ask}<end_of_turn>`n<start_of_turn>model`n"
    $body = @{prompt=$prompt;max_completion_tokens=4096;temperature=0.2;stream=$false;stop=@("<end_of_turn>")} | ConvertTo-Json -Compress
    try {
        $result = Invoke-RestMethod -Uri "${apiBase}/completion" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 180
        Write-Output $result.content
    } catch {
        Write-Error "Query failed: $_"
        exit 1
    }
    exit 0
}

# Default: just leave server running
Write-Host "Server is ready at $apiBase. Press Ctrl+C to stop."
wait-process -Id $serverProc.Id
