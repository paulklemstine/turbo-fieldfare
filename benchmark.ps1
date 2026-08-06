# benchmark.ps1 — Benchmark llama-server on Windows (Intel N150)
#
# Tests token generation speed using the OpenAI-compatible API.
# Uses curl.exe (not Invoke-WebRequest) for localhost access.
#
# Usage (in PowerShell):
#   .\benchmark.ps1                         Run all tests
#   .\benchmark.ps1 -TestMode speed         Speed tests only
#   .\benchmark.ps1 -Iterations 5           5 iterations per test
#   .\benchmark.ps1 -OutputFile results.json

param(
    [ValidateSet("all", "ask", "chat", "speed")]
    [string]$TestMode = "all",
    [int]$Iterations = 3,
    [string]$OutputFile = "",
    [string]$ServerPath = "C:\Users\Paul\llama-b10242\llama-server.exe",
    [string]$ModelPath = "C:\Users\Paul\turbo-fieldfare\models\gemma-4-26B-A4B-it.Q4_0.gguf",
    [int]$Port = 9090
)

# Resolve output path relative to script directory
if (-not $OutputFile) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $OutputFile = Join-Path $scriptDir "benchmark_results.json"
}

$ErrorActionPreference = "Stop"

# --- Thermal cooldown helper ---
# The Intel N150 (6W TDP) thermal-throttles under sustained all-core load.
# Without cooldown, speed drops from ~14 tok/s (fresh) to ~2 tok/s (throttled).
# We pause between test blocks to let the chip cool, and we warn the user.
function Invoke-Cooldown {
    param([int]$Seconds = 30)
    Write-Host ""
    $msg = "Cooling down - $Seconds s"
    Write-Host "  $msg - N150 thermal recovery..." `
        -ForegroundColor DarkGray
    Start-Sleep -Seconds $Seconds
}

function Get-RequestJson {
    param([string]$Content, [int]$MaxTokens)
    $obj = @{
        model = "gemma-4-26b-a4b-it"
        messages = @(@{role = "user"; content = $Content})
        max_tokens = $MaxTokens
        stream = $false
    }
    return $obj | ConvertTo-Json -Compress -Depth 5
}

function Start-LlamaServer {
    param([string]$ExtraArgs = "")
    $argList = "-m `"$ModelPath`" -ngl 0 -c 4096 -t 3"
    $argList += " --host 127.0.0.1 --port $Port"
    $argList += " -ctk q4_0 -ctv q4_0 -ub 128 -fa on"
    $argList += " --cpu-strict 1 --cpu-range 0-2"
    if ($ExtraArgs) { $argList += " " + $ExtraArgs }
    Write-Host "Starting server..." -ForegroundColor Cyan
    Write-Host "  $ServerPath $argList" -ForegroundColor Gray
    $proc = Start-Process -FilePath $ServerPath `
        -ArgumentList $argList `
        -PassThru -WindowStyle Hidden
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 2
        try {
            $resp = curl.exe -s -m 3 `
                "http://127.0.0.1:$Port/health" 2>$null
            if ($resp -match "ok") {
                # Health endpoint OK but model may still be loading.
                # Send a test request to confirm model is ready.
                $testBody = '{"model":"x","messages":[{"role":"user","content":"hi"}],"max_tokens":1,"stream":false}'
                $testFile = "$env:TEMP\llama_warmup.json"
                Set-Content -Path $testFile -Value $testBody -NoNewline
                $testResp = curl.exe -s -m 10 `
                    -X POST "http://127.0.0.1:$Port/v1/chat/completions" `
                    -H "Content-Type: application/json" `
                    -d "@$testFile" 2>$null
                if ($testResp -match '"usage"') { $ready = $true; break }
            }
        } catch { }
        if ($i % 5 -eq 0) {
            $elapsed = $i * 2
            $w = "Waiting..."
            $msg = "$w $elapsed seconds"
            Write-Host "  $msg" -ForegroundColor Gray
        }
    }
    if (-not $ready) { throw "Server failed to start after 240s" }
    Write-Host "Server ready (model loaded)." -ForegroundColor Green
    return $proc
}

function Stop-LlamaServer {
    param($Proc)
    # Suppress all errors — taskkill writes to stderr which PowerShell
    # treats as a terminating error under $ErrorActionPreference = "Stop"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    if ($Proc -and -not $Proc.HasExited) {
        $Proc.Kill()
        $Proc.WaitForExit(5000) | Out-Null
    }
    # Force kill any remaining instances (only if running)
    $running = Get-Process llama-server -ErrorAction SilentlyContinue
    if ($running) {
        taskkill /F /IM llama-server.exe 2>&1 | Out-Null
    }
    $ErrorActionPreference = $prevEAP
    Start-Sleep -Seconds 2
    # Verify port is free
    $maxWait = 10
    for ($i = 0; $i -lt $maxWait; $i++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $Port)
            $tcp.Close()
            # Still connected means server still running
            Start-Sleep -Seconds 2
        } catch {
            break  # Port is free
        }
    }
}

function Measure-Request {
    param([string]$JsonBody, [string]$Label)
    $bodyFile = "$env:TEMP\llama_bench_req.json"
    $respFile = "$env:TEMP\llama_bench_resp.json"
    Set-Content -Path $bodyFile -Value $JsonBody -NoNewline
    # Build curl command as a batch file to avoid quoting issues
    $batchFile = "$env:TEMP\llama_curl.cmd"
    $batchContent = "@echo off`r`n"
    $batchContent += "curl.exe -s -m 180 "
    $batchContent += "-X POST `"http://127.0.0.1:$Port/v1/chat/completions`" "
    $batchContent += "-H `"Content-Type: application/json`" "
    $batchContent += "-d `"@$bodyFile`" "
    $batchContent += "-o `"$respFile`""
    Set-Content -Path $batchFile -Value $batchContent -NoNewline
    # Retry loop: server may return 503 "Loading model" briefly
    $maxRetries = 5
    $resp = ""
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        if (Test-Path $respFile) { Remove-Item $respFile -Force }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        cmd.exe /c "`"$batchFile`"" | Out-Null
        $sw.Stop()
        if (Test-Path $respFile) {
            $resp = Get-Content $respFile -Raw
            if ($resp -match '"usage"') { break }
        }
        if ($attempt -lt $maxRetries) {
            Write-Host "    Retry $attempt (model loading)..." -ForegroundColor Gray
            Start-Sleep -Seconds 5
        }
    }
    if (-not $resp -or $resp -notmatch '"usage"') {
        throw "Invalid response after $maxRetries attempts: $resp"
    }
    $json = $resp | ConvertFrom-Json
    $usage = $json.usage
    $content = $json.choices[0].message.content
    $compTokens = $usage.completion_tokens
    $elapsed = $sw.Elapsed.TotalSeconds
    $tokRate = [math]::Round($compTokens / $elapsed, 2)
    $previewLen = [math]::Min(80, $content.Length)
    return [PSCustomObject]@{
        label = $Label
        prompt_tokens = $usage.prompt_tokens
        completion_tokens = $compTokens
        total_tokens = $usage.total_tokens
        elapsed_seconds = [math]::Round($elapsed, 2)
        tokens_per_second = $tokRate
        response_preview = $content.Substring(0, $previewLen)
    }
}

function Run-TestBlock {
    param(
        [string]$Title,
        [scriptblock]$ScriptBlock
    )
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Yellow
    & $ScriptBlock
}

# --- Results collection ---
$results = [System.Collections.ArrayList]::new()
$testId = [DateTime]::Now.ToString("yyyyMMdd_HHmmss")

# --- Thermal throttling notice ---
Write-Host ""
Write-Host "NOTE: Intel N150 (6W TDP) thermal-throttles under sustained load." `
    -ForegroundColor DarkYellow
Write-Host "  Fresh/cool: ~14 tok/s | Throttled: ~2-4 tok/s" `
    -ForegroundColor DarkYellow
Write-Host "  Cooldown pauses between tests help recover peak speed." `
    -ForegroundColor DarkYellow
Write-Host "  For best results, run this benchmark right after a reboot." `
    -ForegroundColor DarkYellow

# ===== Test 1: Default mode (warm + speculative) =====
if ($TestMode -in "all", "speed") {
    Run-TestBlock "Test 1: Default mode (speculative ON)" {
        try {
            $specArgs = "--spec-type ngram-mod"
            $specArgs += " --spec-ngram-mod-n-match 24"
            $specArgs += " --spec-ngram-mod-n-min 48"
            $specArgs += " --spec-ngram-mod-n-max 64"
            $specArgs += " --spec-draft-n-max 4"
            $proc = Start-LlamaServer $specArgs
            for ($i = 1; $i -le $Iterations; $i++) {
                $req = Get-RequestJson "Write a Python Stack class" 256
                $r = Measure-Request $req "default_spec_run$i"
                Write-Host "  Run $i`: $($r.tokens_per_second) tok/s" `
                    -ForegroundColor White
                $null = $results.Add($r)
            }
            Stop-LlamaServer $proc
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
        }
    }
    Invoke-Cooldown 30
}

# ===== Test 2: Without speculative =====
if ($TestMode -in "all", "speed") {
    Run-TestBlock "Test 2: Speculative OFF" {
        try {
            $proc = Start-LlamaServer ""
            for ($i = 1; $i -le $Iterations; $i++) {
                $req = Get-RequestJson "Write a Python Stack class" 256
                $r = Measure-Request $req "no_spec_run$i"
                Write-Host "  Run $i`: $($r.tokens_per_second) tok/s" `
                    -ForegroundColor White
                $null = $results.Add($r)
            }
            Stop-LlamaServer $proc
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
        }
    }
    Invoke-Cooldown 30
}

# ===== Test 3: --ask mode =====
if ($TestMode -in "all", "ask") {
    Run-TestBlock "Test 3: Single-shot (--ask)" {
        try {
            $proc = Start-LlamaServer ""
            $req = Get-RequestJson `
                "What is the capital of France? Explain briefly." 128
            $r = Measure-Request $req "ask_single"
            Write-Host "  Result: $($r.tokens_per_second) tok/s" `
                -ForegroundColor White
            Write-Host "  $($r.response_preview)..." -ForegroundColor Gray
            $null = $results.Add($r)
            Stop-LlamaServer $proc
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
        }
    }
    Invoke-Cooldown 30
}

# ===== Test 4: Chat mode (multi-turn) =====
if ($TestMode -in "all", "chat") {
    Run-TestBlock "Test 4: Chat mode (multi-turn)" {
        try {
            $proc = Start-LlamaServer ""
            $turns = @(
                @{Q = "Hello, who are you?"; T = 64},
                @{Q = "What is 2+2?"; T = 32},
                @{Q = "Name three colors."; T = 32}
            )
            for ($i = 0; $i -lt $turns.Count; $i++) {
                $req = Get-RequestJson $turns[$i].Q $turns[$i].T
                $r = Measure-Request $req "chat_turn$($i+1)"
                Write-Host "  Turn $($i+1): $($r.tokens_per_second) tok/s" `
                    -ForegroundColor White
                Write-Host "  $($r.response_preview)..." -ForegroundColor Gray
                $null = $results.Add($r)
            }
            Stop-LlamaServer $proc
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
        }
    }
    Invoke-Cooldown 30
}

# ===== Summary =====
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Yellow
$grouped = $results | Group-Object {
    $_.label -replace '_\d+$', ''
}
foreach ($g in $grouped) {
    $avg = ($g.Group |
        Measure-Object tokens_per_second -Average).Average
    $min = ($g.Group |
        Measure-Object tokens_per_second -Minimum).Minimum
    $max = ($g.Group |
        Measure-Object tokens_per_second -Maximum).Maximum
    Write-Host ("  {0}: avg={1} tok/s  min={2}  max={3}" -f
        $g.Name,
        [math]::Round($avg, 2),
        [math]::Round($min, 2),
        [math]::Round($max, 2)
    ) -ForegroundColor Cyan
}

# --- Save results ---
$output = @{
    timestamp = $testId
    machine   = $env:COMPUTERNAME
    model     = $ModelPath
    tests     = $results
}
$output | ConvertTo-Json -Depth 5 | Set-Content $OutputFile
Write-Host ""
Write-Host "Results saved to $OutputFile" -ForegroundColor Green
