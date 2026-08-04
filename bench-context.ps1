# bench-context.ps1 — Benchmark different context sizes on Windows native
# Tests context sizes from 256 to 16384 to find the maximum usable
# based on available RAM and throughput tradeoffs.
#
# Usage: .\bench-context.ps1
# Assumes llama-server.exe and model are at default locations.

$ErrorActionPreference = "Stop"

$llamaDir = "C:\Users\Paul\llama-b10242"
$modelPath = "C:\Users\Paul\models\gemma-4-26B-A4B-it.Q4_0.gguf"
$llamaServer = "$llamaDir\llama-server.exe"
$serverHost = "127.0.0.1"
$serverPort = 8080
$threads = 3

# Context sizes to test
$contexts = @(256, 512, 1024, 2048, 4096, 8192, 16384)

Write-Host "=== Context Size Benchmark ===" -ForegroundColor Cyan
Write-Host "Model: $modelPath"
Write-Host "Threads: $threads"
Write-Host ""

function Start-Server {
    param([int]$ctx)
    $opts = "-m `"$modelPath`" -ngl 0 -c $ctx -t $threads --cpu-strict 1 --host $serverHost --port $serverPort -ctk q4_0 -ctv q4_0 -ub 256"
    Write-Host "  Starting server with context=$ctx..."
    $proc = Start-Process -FilePath $llamaServer -ArgumentList $opts -PassThru -WindowStyle Hidden -RedirectStandardOutput "C:\Users\Paul\llama_ctx.log" -RedirectStandardError "C:\Users\Paul\llama_ctx_err.log"

    # Wait for server to be ready
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri "http://${serverHost}:${serverPort}/health" -TimeoutSec 3 -ErrorAction Stop
            if ($resp.Content -match '"status":"ok"') {
                $ready = $true
                break
            }
        } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        Write-Host "  ERROR: Server failed to start for context=$ctx" -ForegroundColor Red
        try { Stop-Process -Id $proc.Id -Force } catch {}
        return $null
    }
    return $proc
}

function Measure-Throughput {
    # Warmup
    $body = '{"prompt":"What is 2+2?","n_predict":16,"temperature":0}'
    try {
        Invoke-WebRequest -Uri "http://${serverHost}:${serverPort}/completion" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 300 | Out-Null
    } catch {
        Write-Host "  ERROR: Warmup request failed: $_" -ForegroundColor Red
        return $null
    }

    # Benchmark 3 requests
    $times = @()
    for ($r = 0; $r -lt 3; $r++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-WebRequest -Uri "http://${serverHost}:${serverPort}/completion" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 300
            $sw.Stop()
            $times += $sw.Elapsed.TotalSeconds
        } catch {
            Write-Host "  ERROR: Benchmark request $r failed: $_" -ForegroundColor Red
            return $null
        }
    }
    return ($times | Measure-Object -Average).Average
}

$results = @()

foreach ($ctx in $contexts) {
    Write-Host "Testing context=$ctx..." -ForegroundColor Yellow

    $proc = Start-Server -ctx $ctx
    if (-not $proc) {
        $results += [PSCustomObject]@{ Context = $ctx; Status = "FAILED"; AvgTime = 0; EstTokPerSec = 0 }
        continue
    }

    $avgTime = Measure-Throughput

    if ($null -eq $avgTime) {
        $results += [PSCustomObject]@{ Context = $ctx; Status = "ERROR"; AvgTime = 0; EstTokPerSec = 0 }
    } else {
        # 16 tokens generated, avgTime seconds -> tok/s
        $tokPerSec = [math]::Round(16 / $avgTime, 2)
        $results += [PSCustomObject]@{ Context = $ctx; Status = "OK"; AvgTime = [math]::Round($avgTime, 2); EstTokPerSec = $tokPerSec }
        Write-Host "  -> $tokPerSec tok/s (avg $($avgTime.ToString("F2"))s)" -ForegroundColor Green
    }

    # Kill server
    try { Stop-Process -Id $proc.Id -Force } catch {}
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$okResults = $results | Where-Object { $_.Status -eq "OK" }
if ($okResults) {
    $maxCtx = ($okResults | Measure-Object -Property Context -Maximum).Maximum
    Write-Host "Maximum working context: $maxCtx" -ForegroundColor Green
    Write-Host ""
    Write-Host "Recommendation: Use context=$maxCtx for best balance of" -ForegroundColor Green
    Write-Host "context window and throughput on this hardware." -ForegroundColor Green
}
