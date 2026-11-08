# Real-device interoperability matrix

Loopback and golden-vector tests cannot prove compatibility with Google's
current Quick Share build. Complete this matrix for every release candidate.

## Record before testing

- SWIFT commit and build number
- Mac model, macOS version, interface, and firewall/VPN state
- Phone model, Android version, Google Play system update, Quick Share version
- Router model, firmware, bands/SSIDs, and client-isolation setting

## Required devices

- Redmi Note 14
- Samsung Galaxy S22
- Google Pixel 8

## Probe commands

Run from `SWIFT/`:

```bash
swift run SWIFTProbe discover 45
swift run SWIFTProbe receive --directory /tmp/swift-receive --accept
swift run SWIFTProbe send /tmp/swift-fixture.bin --to "PHONE NAME"
```

For Local Network permission, use the packaged app if macOS denies a bare
terminal process:

```bash
Packaging/build-app.sh debug
open build/SWIFT.app
```

## Per-device cases

- [ ] Phone discovers visible Mac in native Quick Share
- [ ] Android → Mac 1 KiB text file; PIN matches; SHA-256 matches
- [ ] Android → Mac 1.5 GiB file; bounded Mac memory; SHA-256 matches
- [ ] Android → Mac multiple files with duplicate and Unicode names
- [ ] Android → Mac sender cancellation removes every `.part` file
- [ ] Android → Mac Mac rejection produces a clear Android result
- [ ] Mac discovers phone while its Quick Share receive UI is open
- [ ] Mac → Android 1 KiB file; PIN matches; SHA-256 matches
- [ ] Mac → Android 1.5 GiB file; bounded Mac memory; SHA-256 matches
- [ ] Mac → Android multiple files
- [ ] Mac → Android receiver cancellation stops sending promptly
- [ ] QR/manual route works when ordinary discovery does not
- [ ] Recovery after Wi‑Fi interruption
- [ ] Recovery after Mac sleep/wake

## Pass criteria

V1 requires three consecutive clean runs of every applicable case on every
device. A discovery limitation may be documented only when QR/manual connection
passes and the UI explains the exact recovery step.

Do not mark a case passed from the simulator, mock engine, loopback test, or
another project’s compatibility report.

## Tonight: Galaxy S22 first pass

Do this once the S22 is on the same Wi‑Fi as this MacBook Air (Mac14,2, macOS
27.0 26A428), with SWIFT **34017** already installed. Record the phone's
Android version and Quick Share version before starting.

1. Open Quick Share receive on the S22. Confirm it appears in SWIFT Send.
2. Send a small text file from the app. Confirm PIN, accept, file lands.
3. Share a larger file from Finder → SWIFT. Confirm the popup lists the
   S22, the bar moves, percent updates after accept, and the file lands.
4. From the S22, send a photo to the Mac. Confirm PIN, accept, file in Downloads.
5. Start a send and cancel on the phone. Confirm the Mac stops and shows failure.
6. If 1–5 are clean, send a few-hundred-MB file both ways. SHA-256 if practical.

Do **not** spend the first session on 1.5 GiB × 3 consecutive runs. That is the
V1 gate after the S22 handshake is proven. Pixel 8 remains a separate OEM; it
is not required to learn whether Samsung Quick Share talks to this build.

## Recorded runs

### 2026-11-05 evening — Redmi Note 14 — development build 34017

- Mac: Mac14,2 (Apple M2), macOS 27.0 (26A428)
- Android/Quick Share version: not recorded
- Network details: not recorded
- [x] Mac discovers Redmi while Quick Share receive is open
- [x] Mac → Redmi via Finder Share; popup listed the phone; live progress
      (connecting → accept/PIN → sending percent); file accepted on the phone
- [x] Earlier the same day, Mac → Redmi document and Redmi → Mac photo both
      completed on build 34003
- [ ] 1.5 GiB both ways, SHA-256, cancellation, Wi‑Fi interrupt, sleep/wake,
      QR fallback, three consecutive clean runs

Result: Xiaomi Quick Share send path, including Finder Share with live
progress, works on this Mac. Not a V1 matrix pass.

### 2026-11-05 — Redmi Note 14 — development build 34003

- macOS: 27 (exact point version not recorded)
- Android/Quick Share version: not recorded
- Network details: not recorded
- [x] Mac → Redmi document completed; file present in Android Downloads
- [x] Redmi → Mac photo completed; file present in macOS Downloads
- [ ] Remaining matrix cases

Result: bidirectional protocol spike passed. This is not yet a full device-matrix
pass because version metadata, repeated runs, large files, cancellation,
interruption, QR fallback, and failure cases were not recorded.
