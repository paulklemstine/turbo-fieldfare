# bench-speed.ps1 — Benchmark different speed optimization flags
# Tests Flash Attention, batch sizes, and thread counts to find max tok/s
#
# Usage: .\bench-speed.ps1

$ErrorActionPreference = "Stop"

$llamaDir = "C:\Users\Paul\llama-b10242"
$modelPath = "C:\Users\Paul\models\gemma-4-26B-A4B-it.Q4_0.gguf"
$llamaServer = "$llamaDir\llama-server.exe"
$serverHost = "127.0.0.1"
$serverPort = 8080

# Test configurations: description -> flags
$tests = @(
    @{ Name="baseline (current)";        Extra="" },
    @{ Name="flash-attention";           Extra="-fa" },
    @{ Name="fa + ub512";                Extra="-fa -ub 512" },
    @{ Name="fa + ub128";                Extra="-fa -ub 128" },
    @{ Name="fa + ub64";                 Extra="-fa -ub 64" },
    @{ Name="fa + b1024";                Extra="-fa -b 1024" },
    @{ Name="fa + b2048";                Extra="-fa -b 2048" },
    @{ Name="fa + b4096";                Extra="-fa -b 4096" },
    @{ Name="fa + b1024 + ub512";        Extra="-fa -b 1024 -ub 512" },
    @{ Name="fa + b2048 + ub256";        Extra="-fa -b 2048 -ub 256" }
)

Write-Host "=== Speed Optimization Benchmark ===" -ForegroundColor Cyan
Write-Host "Model: $modelPath"
Write-Host "Context: 16384, Threads: 3, KV: q4_0"
Write-Host ""

function Start-Server {
    param([string]$extraFlags)
    $opts = "-m `"$modelPath`" -ngl 0 -c 16384 -t 3 --cpu-strict 1 --host $serverHost --port $serverPort -ctk q4_0 -ctv q4_0 -ub 256 $extraFlags"
    Write-Host "  Starting server: $opts"
    $proc = Start-Process -FilePath $llamaServer -ArgumentList $opts -PassThru -WindowStyle Hidden -RedirectStandardOutput "C:\Users\Paul\llama_speed.log" -RedirectStandardError "C:\Users\Paul\llama_speed_err.log"

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
