# benchmark.ps1 — Benchmark llama-server on Windows (Intel N150)
#
# Tests token generation speed using the OpenAI-compatible API.
# Uses curl.exe (not Invoke-WebRequest) because WSL2 interop can't reach
# localhost from PowerShell.
#
# Usage (in PowerShell):
#   .\benchmark.ps1                      # Run all tests
#   .\benchmark.ps1 -Testask        # Test --ask mode only
#   .\benchmark.ps1 -TestMode chat        # Test --chat mode only
#   .\benchmark.ps1 -Iterations 5         # 5 iterations per test (default: 3)
#   .\benchmark.ps1 -OutputFile results.json

param(
    [ValidateSet("all", "ask", "chat", "speed")]
    [string]$TestMode = "all",
    [int]$Iterations = 3,
    [string]$OutputFile = "benchmark_results.json",
    [string]$ServerPath = "C:\Users\Paul\llama-b10242\llama-server.exe",
    [string]$ModelPath = "C:\Users\Paul\turbo-fieldfare\models\gemma-4-26B-A4B-it.Q4_0.gguf",
    [int]$Port = 9090
)

$ErrorActionPreference = "Stop"

# --- Request payloads ---
$askRequest = @'
{"model":"gemma-4-26b-a4b-it","messages":[{"role":"user","content":"What is the capital of France? Explain briefly."}],"max_tokens":128,"stream":false}
'@

$chatRequest = @'
{"model":"gemma-4-26b-a4b-it","messages":[{"role":"user","content":"Write a short Python function to calculate factorial."}],"max_tokens":256,"stream":false}
'@

$codeRequest = @'
{"model":"gemma-4-26b-a4b-it","messages":[{"role":"user","content":"Write a Python class called Stack with push, pop, and peek methods."}],"max_tokens":256,"stream":false}
'@

# --- Helper: start server ---
function Start-Server {
    param([string]$ExtraArgs = "")
    $opts = "-m `"$ModelPath`" -ngl 0 -c 4096 -t 3 --host 127.0.0.1 --port $Port -ctk q4_0 -ctv q4_0 -ub 128 -fa on --cpu-strict 1 --cpu-range 0-2 $ExtraArgs"
    Write-Host "Starting server: $ServerPath $Opts" -ForegroundColor Cyan
    $proc = Start-Process -FilePath $ServerPath -ArgumentList $Opts -PassThru -WindowStyle Hidden
    # Wait for server to be ready
    $ready = $false
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2
        try {
            $resp = curl.exe -s -m 3 "http://127.0.0.1:$Port/health" 2>$null
            if ($resp -match "ok") { $ready = $true; break }
        } catch {}
        if ($i % 5 -eq 0) { Write-Host "  Waiting for server... ($([int]$i * 2)s)" -ForegroundColor Gray }
    }
    if (-not $ready) { throw "Server failed to start" }
    Write-Host "Server ready." -ForegroundColor Green
    return $proc
}

# --- Helper: send request and measure ---
function Measure-Request {
    param([string]$JsonBody, [string]$Label)
    $bodyFile = "$env:TEMP\llama_bench_req.json"
    $respFile = "$env:TEMP\llama_bench_resp.json"
    Set-Content -Path $bodyFile -Value $JsonBody -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    curl.exe -s -m 120 -X POST "http://127.0.0.1:$Port/v1/chat/completions" `
      -H "Content-Type: application/json" `
      -d "@$bodyFile" -o $respFile | Out-Null
    $sw.Stop()
    $resp = Get-Content $respFile -Raw
    # Parse JSON for usage info
    $json = $resp | ConvertFrom-Json
    $usage = $json.usage
    $content = $json.choices[0].message.content
    $totalTokens = $usage.total_tokens
    $completionTokens = $usage.completion_tokens
    $promptTokens = $usage.prompt_tokens
    $elapsed = $sw.Elapsed.TotalSeconds
    $tokRate = [math]::Round($completionTokens / $elapsed, 2)
    [PSCustomObject]@{
        label = $Label
        prompt_tokens = $promptTokens
        completion_tokens = $completionTokens
        total_tokens = $totalTokens
        elapsed_seconds = [math]::Round($elapsed, 2)
        tokens_per_second = $tokRate
        response_preview = $content.Substring(0, [math]::Min(80, $content.Length))
    }
}

# --- Helper: kill server ---
function Stop-Server {
    param($Proc)
    if ($Proc -and -not $Proc.HasExited) {
        $Proc.Kill()
        $Proc.WaitForExit(5000) | Out-Null
    }
    # Also kill any lingering process
    taskkill /F /IM llama-server.exe 2>$null | Out-Null
}

# --- Results collection ---
$results = @()
$testId = [DateTime]::Now.ToString("yyyyMMdd_HHmmss")

# ===== Test 1: Default mode (warm + speculative) =====
if ($TestMode -in "all", "speed") {
    Write-Host ""
    Write-Host "=== Test 1: Default mode (speculative ON) ===" -ForegroundColor Yellow
    try {
        $proc = Start-Server "--spec-type ngram-mod --spec-ngram-mod-n-match 24 --spec-ngram-mod-n-min 48 --spec-ngram-mod-n-max 64 --spec-draft-n-max 4"
        for ($i = 1; $i -le $Iterations; $i++) {
            $r = Measure-Request $codeRequest "default_spec_run$i"
            Write-Host "  Run $i`: $($r.tokens_per_second) tok/s ($($r.completion_tokens) tokens in $($r.elapsed_seconds)s)" -ForegroundColor White
            $results += $r
        }
        Stop-Server $proc
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }
}

# ===== Test 2: Without speculative =====
if ($TestMode -in "all", "speed") {
    Write-Host ""
    Write-Host "=== Test 2: Speculative OFF ===" -ForegroundColor Yellow
    try {
        $proc = Start-Server ""
        for ($i = 1; $i -le $Iterations; $i++) {
            $r = Measure-Request $codeRequest "no_spec_run$i"
            Write-Host "  Run $i`: $($r.tokens_per_second) tok/s ($($r.completion_tokens) tokens in $($r.elapsed_seconds)s)" -ForegroundColor White
            $results += $r
        }
        Stop-Server $proc
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }
}

# ===== Test 3: --ask mode =====
if ($TestMode -in "all", "ask") {
    Write-Host ""
    Write-Host "=== Test 3: --ask mode (single-shot) ===" -ForegroundColor Yellow
    try {
        $proc = Start-Server ""
        $r = Measure-Request $askRequest "ask_single"
        Write-Host "  Result: $($r.tokens_per_second) tok/s — $($r.response_preview)..." -ForegroundColor White
        $results += $r
        Stop-Server $proc
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }
}

# ===== Test 4: Chat mode (multiple turns) =====
if ($TestMode -in "all", "chat") {
    Write-Host ""
    Write-Host "=== Test 4: Chat mode (multi-turn) ===" -ForegroundColor Yellow
    try {
        $proc = Start-Server ""
        $chatTurns = @(
            '{"model":"gemma-4-26b-a4b-it","messages":[{"role":"user","content":"Hello, who are you?"}],"max_tokens":64,"stream":false}',
            '{"model":"gemma-4-26b-a4b-it","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":32,"stream":false}',
            '{"model":"gemma-4-26b-a4b-it","messages":[{"role":"user","content":"Name three colors."}],"max_tokens":32,"stream":false}'
        )
        for ($i = 0; $i -lt $chatTurns.Count; $i++) {
            $r = Measure-Request $chatTurns[$i] "chat_turn$($i+1)"
            Write-Host "  Turn $($i+1): $($r.tokens_per_second) tok/s — $($r.response_preview)..." -ForegroundColor White
            $results += $r
        }
        Stop-Server $proc
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }
}

# ===== Summary =====
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Yellow
$grouped = $results | Group-Object { $_.label -replace '_\d+$', '' }
foreach ($g in $grouped) {
    $avg = ($g.Group | Measure-Object tokens_per_second -Average).Average
    $min = ($g.Group | Measure-Object tokens_per_second -Minimum).Minimum
    $max = ($g.Group | Measure-Object tokens_per_second -Maximum).Maximum
    Write-Host "  $($g.Name): avg=$([math]::Round($avg,2)) tok/s  min=$([math]::Round($min,2))  max=$([math]::Round($max,2))" -ForegroundColor Cyan
}

# --- Save results ---
$output = @{
    timestamp = $testId
    machine = $env:COMPUTERNAME
    model = $ModelPath
    tests = $results
}
$output | ConvertTo-Json -Depth 5 | Set-Content $OutputFile
Write-Host ""
Write-Host "Results saved to $OutputFile" -ForegroundColor Green
