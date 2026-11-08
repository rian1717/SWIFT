# ADR 0001: Native Swift and Quick Share LAN transport

- Status: Accepted
- Date: 2026-11-05

## Context

SWIFT's first promise is bidirectional transfer between macOS and Android
through Android's built-in Quick Share experience. macOS cannot emit the BLE
advertisements or provide the Wi‑Fi Direct APIs used by Google's complete
implementation.

## Decision

1. Target macOS 26 and newer for V1, validating first on macOS 27.
2. Use Swift 6, SwiftUI/AppKit, Network.framework, CryptoKit, and CommonCrypto.
3. Keep the protocol in a separate `SWIFTCore` target behind a service
   interface.
4. Implement Quick Share's same-LAN mDNS/TCP transport and QR/manual connection
   fallback.
5. Stream payloads in bounded chunks. Do not add accounts, a backend, analytics,
   or cloud relay.
6. Require per-transfer PIN confirmation because native Quick Share peers do not
   expose a verifiable persistent identity to this implementation.

## Consequences

The first release is small, native, and distributable without an Android
companion app. Same-network connectivity, router client isolation, VPNs, and
platform discovery limits must be explained in product UI. A portable Rust core,
BLE discovery, remote transfer, and older macOS support may be evaluated after
the V1 compatibility matrix is stable.
