# bench-flags.ps1 — Benchmark CLI flag combinations for max tok/s
# Tests CPU pinning, polling, memory locking, MoE flags, and priority
#
# Usage: powershell -ExecutionPolicy Bypass -File "C:\Users\Paul\bench-flags.ps1"

$ErrorActionPreference = "Stop"

$llamaDir = "C:\Users\Paul\llama-b10242"
$modelPath = "C:\Users\Paul\models\gemma-4-26B-A4B-it.Q4_0.gguf"
$llamaServer = "$llamaDir\llama-server.exe"
$serverHost = "127.0.0.1"
$serverPort = 8080

# Test configurations - building on winner -fa -ub 128
$tests = @(
    @{ Name="winner (fa+ub128)";       Extra="-fa -ub 128" },
    @{ Name="+ cpu-strict";            Extra="-fa -ub 128 --cpu-strict 1" },
    @{ Name="+ cpu-strict+prio2";      Extra="-fa -ub 128 --cpu-strict 1 --prio 2" },
    @{ Name="+ cpu-strict+poll100";    Extra="-fa -ub 128 --cpu-strict 1 --poll 100" },
    @{ Name="+ cpu-strict+no-perf";    Extra="-fa -ub 128 --cpu-strict 1 --no-perf" },
    @{ Name="+ cmoe";                  Extra="-fa -ub 128 -cmoe" },
    @{ Name="+ mlock";                 Extra="-fa -ub 128 -lm mlock" },
    @{ Name="+ all safe flags";        Extra="-fa -ub 128 --cpu-strict 1 --prio 2 --no-perf" },
    @{ Name="+ all safe + poll100";    Extra="-fa -ub 128 --cpu-strict 1 --prio 2 --poll 100 --no-perf" },
    @{ Name="+ all combos";            Extra="-fa -ub 128 --cpu-strict 1 --prio 2 --poll 100 --no-perf -cmoe" }
)

Write-Host "=== CLI Flag Optimization Benchmark ===" -ForegroundColor Cyan
Write-Host "Base: -fa -ub 128 (4.86 tok/s reference)"
Write-Host ""

function Start-Server {
    param([string]$extraFlags)
    $opts = "-m `"$modelPath`" -ngl 0 -c 16384 -t 3 --cpu-strict 1 --host $serverHost --port $serverPort -ctk q4_0 -ctv q4_0 $extraFlags"
    $proc = Start-Process -FilePath $llamaServer -ArgumentList $opts -PassThru -WindowStyle Hidden -RedirectStandardOutput "C:\Users\Paul\llama_flags.log" -RedirectStandardError "C:\Users\Paul\llama_flags_err.log"

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
        Write-Host "  ERROR: Server failed to start" -ForegroundColor Red
        try { Stop-Process -Id $proc.Id -Force } catch {}
        return $null
    }
    return $proc
}

function Measure-Throughput {
    $body = '{"prompt":"What is 2+2?","n_predict":32,"temperature":0}'

    # Warmup
    try {
        Invoke-WebRequest -Uri "http://${serverHost}:${serverPort}/completion" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 600 | Out-Null
    } catch {
        Write-Host "  ERROR: Warmup failed: $_" -ForegroundColor Red
        return $null
    }

    # Benchmark 3 requests
    $times = @()
    for ($r = 0; $r -lt 3; $r++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-WebRequest -Uri "http://${serverHost}:${serverPort}/completion" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 600
            $sw.Stop()
            $times += $sw.Elapsed.TotalSeconds
        } catch {
            Write-Host "  ERROR: Request $r failed: $_" -ForegroundColor Red
            return $null
        }
    }
    return ($times | Measure-Object -Average).Average
}

$results = @()

foreach ($test in $tests) {
    Write-Host "Testing: $($test.Name)..." -ForegroundColor Yellow
    Write-Host "  Flags: $($test.Extra)"

    $proc = Start-Server -extraFlags $test.Extra
    if (-not $proc) {
        $results += [PSCustomObject]@{ Config = $test.Name; Flags = $test.Extra; Status = "FAILED"; TokPerSec = 0 }
        continue
    }

    $avgTime = Measure-Throughput

    if ($null -eq $avgTime) {
        $results += [PSCustomObject]@{ Config = $test.Name; Flags = $test.Extra; Status = "ERROR"; TokPerSec = 0 }
    } else {
        $tokPerSec = [math]::Round(32 / $avgTime, 2)
        $results += [PSCustomObject]@{ Config = $test.Name; Flags = $test.Extra; Status = "OK"; TokPerSec = $tokPerSec }
        Write-Host "  -> $tokPerSec tok/s" -ForegroundColor Green
    }

    try { Stop-Process -Id $proc.Id -Force } catch {}
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
$results | Sort-Object -Property TokPerSec -Descending | Format-Table -AutoSize

$best = ($results | Where-Object { $_.Status -eq "OK" } | Sort-Object TokPerSec -Descending | Select-Object -First 1)
if ($best) {
    Write-Host "=== WINNER ===" -ForegroundColor Green
    Write-Host "Config: $($best.Config)" -ForegroundColor Green
    Write-Host "Flags: $($best.Flags)" -ForegroundColor Green
    Write-Host "Speed: $($best.TokPerSec) tok/s" -ForegroundColor Green
}
