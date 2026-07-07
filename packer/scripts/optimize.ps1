$ErrorActionPreference = "Continue"
Write-Host "[optimize] Applying performance optimizations..."

# Disable unnecessary services
$services = @(
    "wuauserv",      # Windows Update
    "WSearch",       # Windows Search
    "SysMain",       # Superfetch
    "WerSvc",        # Windows Error Reporting
    "DiagTrack",     # Connected User Experiences
    "dmwappushservice" # WAP Push
)

foreach ($svc in $services) {
    try {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-Service $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "[optimize] Disabled service: $svc"
    } catch {
        Write-Host "[optimize] Could not disable: $svc"
    }
}

# Disable hibernation
powercfg /h off
Write-Host "[optimize] Hibernation disabled"

# High performance power plan
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
Write-Host "[optimize] High performance power plan set"

# Disable System Restore
try {
    Disable-ComputerRestore -Drive "C:\" -ErrorAction Stop
    Write-Host "[optimize] System Restore disabled"
} catch {
    Write-Host "[optimize] System Restore not available on this edition"
}

# Disable Windows Defender scheduled scans
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Write-Host "[optimize] Windows Defender real-time disabled"
} catch {}

# Disable unnecessary scheduled tasks
$tasks = @(
    "\Microsoft\Windows\Defrag\ScheduledDefrag",
    "\Microsoft\Windows\Diagnosis\Scheduled",
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "\Microsoft\Windows\Maintenance\WinSAT",
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)

foreach ($task in $tasks) {
    try {
        Disable-ScheduledTask -TaskPath (Split-Path $task) `
            -TaskName (Split-Path $task -Leaf) `
            -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}
Write-Host "[optimize] Scheduled tasks disabled"

Write-Host "[optimize] Optimizations complete"
