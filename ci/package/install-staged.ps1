#Requires -RunAsAdministrator
# Stage the test-signed DroidVM KMD package. This script deliberately does NOT
# run "pnputil /install" and does NOT reboot: the device binds to the new driver
# on the next normal guest boot.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cer = Join-Path $dir 'droidvm-kmd-test.cer'
$inf = Join-Path $dir 'virtio_wddm_rs.inf'

if (-not (Test-Path $cer)) { throw "missing $cer" }
if (-not (Test-Path $inf)) { throw "missing $inf" }

Write-Host '== DroidVM KMD candidate: stage only (no /install, no reboot) =='

Write-Host '-- trust the test certificate (Root + TrustedPublisher)'
& certutil.exe -addstore -f Root $cer
if ($LASTEXITCODE -ne 0) { throw "certutil Root failed: $LASTEXITCODE" }
& certutil.exe -addstore -f TrustedPublisher $cer
if ($LASTEXITCODE -ne 0) { throw "certutil TrustedPublisher failed: $LASTEXITCODE" }

$before = Join-Path $dir 'pnputil-before.txt'
& pnputil.exe /enum-drivers | Out-File -Encoding utf8 $before
Write-Host "saved pre-stage driver list: $before"

$addLog = Join-Path $dir 'pnputil-add.log'
& pnputil.exe /add-driver $inf 2>&1 | Tee-Object -FilePath $addLog
if ($LASTEXITCODE -ne 0) { throw "pnputil /add-driver failed: $LASTEXITCODE" }

Write-Host ''
Write-Host 'Staged successfully. The current device was NOT rebound by this script.'
Write-Host 'When ready, reboot the guest normally from inside Windows:'
Write-Host '    shutdown /r /t 0'
Write-Host 'PnP will bind the staged driver during the next boot.'
Write-Host ''
Write-Host 'Rollback after reboot:'
Write-Host "    pnputil /enum-drivers            # find the new oemXX.inf"
Write-Host '    pnputil /delete-driver <oemXX.inf> /uninstall /force'
Write-Host '    reinstall the previous package, then reboot normally'
Write-Host 'Certificate removal (after rollback):'
Write-Host '    certutil -delstore Root "DroidVM KMD Test (GitHub Actions)"'
Write-Host '    certutil -delstore TrustedPublisher "DroidVM KMD Test (GitHub Actions)"'
