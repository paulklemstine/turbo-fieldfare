$serverPath = "C:\Users\Paul\llama-b10242\llama-server.exe"
$args = @(
    "-m", "C:\Users\Paul\models\gemma-4-26B-A4B-it.Q4_0.gguf",
    "-ngl", "0", "-c", "512", "-t", "4",
    "--cpu-strict", "1", "--no-repack",
    "-ctk", "q8_0", "-ctv", "q8_0",
    "-ub", "256",
    "--port", "8080"
)

$proc = Start-Process -FilePath $serverPath -ArgumentList $args -PassThru -NoNewWindow -RedirectStandardOutput "C:\Users\Paul\baseline_out.log" -RedirectStandardError "C:\Users\Paul\baseline_err.log"

# Wait for ready
for ($i = 1; $i -le 120; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:8080/health" -TimeoutSec 2 -ErrorAction Stop
        if ($r.Content -match "ok") {
            Write-Host "Server ready after ${i}s"
            break
        }
    } catch {}
}

# Warmup + benchmark
$uri = "http://127.0.0.1:8080/completion"
$body = '{"prompt":"What is 2+2?","n_predict":16,"temperature":0}'
Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120 | Out-Null

$times = @()
for ($j = 1; $j -le 5; $j++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120 | Out-Null
    $sw.Stop()
    $times += $sw.ElapsedMilliseconds
    Write-Host "Request $j : $($sw.ElapsedMilliseconds)ms ($([math]::Round(16*1000/$sw.ElapsedMilliseconds,2)) tok/s)"
}

$avg = ($times | Measure-Object -Average).Average
Write-Host "AVG: $([math]::Round(16*1000/$avg,2)) tok/s"

$proc.Kill()
