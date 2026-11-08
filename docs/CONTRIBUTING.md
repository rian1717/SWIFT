# Contributing

SWIFT is a native macOS 26+ Swift 6 application. Changes should preserve
the no-account, no-cloud, bounded-memory design.

## Local checks

```bash
cd SWIFT
swift test
swift test --sanitize=thread
swift build -c release
```

To exercise the UI without a phone:

```bash
SWIFT_MOCK=1 swift run SWIFT
```

Real networking requires the packaged app:

```bash
SWIFT/Packaging/build-app.sh debug
open SWIFT/build/SWIFT.app
```

## Pull requests

- Add tests for protocol, parser, state-machine, and security changes.
- Never record real transferred file contents, PINs, tokens, or peer addresses.
- Document protocol provenance and licenses for imported material.
- Keep the app target thin; networking and transfer logic belong in
  `SWIFTCore`.
- Describe real-device validation separately from simulated and loopback tests.

Run the complete local checks before requesting review.
