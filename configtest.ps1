param(
    [string]$Name = "default",
    [string]$ExtraArgs = ""
)

$uri = "http://127.0.0.1:8080/completion"
$body = '{"prompt":"What is 2+2?","n_predict":16,"temperature":0}'
$times = @()

# Warmup
try {
    Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120 | Out-Null
} catch {}

# Benchmark
for ($i = 1; $i -le 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120 | Out-Null
        $sw.Stop()
        $times += $sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        Write-Host "Request $i : ERROR"
    }
}

if ($times.Count -gt 0) {
    $avg = ($times | Measure-Object -Average).Average
    $min = ($times | Measure-Object -Minimum).Minimum
    $max = ($times | Measure-Object -Maximum).Maximum
    $avgToks = [math]::Round(16 * 1000 / $avg, 2)
    $bestToks = [math]::Round(16 * 1000 / $min, 2)
    Write-Host "$Name : avg=${avgToks} tok/s (best=$bestToks, avg_ms=$([math]::Round($avg)))"
}
