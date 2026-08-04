$cpu = Get-CimInstance Win32_Processor
Write-Host "CPU: $($cpu.Name)"
Write-Host "Max MHz: $($cpu.MaxClockSpeed)"
Write-Host "Current MHz: $($cpu.CurrentClockSpeed)"
Write-Host "Cores: $($cpu.NumberOfCores)"
Write-Host "Threads: $($cpu.NumberOfLogicalProcessors)"
Write-Host ""
# Check memory
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "Total RAM: $([math]::Round($os.TotalVisibleMemorySize/1MB, 1)) GB"
Write-Host "Free RAM: $([math]::Round($os.FreePhysicalMemory/1MB, 2)) GB"
Write-Host ""
# Check if AVX_VNNI is available (for Gemma 4 26B-A4B on CPU)
Write-Host "Note: N150 supports AVX_VNNI which accelerates quantized matmul"
Write-Host "b10242 binary should use AVX_VNNI if compiled with -mavxvnni"
