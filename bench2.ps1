$ErrorActionPreference = "Stop"
$uri = "http://127.0.0.1:8080/completion"
$body = '{"prompt":"What is 2+2?","n_predict":16,"temperature":0}'

# Warmup
Write-Host "Warmup..."
Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120 | Out-Null
Write-Host "Done"

# Benchmark
$times = @()
for ($i = 1; $i -le 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120 | Out-Null
    $sw.Stop()
    $ms = $sw.ElapsedMilliseconds
    $toks = [math]::Round(16 * 1000 / $ms, 2)
    $times += $ms
    Write-Host "Request $i : ${ms}ms = $toks tok/s"
}

$avg = ($times | Measure-Object -Average).Average
Write-Host "AVG: $([math]::Round(16*1000/$avg,2)) tok/s"
