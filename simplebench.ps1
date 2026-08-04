$handler = New-Object System.Net.Http.HttpHandler
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(120)

# Health check
Write-Host "Checking health..."
try {
    $resp = $client.GetAsync("http://127.0.0.1:8080/health").Result
    $body = $resp.Content.ReadAsStringAsync().Result
    Write-Host "Health: $body"
} catch {
    Write-Host "Health FAILED: $_"
    exit 1
}

# Warmup
Write-Host "Warmup..."
$content = New-Object System.Net.Http.StringContent('{"prompt":"What is 2+2?","n_predict":16,"temperature":0}', [System.Text.Encoding]::UTF8, "application/json")
$resp = $client.PostAsync("http://127.0.0.1:8080/completion", $content).Result
$body = $resp.Content.ReadAsStringAsync().Result
Write-Host "Warmup done"

# Benchmark
Write-Host "Benchmarking 5 requests..."
$times = @()
for ($i = 1; $i -le 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $content = New-Object System.Net.Http.StringContent('{"prompt":"What is 2+2?","n_predict":16,"temperature":0}', [System.Text.Encoding]::UTF8, "application/json")
    $resp = $client.PostAsync("http://127.0.0.1:8080/completion", $content).Result
    $body = $resp.Content.ReadAsStringAsync().Result
    $sw.Stop()
    $ms = $sw.ElapsedMilliseconds
    $toks = [math]::Round(16 * 1000 / $ms, 2)
    $times += $ms
    Write-Host "Request $i : ${ms}ms = $toks tok/s"
}

$avg = ($times | Measure-Object -Average).Average
Write-Host "AVG: $([math]::Round(16*1000/$avg,2)) tok/s"
$client.Dispose()
