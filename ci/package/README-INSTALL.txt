DroidVM ARM64 KMD candidate - test-signed, unofficial
=====================================================

Contents: virtio_wddm_rs.sys, virtio_wddm_rs.cat, virtio_wddm_rs.inf,
droidvm-kmd-test.cer, install-staged.ps1, BUILD-INFO.txt, patch.log,
build.log, SHA256SUMS.txt.

STAGE ONLY - do not use "pnputil /install" for this candidate. The device is
expected to bind on the next normal guest boot. Do not deploy from the host.

Version requirement:
  This package is DriverVer 11/16/2026 20.15.2.1 (or newer). The currently
  installed package (oem11.inf) is 11/03/2026 20.15.1.43, so the new package
  must win the driver ranking. Confirm the staged version before rebooting.

Install (elevated PowerShell in this folder):
  1. certutil -addstore -f Root .\droidvm-kmd-test.cer
     certutil -addstore -f TrustedPublisher .\droidvm-kmd-test.cer
  2. pnputil /enum-drivers > pnputil-before.txt
     Export the old package for rollback:
       New-Item -ItemType Directory -Force .\driverstore-backup
       pnputil /export-driver oem11.inf .\driverstore-backup
  3. pnputil /add-driver .\virtio_wddm_rs.inf
     (or: powershell -ExecutionPolicy Bypass -File .\install-staged.ps1)
  4. pnputil /enum-drivers > pnputil-after.txt
     Confirm the block for Original Name virtio_wddm_rs.inf shows
     Driver Version 20.15.2.1 (or newer), and record its new oemXX.inf name.
     It MUST be greater than 20.15.1.43 (the old oem11.inf).
  5. Reboot normally from inside the guest when ready: shutdown /r /t 0

The INF binds both:
  PCI\VEN_1AF4&DEV_1050&SUBSYS_10501AF4&REV_01   (current DroidVM/crosvm)
  PCI\VEN_1AF4&DEV_1050&SUBSYS_11001AF4&REV_01   (upstream/QEMU-style)

After reboot, verify the new package (not oem11.inf) is bound:
  Get-PnpDevice -Class Display | Select-Object Status,FriendlyName,InstanceId
  Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID
  pnputil /enum-devices /class Display
  Get-PnpDeviceProperty -InstanceId <instance-id> -KeyName DEVPKEY_Device_DriverInfPath

Rollback:
  pnputil /enum-drivers
  pnputil /delete-driver <new-oemXX.inf> /uninstall /force
  pnputil /add-driver .\driverstore-backup\*.inf
  Reboot normally. Keep a VM disk clone/system restore point.

Certificate removal (after rollback):
  certutil -delstore Root <thumbprint>
  certutil -delstore TrustedPublisher <thumbprint>
  Thumbprint is in BUILD-INFO.txt (cert_thumbprint_sha1).

Notes:
- Testsigning/nointegritychecks are expected to be enabled already; this
  package does not change bcdedit settings.
- The identity variant writes HardwareInformation.ChipType/AdapterString and
  DriverDesc only when SystemManufacturer == "DroidVM" and SystemProductName is
  a real host-provided name. The stock variant does not write those values.
- The gdi/both variants issue RESOURCE_DETACH_BACKING before re-attaching
  backing on UPDATE_PAGE_TABLE, so rutabaga drops the stale iovec before the
  coalesced page list is installed.
- Verify integrity with: Get-FileHash <file> -Algorithm SHA256
