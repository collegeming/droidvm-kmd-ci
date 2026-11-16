#Requires -RunAsAdministrator
# Stage the test-signed DroidVM KMD package. This script deliberately does NOT
# run "pnputil /install" and does NOT reboot: the device binds to the new driver
# on the next normal guest boot.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cer = Join-Path $dir 'droidvm-kmd-test.cer'
$inf = Join-Path $dir 'virtio_wddm_rs.inf'
$minPrevious = [version]'20.15.1.43'

if (-not (Test-Path $cer)) { throw "missing $cer" }
if (-not (Test-Path $inf)) { throw "missing $inf" }

Write-Host '== DroidVM KMD candidate: stage only (no /install, no reboot) =='

Write-Host '-- trust the test certificate (Root + TrustedPublisher)'
& certutil.exe -addstore -f Root $cer
if ($LASTEXITCODE -ne 0) { throw "certutil Root failed: $LASTEXITCODE" }
& certutil.exe -addstore -f TrustedPublisher $cer
if ($LASTEXITCODE -ne 0) { throw "certutil TrustedPublisher failed: $LASTEXITCODE" }

# Record and export the current DriverStore package(s) before staging, so the
# previous driver can be restored without downloading anything.
$before = Join-Path $dir 'pnputil-before.txt'
$beforeText = (& pnputil.exe /enum-drivers | Out-String)
[IO.File]::WriteAllText($before, $beforeText, [Text.Encoding]::UTF8)
Write-Host "saved pre-stage driver list: $before"
$backup = Join-Path $dir 'driverstore-backup'
New-Item -ItemType Directory -Force $backup | Out-Null
$existing = [regex]::Matches($beforeText, 'Published Name:\s*(oem\d+\.inf)[\s\S]*?Original Name:\s*virtio_wddm_rs\.inf')
foreach ($m in $existing) {
    $published = $m.Groups[1].Value
    Write-Host "exporting existing driver package $published to $backup"
    & pnputil.exe /export-driver $published $backup
}

$addLog = Join-Path $dir 'pnputil-add.log'
& pnputil.exe /add-driver $inf 2>&1 | Tee-Object -FilePath $addLog
if ($LASTEXITCODE -ne 0) { throw "pnputil /add-driver failed: $LASTEXITCODE" }

# Confirm the staged version from the DriverStore listing.
$after = Join-Path $dir 'pnputil-after.txt'
$afterText = (& pnputil.exe /enum-drivers | Out-String)
[IO.File]::WriteAllText($after, $afterText, [Text.Encoding]::UTF8)
$staged = [regex]::Matches($afterText, 'Published Name:\s*(oem\d+\.inf)[\s\S]*?Original Name:\s*virtio_wddm_rs\.inf[\s\S]*?Driver Version:\s*([^\r\n]+)')
$ok = $false
foreach ($m in $staged) {
    $published = $m.Groups[1].Value
    $raw = $m.Groups[2].Value.Trim()
    Write-Host "staged: $published  Driver Version: $raw"
    $numeric = ($raw -split '\s+')[-1]
    try {
        $v = [version]$numeric
    } catch {
        Write-Warning "could not parse staged version '$raw'"
        continue
    }
    if ($v -le $minPrevious) {
        Write-Warning "staged version $v is NOT newer than $minPrevious; PnP may keep the old driver"
    } else {
        Write-Host "OK: staged version $v is newer than $minPrevious"
        $ok = $true
    }
}
if (-not $ok) {
    Write-Warning "no staged virtio_wddm_rs.inf with a version newer than $minPrevious was found; inspect $after"
}

Write-Host ''
Write-Host 'Staged. The current device was NOT rebound by this script.'
Write-Host 'When ready, reboot the guest normally from inside Windows:'
Write-Host '    shutdown /r /t 0'
Write-Host ''
Write-Host 'After reboot, verify the new package is bound (not oem11.inf):'
Write-Host '    Get-PnpDevice -Class Display | Select-Object Status,FriendlyName,InstanceId'
Write-Host '    Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID'
Write-Host '    pnputil /enum-devices /class Display'
Write-Host '    Get-PnpDeviceProperty -InstanceId <instance-id> -KeyName DEVPKEY_Device_DriverInfPath'
Write-Host ''
Write-Host 'Rollback after reboot:'
Write-Host '    pnputil /enum-drivers            # find the new oemXX.inf'
Write-Host '    pnputil /delete-driver <oemXX.inf> /uninstall /force'
Write-Host "    pnputil /add-driver $backup\*.inf   # restore the exported backup"
Write-Host '    reboot normally from inside the guest'
Write-Host ''
Write-Host 'Certificate removal (after rollback):'
Write-Host '    certutil -delstore Root "DroidVM KMD Test (GitHub Actions)"'
Write-Host '    certutil -delstore TrustedPublisher "DroidVM KMD Test (GitHub Actions)"'
