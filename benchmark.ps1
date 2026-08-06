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
    [string]$OutputFile = "benchmark_results.json",
    [string]$ServerPath = "C:\Users\Paul\llama-b10242\llama-server.exe",
    [string]$ModelPath = "C:\Users\Paul\turbo-fieldfare\models\gemma-4-26B-A4B-it.Q4_0.gguf",
    [int]$Port = 9090
)

$ErrorActionPreference = "Stop"

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
    $argList = @(
        "-m", "`"",
        $ModelPath,
        "`"",
        "-ngl", "0",
        "-c", "4096",
        "-t", "3",
        "--host", "127.0.0.1",
        "--port", $Port,
        "-ctk", "q4_0",
        "-ctv", "q4_0",
        "-ub", "128",
        "-fa", "on",
        "--cpu-strict", "1",
        "--cpu-range", "0-2"
    ) -join " "
    if ($ExtraArgs) { $argList += " " + $ExtraArgs }
    Write-Host "Starting server..." -ForegroundColor Cyan
    Write-Host "  $ServerPath $argList" -ForegroundColor Gray
    $proc = Start-Process -FilePath $ServerPath `
        -ArgumentList $argList `
        -PassThru -WindowStyle Hidden
    $ready = $false
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2
        try {
            $resp = curl.exe -s -m 3 `
                "http://127.0.0.1:$Port/health" 2>$null
            if ($resp -match "ok") { $ready = $true; break }
        } catch { }
        if ($i % 5 -eq 0) {
            Write-Host "  Waiting... ($([int]$i * 2)s)" -ForegroundColor Gray
        }
    }
    if (-not $ready) { throw "Server failed to start after 180s" }
    Write-Host "Server ready." -ForegroundColor Green
    return $proc
}

function Stop-LlamaServer {
    param($Proc)
    if ($Proc -and -not $Proc.HasExited) {
        $Proc.Kill()
        $Proc.WaitForExit(5000) | Out-Null
    }
    taskkill /F /IM llama-server.exe 2>$null | Out-Null
}

function Measure-Request {
    param([string]$JsonBody, [string]$Label)
    $bodyFile = "$env:TEMP\llama_bench_req.json"
    $respFile = "$env:TEMP\llama_bench_resp.json"
    Set-Content -Path $bodyFile -Value $JsonBody -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $curlArgs = @(
        "-s", "-m", "120",
        "-X", "POST",
        "http://127.0.0.1:$Port/v1/chat/completions",
        "-H", "Content-Type: application/json",
        "-d", "@$bodyFile",
        "-o", $respFile
    )
    & curl.exe @curlArgs | Out-Null
    $sw.Stop()
    $resp = Get-Content $respFile -Raw
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
$results = @()
$testId = [DateTime]::Now.ToString("yyyyMMdd_HHmmss")

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
                $results += $r
            }
            Stop-LlamaServer $proc
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
        }
    }
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
                $results += $r
            }
            Stop-LlamaServer $proc
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
        }
    }
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
            $results += $r
            Stop-LlamaServer $proc
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
        }
    }
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
                $results += $r
            }
            Stop-LlamaServer $proc
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
        }
    }
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
