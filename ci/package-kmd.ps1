#Requires -Version 7.0
# Package + test-sign the ARM64 KMD on windows-latest.
# Inputs: artifacts/kmd-arm64-build (from the Linux build job).
# Secrets: SIGN_PFX_BASE64, SIGN_PFX_PASSWORD. Never print either value.
param(
    [string]$ArtifactRoot = 'artifacts',
    [string]$DistDir = 'dist'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$versions = @{}
Get-Content (Join-Path $root 'versions.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z0-9_]+)=(.*)$') { $versions[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
$subject = $versions['CERT_SUBJECT']
if (-not $subject) { throw 'CERT_SUBJECT is missing from versions.env' }
$run = if ($env:GITHUB_RUN_NUMBER) { $env:GITHUB_RUN_NUMBER } else { '0' }
# Must stay above the currently installed candidate (20.15.1.43 / oem11.inf).
$version = if ($versions['INF_DRIVER_VER']) { $versions['INF_DRIVER_VER'] } else { '20.15.2.0' }
$variant = if ($env:KMD_VARIANT) { $env:KMD_VARIANT } else { 'stock' }
$patchKind = if ($env:PATCH) { $env:PATCH } else { 'none' }

# ---- collect build artifacts
$artifactPath = Join-Path $root $ArtifactRoot
$sysSrc = Get-ChildItem -Path $artifactPath -Recurse -File -Filter 'virtio_wddm_rs.sys' | Select-Object -First 1
if (-not $sysSrc) { throw "virtio_wddm_rs.sys not found under $artifactPath" }
$buildLog = Get-ChildItem -Path $artifactPath -Recurse -File -Filter 'build.log' | Select-Object -First 1
$buildEnv = Get-ChildItem -Path $artifactPath -Recurse -File -Filter 'BUILD-ENV.txt' | Select-Object -First 1
$uapi = Get-ChildItem -Path $artifactPath -Recurse -File -Filter 'virtio_wddm_uapi.h' | Select-Object -First 1
$patchLog = Get-ChildItem -Path $artifactPath -Recurse -File -Filter 'patch.log' | Select-Object -First 1
$pdb = Get-ChildItem -Path $artifactPath -Recurse -File -Filter 'virtio_gpu_wddm_rs.pdb' | Select-Object -First 1

# ---- stage
$stage = Join-Path $root 'stage'
$drv = Join-Path $stage 'driver'
$dist = Join-Path $root $DistDir
Remove-Item -Recurse -Force $stage, $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $drv, $dist | Out-Null

$sys = Join-Path $drv 'virtio_wddm_rs.sys'
$inf = Join-Path $drv 'virtio_wddm_rs.inf'
$cat = Join-Path $drv 'virtio_wddm_rs.cat'
$cer = Join-Path $stage 'droidvm-kmd-test.cer'
Copy-Item $sysSrc.FullName $sys
if ($pdb) { Copy-Item $pdb.FullName (Join-Path $stage $pdb.Name) }

# ---- INF
$template = Get-Content (Join-Path $root 'ci/package/virtio_wddm_rs_arm64.inx') -Raw
$buildDate = (Get-Date).ToUniversalTime().ToString('MM/dd/yyyy')
$infText = $template.Replace('%%BUILDDATE%%', $buildDate).Replace('%%VERSION%%', $version)
[IO.File]::WriteAllText($inf, $infText.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)

# ---- tools: Inf2Cat from the WDK NuGet, signtool from the installed SDK
$nuget = Join-Path $root 'wdk-nuget'
$inf2cat = Get-ChildItem $nuget -Recurse -Filter 'Inf2Cat.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $inf2cat) {
    $nugetVer = $versions['NUGET_VER']
    New-Item -ItemType Directory -Force $nuget | Out-Null
    $zip = Join-Path $stage 'wdk.zip'
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.x64/$nugetVer/microsoft.windows.wdk.x64.$nugetVer.nupkg" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $nuget -Force
    Remove-Item $zip
    $inf2cat = Get-ChildItem $nuget -Recurse -Filter 'Inf2Cat.exe' -File | Select-Object -First 1
}
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter 'signtool.exe' -File -ErrorAction SilentlyContinue |
    Where-Object FullName -match '\\x64\\' | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $inf2cat -or -not $signtool) {
    throw "missing tools: Inf2Cat=$(if ($inf2cat) { $inf2cat.FullName } else { '<none>' }) signtool=$(if ($signtool) { $signtool.FullName } else { '<none>' })"
}
Write-Host "Inf2Cat: $($inf2cat.FullName)"
Write-Host "signtool: $($signtool.FullName)"

# ---- certificate from repo secrets (stable test cert; never auto-generate here)
if (-not $env:SIGN_PFX_BASE64 -or -not $env:SIGN_PFX_PASSWORD) {
    throw 'SIGN_PFX_BASE64 / SIGN_PFX_PASSWORD secrets are not set'
}
$pfx = Join-Path $stage 'sign.pfx'
$pw = $env:SIGN_PFX_PASSWORD
[IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:SIGN_PFX_BASE64))
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $pfx, $pw, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
if ($cert.Subject -ne $subject) {
    throw "PFX subject mismatch: expected '$subject', got '$($cert.Subject)'"
}
[IO.File]::WriteAllBytes($cer, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
$thumbprint = $cert.Thumbprint
$certSha256 = $cert.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
$pinnedCer = Join-Path $root 'certs/droidvm-kmd-test.cer'
if (Test-Path $pinnedCer) {
    $pinnedHash = (Get-FileHash $pinnedCer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pinnedHash -ne $certSha256) {
        throw "PFX does not match certs/droidvm-kmd-test.cer (pfx=$certSha256 pinned=$pinnedHash); rotate the pinned public cert when rotating secrets"
    }
}
Write-Host "Signing cert subject: $subject"
Write-Host "Signing cert SHA1 thumbprint: $thumbprint"
Write-Host "Signing cert SHA256: $certSha256"

function Invoke-Sign([string]$Path) {
    & $signtool.FullName sign /fd SHA256 /f $pfx /p $pw $Path
    if ($LASTEXITCODE -ne 0) { throw "signtool failed for $Path (exit $LASTEXITCODE)" }
}

Invoke-Sign $sys
& $inf2cat.FullName /driver:$drv /os:10_GE_ARM64 /uselocaltime
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed (exit $LASTEXITCODE)" }
if (-not (Test-Path $cat)) { throw "Inf2Cat did not produce $cat" }
Invoke-Sign $cat

# ---- make the ephemeral runner trust the test cert, then verify signatures
Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null

$checks = @(
    @{ Name = 'virtio_wddm_rs.sys'; Path = $sys },
    @{ Name = 'virtio_wddm_rs.cat'; Path = $cat }
)
$report = [System.Collections.Generic.List[string]]::new()
$failed = $false
foreach ($check in $checks) {
    $sig = Get-AuthenticodeSignature -FilePath $check.Path
    $signer = $sig.SignerCertificate
    $signerSubject = if ($signer) { $signer.Subject } else { '<none>' }
    $signerThumbprint = if ($signer) { $signer.Thumbprint } else { '<none>' }
    $report.Add("file=$($check.Name)")
    $report.Add("status=$($sig.Status)")
    $report.Add("status_message=$($sig.StatusMessage)")
    $report.Add("signer_subject=$signerSubject")
    $report.Add("signer_thumbprint=$signerThumbprint")
    $report.Add('')
    if ($sig.Status -ne [System.Management.Automation.SignatureStatus]::Valid) { $failed = $true }
    if ($signerSubject -ne $subject) { $failed = $true }
    if ($signerThumbprint -ne $thumbprint) { $failed = $true }
}
$report | Set-Content (Join-Path $stage 'signature-verify.txt') -Encoding ascii
$report | ForEach-Object { Write-Host $_ }
if ($failed) { throw 'Authenticode verification failed (status/subject/thumbprint mismatch)' }
Write-Host 'Authenticode verification: Valid for .sys and .cat'

# ---- PE header facts
$bytes = [IO.File]::ReadAllBytes($sys)
$peOff = [BitConverter]::ToInt32($bytes, 0x3C)
$machine = [BitConverter]::ToUInt16($bytes, $peOff + 4)
$opt = $peOff + 24
$magic = [BitConverter]::ToUInt16($bytes, $opt)
$entryRva = [BitConverter]::ToUInt32($bytes, $opt + 0x10)
$imageBase = [BitConverter]::ToUInt64($bytes, $opt + 0x18)
$sizeOfImage = [BitConverter]::ToUInt32($bytes, $opt + 0x38)
$subsystem = [BitConverter]::ToUInt16($bytes, $opt + 0x44)
$dllChars = [BitConverter]::ToUInt16($bytes, $opt + 0x46)
Write-Host ("PE: machine=0x{0:X4} magic=0x{1:X4} subsystem={2} entry_rva=0x{3:X} image_base=0x{4:X} size_of_image=0x{5:X} dllchars=0x{6:X4}" -f $machine, $magic, $subsystem, $entryRva, $imageBase, $sizeOfImage, $dllChars)
if ($machine -ne 0xAA64) { throw "PE machine is 0x$('{0:X4}' -f $machine), expected 0xAA64" }
if ($magic -ne 0x20B) { throw "PE optional magic is 0x$('{0:X4}' -f $magic), expected PE32+ 0x20B" }
if ($subsystem -ne 1) { throw "PE subsystem is $subsystem, expected 1 (NATIVE)" }
if ($entryRva -eq 0) { throw 'PE entry RVA is zero; /ENTRY:driver_entry was not honored' }

$sysHash = (Get-FileHash $sys -Algorithm SHA256).Hash.ToLowerInvariant()
$catHash = (Get-FileHash $cat -Algorithm SHA256).Hash.ToLowerInvariant()

# ---- build info
$rustcLine = ''
if ($buildLog) {
    $m = Select-String -Path $buildLog.FullName -Pattern '^rustc \d' | Select-Object -First 1
    if ($m) { $rustcLine = $m.Line }
}
$buildInfo = @(
    'droidvm-kmd-ci candidate package (test-signed, unofficial)',
    "repo=$($env:GITHUB_REPOSITORY)",
    "commit=$($env:GITHUB_SHA)",
    "run_id=$($env:GITHUB_RUN_ID)",
    "run_number=$run",
    "ref=$($env:GITHUB_REF)",
    "variant=$variant",
    "patch=$patchKind",
    "patch_identity_sha256=$($versions['IDENTITY_PATCH_SHA256'])",
    "patch_gdi_sha256=$($versions['GDI_PATCH_SHA256'])",
    "built_utc=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
    "kmd_upstream_commit=$($versions['KMD_UPSTREAM_COMMIT'])",
    "rustc=$rustcLine",
    "target=aarch64-pc-windows-msvc",
    "profile=debug",
    "inf_driver_ver=$version",
    "inf_build_date=$buildDate",
    "inf_hwid=PCI\VEN_1AF4&DEV_1050&SUBSYS_10501AF4&REV_01;PCI\VEN_1AF4&DEV_1050&SUBSYS_11001AF4&REV_01",
    "cert_subject=$subject",
    "cert_thumbprint_sha1=$thumbprint",
    "cert_sha256=$certSha256",
    "sys_sha256=$sysHash",
    "cat_sha256=$catHash",
    ("pe_machine=0x{0:X4}" -f $machine),
    ("pe_magic=0x{0:X4}" -f $magic),
    "pe_subsystem=$subsystem",
    ("pe_entry_rva=0x{0:X}" -f $entryRva),
    ("pe_image_base=0x{0:X}" -f $imageBase),
    ("pe_size_of_image=0x{0:X}" -f $sizeOfImage),
    ("pe_dll_characteristics=0x{0:X4}" -f $dllChars),
    'entry_point_link_arg=/ENTRY:driver_entry',
    'signature_sys=Valid',
    'signature_cat=Valid'
)
$buildInfo | Set-Content (Join-Path $stage 'BUILD-INFO.txt') -Encoding ascii

# ---- package files (flat zip root)
Copy-Item $cer $drv
if ($buildLog) { Copy-Item $buildLog.FullName (Join-Path $drv 'build.log') }
if ($buildEnv) { Copy-Item $buildEnv.FullName (Join-Path $drv 'BUILD-ENV.txt') }
if ($uapi) { Copy-Item $uapi.FullName (Join-Path $drv 'virtio_wddm_uapi.h') }
if ($patchLog) { Copy-Item $patchLog.FullName (Join-Path $drv 'patch.log') }
Copy-Item (Join-Path $PSScriptRoot 'package/install-staged.ps1') $drv
Copy-Item (Join-Path $PSScriptRoot 'package/README-INSTALL.txt') $drv
Copy-Item (Join-Path $stage 'BUILD-INFO.txt') $drv
Copy-Item (Join-Path $stage 'signature-verify.txt') $drv

$packageFiles = @(
    'virtio_wddm_rs.sys', 'virtio_wddm_rs.cat', 'virtio_wddm_rs.inf',
    'droidvm-kmd-test.cer', 'BUILD-INFO.txt', 'BUILD-ENV.txt',
    'signature-verify.txt', 'virtio_wddm_uapi.h', 'patch.log', 'build.log',
    'install-staged.ps1', 'README-INSTALL.txt'
) | Where-Object { Test-Path (Join-Path $drv $_) }
$sums = foreach ($f in $packageFiles) {
    '{0}  {1}' -f (Get-FileHash (Join-Path $drv $f) -Algorithm SHA256).Hash.ToLowerInvariant(), $f
}
[IO.File]::WriteAllText((Join-Path $drv 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), [Text.Encoding]::ASCII)
$sums | ForEach-Object { Write-Host $_ }

$zipPath = Join-Path $dist "droidvm-kmd-arm64-$variant-$run.zip"
Compress-Archive -Path (Join-Path $drv '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force

foreach ($f in (Get-ChildItem $drv -File)) { Copy-Item $f.FullName $dist }
if ($pdb) { Copy-Item $pdb.FullName $dist }
$distSums = Get-ChildItem $dist -File | Where-Object Name -ne 'SHA256SUMS.txt' | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
}
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($distSums -join "`n") + "`n"), [Text.Encoding]::ASCII)

if ($env:GITHUB_STEP_SUMMARY) {
    @"
## DroidVM KMD candidate (run $run)
- sys SHA256: ``$sysHash``
- cat SHA256: ``$catHash``
- cert subject: ``$subject``
- cert thumbprint: ``$thumbprint``
- Authenticode: .sys=Valid, .cat=Valid
- PE: machine=0xAA64 subsystem=1 entry_rva=0x$('{0:X}' -f $entryRva)
"@ | Add-Content $env:GITHUB_STEP_SUMMARY
}

Get-ChildItem $dist | Format-Table Name, Length
Write-Host "Package: $zipPath"
