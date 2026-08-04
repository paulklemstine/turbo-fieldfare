param(
    [string]$Name,
    [string]$ServerArgs
)

$logFile = "\\wsl.localhost\Ubuntu\home\raver1975\turbo-fieldfare\experiment_$Name.log"
$serverPath = "C:\Users\Paul\llama-b10242\llama-server.exe"

Write-Host "=== Experiment: $Name ==="
Write-Host "Args: $ServerArgs"

# Start server
$proc = Start-Process -FilePath $serverPath -ArgumentList $ServerArgs -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" -PassThru -NoNewWindow
Write-Host "Server PID: $($proc.Id)"

# Wait for ready
$ready = $false
for ($i = 1; $i -le 120; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:8080/health" -TimeoutSec 2
        if ($r.Content -match "ok") {
            $ready = $true
            Write-Host "Server ready after ${i}s"
            break
        }
    } catch {}
}

if (-not $ready) {
    Write-Host "FAILED: Server did not start"
    $proc.Kill()
    exit 1
}

# Benchmark
$uri = "http://127.0.0.1:8080/completion"
$body = '{"prompt":"What is 2+2?","n_predict":16,"temperature":0}'
$times = @()

# Warmup
Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120 | Out-Null

for ($j = 1; $j -le 5; $j++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120 | Out-Null
    $sw.Stop()
    $times += $sw.ElapsedMilliseconds
}

# Kill server
$proc.Kill()
Start-Sleep -Seconds 2

# Report
$avg = ($times | Measure-Object -Average).Average
$min = ($times | Measure-Object -Minimum).Minimum
$avgToks = [math]::Round(16 * 1000 / $avg, 2)
$bestToks = [math]::Round(16 * 1000 / $min, 2)
Write-Host "RESULT: $Name : avg=${avgToks} tok/s (best=$bestToks, avg_ms=$([math]::Round($avg)))"
Write-Host ""
