try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 5 -ErrorAction Stop
    Write-Host "HEALTHY: $($r.Content)"
} catch {
    Write-Host "FAIL: $($_.Exception.Message)"
}
