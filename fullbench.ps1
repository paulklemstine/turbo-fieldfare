$uri = "http://127.0.0.1:8080/completion"
$body = '{"prompt":"What is 2+2?","n_predict":16,"temperature":0}'

# Check health first
try {
    $h = Invoke-WebRequest -Uri "http://127.0.0.1:8080/health" -TimeoutSec 5 -ErrorAction Stop
    Write-Host "Health: $($h.Content)"
} catch {
    Write-Host "Health check FAILED: $_"
    exit 1
}

# Warmup
Write-Host "Warmup..."
try {
    $r = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120
    Write-Host "Warmup done"
} catch {
    Write-Host "Warmup FAILED: $_"
    exit 1
}

# Benchmark
Write-Host "Benchmarking..."
$times = @()
for ($i = 1; $i -le 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120
    $sw.Stop()
    $ms = $sw.ElapsedMilliseconds
    $toksPerSec = [math]::Round(16 * 1000 / $ms, 2)
    $times += $ms
    Write-Host "Request $i : ${ms}ms = $toksPerSec tok/s"
}

$avg = ($times | Measure-Object -Average).Average
$avgToks = [math]::Round(16 * 1000 / $avg, 2)
$min = ($times | Measure-Object -Minimum).Minimum
$max = ($times | Measure-Object -Maximum).Maximum
Write-Host ""
Write-Host "=== Summary ==="
Write-Host "Average: $avgToks tok/s"
Write-Host "Best: $([math]::Round(16*1000/$min,2)) tok/s"
Write-Host "Worst: $([math]::Round(16*1000/$max,2)) tok/s"
