$ErrorActionPreference = "Continue"
Write-Host "[vboxga] Searching for VirtualBox Guest Additions ISO..."

$drive = $null

# Method 1: Search all drives for VBoxWindowsAdditions.exe
foreach ($d in (Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 5 })) {
    $driveLetter = $d.DeviceID
    if (Test-Path "$driveLetter\VBoxWindowsAdditions.exe") {
        $drive = "$driveLetter\"
        Write-Host "[vboxga] Found on optical drive: $drive"
        break
    }
}

# Method 2: Search all drive letters if Method 1 failed
if (-not $drive) {
    foreach ($letter in @("D","E","F","G","H")) {
        if (Test-Path "${letter}:\VBoxWindowsAdditions.exe") {
            $drive = "${letter}:\"
            Write-Host "[vboxga] Found at: $drive"
            break
        }
    }
}

if (-not $drive) {
    Write-Host "[vboxga] WARNING: VBoxWindowsAdditions.exe not found on any drive"
    Write-Host "[vboxga] Available drives:"
    Get-CimInstance Win32_LogicalDisk | ForEach-Object {
        Write-Host "[vboxga]   $($_.DeviceID) DriveType=$($_.DriveType)"
    }
    Write-Host "[vboxga] Guest Additions NOT installed during Packer build"
    Write-Host "[vboxga] vagrant-vbguest plugin will install them on vagrant up"
    exit 0
}

Write-Host "[vboxga] Installing from: ${drive}VBoxWindowsAdditions.exe"
$proc = Start-Process -FilePath "${drive}VBoxWindowsAdditions.exe" `
    -ArgumentList "/S", "/with_autologon" `
    -Wait -PassThru

if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
    Write-Host "[vboxga] Guest Additions installed (exit code: $($proc.ExitCode))"
} else {
    Write-Host "[vboxga] WARNING: Exit code $($proc.ExitCode) - may need manual check"
}
