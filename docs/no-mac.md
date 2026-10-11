# Without a Mac: GitHub Actions + a Windows/Linux PC

The conversion needs macOS (Xcode's `vtool`, `codesign`, the iOS SDK), but no device: a GitHub
Actions macOS runner does it (`tools/ci_build.sh`, `.github/workflows/ios-build.yml`) and produces a
signed `.ipa`. A Windows or Linux PC with USB then replaces `devicectl` for installing, the console and
crash reports, using [pymobiledevice3](https://github.com/doronz88/pymobiledevice3).

Same rules as the [README](../README.md#legal-and-safety): your own Apple developer team, your own
devices, apps you own.

## Once

1. **Keep the repository private.** The `.ipa` artifact contains your profile (team, device UDIDs)
   and a converted copy of the app; the workflow only uploads it from a private repository.
2. **Profile, on developer.apple.com** (replaces `tools/make_profile.sh`, which needs Xcode):
   Certificates, Identifiers & Profiles ->
   - *Devices*: register the device UDID.
   - *Identifiers*: an App ID. A wildcard (`*`) is enough for most apps; an app that needs more
     memory needs an explicit App ID with the Increased Memory Limit and Extended Virtual
     Addressing capabilities (`--entitlement com.apple.developer.kernel.increased-memory-limit`,
     `--entitlement com.apple.developer.kernel.extended-virtual-addressing`).
   - *Profiles*: iOS App Development, that App ID, your Apple Development certificate, the device.
3. **Repository secrets** (Settings -> Secrets and variables -> Actions): `P12_BASE64`,
   `P12_PASSWORD`, `PROFILE_BASE64`. Base64 in PowerShell (copies to the clipboard):
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.p12")) | Set-Clipboard
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("dev.mobileprovision")) | Set-Clipboard
   ```
   The workflow checks that the profile is a development profile, not expired, includes the
   certificate, and (with `--entitlement`) has the entitlements.
4. **PC**: Python 3, `pip install pymobiledevice3`; on Windows also Apple's USB driver (the Apple
   Devices app or iTunes). Connect the device, trust the computer.
5. **Developer Mode** (needed to run development-signed apps):
   `pymobiledevice3 amfi enable-developer-mode`, or `pymobiledevice3 amfi reveal-developer-mode` and
   turn it on in Settings -> Privacy & Security -> Developer Mode.

## Loop

1. Actions -> *iOS build* -> *Run workflow*. `app`: `probe` (the toy probe, built from source) or an
   https URL of a `.zip`/`.dmg`/`.tar` holding the Mac app (direct-download builds; Mac App Store
   builds are encrypted and rejected). Extra `convert_app.py` options go in `convert_args`.
   Without the secrets it is a dry run: the conversion is checked, no `.ipa`.
2. Download the `ipa` artifact, unzip it, install:
   `pymobiledevice3 apps install MacProbe.ipa`
3. Console, then tap the app's icon:
   `pymobiledevice3 syslog live | findstr SHIM` (Linux: `grep SHIM`). These are the `SHIM ...` lines
   `run_app.sh` shows on a Mac (`SHIM STATS`, `SHIM STUB`, `SHIM MISSING`).
4. Crash: `pymobiledevice3 crash pull crashes`, then `python tools/crash.py crashes/<Name>-<date>.ips`.
   Without a PC: Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data.

The `convert-log` artifact (and the run summary) lists the shims built and their stub counts.
