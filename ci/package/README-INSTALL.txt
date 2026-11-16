DroidVM ARM64 KMD candidate - test-signed, unofficial
=====================================================

Contents: virtio_wddm_rs.sys, virtio_wddm_rs.cat, virtio_wddm_rs.inf,
droidvm-kmd-test.cer, install-staged.ps1, BUILD-INFO.txt, patch.log,
build.log, SHA256SUMS.txt.

STAGE ONLY - do not use "pnputil /install" for this candidate. The device is
expected to bind on the next normal guest boot. Do not deploy from the host.

Install (elevated PowerShell in this folder):
  1. certutil -addstore -f Root .\droidvm-kmd-test.cer
     certutil -addstore -f TrustedPublisher .\droidvm-kmd-test.cer
  2. pnputil /enum-drivers > pnputil-before.txt
  3. pnputil /add-driver .\virtio_wddm_rs.inf
     (or: powershell -ExecutionPolicy Bypass -File .\install-staged.ps1)
  4. Record the oemXX.inf name printed by pnputil for rollback.
  5. Reboot normally from inside the guest when ready: shutdown /r /t 0

The INF binds both:
  PCI\VEN_1AF4&DEV_1050&SUBSYS_10501AF4&REV_01   (current DroidVM/crosvm)
  PCI\VEN_1AF4&DEV_1050&SUBSYS_11001AF4&REV_01   (upstream/QEMU-style)

Rollback:
  pnputil /enum-drivers
  pnputil /delete-driver <new-oemXX.inf> /uninstall /force
  Reinstall the previous driver package (or restore the previous DriverStore
  package), then reboot normally. Keep a VM disk clone/system restore point.

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
- Verify integrity with: Get-FileHash <file> -Algorithm SHA256
