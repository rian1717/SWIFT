# Release process

## Preconditions

- CI and the full local test suite pass.
- The Xcode app and Finder extension build in Release configuration.
- The Pixel, Samsung, and Redmi matrix passes three consecutive runs.
- Security findings are resolved or explicitly accepted.
- Version and changelog are updated.
- A valid Apple Developer ID Application certificate and notarytool keychain
  profile are available.

## Build and notarize

```bash
export SWIFT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export SWIFT_NOTARY_PROFILE="swift-notary"
SWIFT/Packaging/release.sh
```

The script builds the app and extension with hardened runtime, signs them,
creates and signs the DMG, waits for notarization, staples the ticket, validates
Gatekeeper acceptance, and writes a SHA-256 checksum.

## Beta gate

Distribute the notarized DMG to invited testers across:

- Apple silicon Mac on macOS 26 and macOS 27
- Redmi Note 14
- Samsung Galaxy S22
- Google Pixel 8
- home, office, guest, mesh, and hotspot networks

Record only device/version/network metadata and failure categories. Do not add
telemetry to the application.

## Publish

- Tag the exact tested commit.
- Upload DMG, `.sha256`, source archive, SBOM, and release notes.
- Verify a clean Mac installs and opens the downloaded artifact.
- Keep the trademark disclaimer and known LAN/discovery limitations prominent.
