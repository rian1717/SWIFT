# Architecture

## Goal

Native macOS app to send/receive files with Android via **Quick Share** (Nearby
Share) over Wi-Fi LAN. All-Swift, **no third-party dependencies** — the protocol
is implemented here on Foundation, Network and CryptoKit alone. The protocol
itself was reverse-engineered by [grishka/NearDrop](https://github.com/grishka/NearDrop);
see [ATTRIBUTION.md](ATTRIBUTION.md).

## Layering

The app is a thin, testable SwiftUI shell over a swappable engine:

```
Views (SwiftUI)  ──observe──▶  AppModel (@MainActor, ObservableObject)
                                   │  intents (connect, sendFiles, respond…)
                                   ▼
                          SWIFTService  (protocol)
                          ├── MockSWIFTService   ← SWIFT_MOCK=1 (simulated)
                          └── NearbySWIFTService ← wraps SWIFTEngine (default)
                                   │
                                   ▼ callbacks (SWIFTServiceDelegate, @MainActor)
                              back into AppModel
```

**Why a protocol seam:** the UI never touches sockets, protobufs, or crypto. It
depends only on `SWIFTService` + `SWIFTServiceDelegate`. Swapping the
mock for the real engine changes one line in `AppModel.init` and adds no UI
churn.

### Files

| File | Role |
|------|------|
| `Sources/SWIFTApp/App/SWIFTApp.swift` | `@main`, windows, menu bar, and app delegate |
| `Sources/SWIFTApp/Model/AppModel.swift` | Single source of truth; state machine; delegate implementation |
| `Sources/SWIFTApp/Engine/SWIFTService.swift` | Engine interface and delegate |
| `Sources/SWIFTApp/Engine/MockService.swift` | Simulated engine for UI development |
| `Sources/SWIFTApp/Model/DomainTypes.swift` | UI-side devices and transfer models |
| `Views/RootView.swift` | Shell: header, Send/Receive switch, transfers list |
| `Views/SendView.swift` | Discover → connect → PIN → drag-drop/picker → send |
| `Views/ReceiveView.swift` | Visibility toggle, QR code, accept/decline |
| `Views/Components/*` | DeviceRow, DropZone, QRCode, TransferRow, PinBadge, … |
| `Design/Theme.swift` | Design tokens + `Card` container |

## The protocol interface (designed to match NearDrop)

`SWIFTService` deliberately mirrors NearDrop's two delegate groups so the
real wrapper is mechanical:

| Our method / callback | NearDrop equivalent |
|---|---|
| `startAdvertising` / `stopAdvertising` | `NearbyConnectionManager.becomeVisible` / listener |
| `serviceDidReceiveIncomingRequest` + `respondToIncoming` | `MainAppDelegate.obtainUserConsent` + `submitUserConsent` |
| `startDiscovery` / `stopDiscovery` | `startDeviceDiscovery` / `stopDeviceDiscovery` |
| `serviceDidDiscover` / `serviceDidLose` | `ShareExtensionDelegate.addDevice` / `removeDevice` |
| `connect(to:)` → `serviceDidEstablishConnection(pin:)` | outbound connection → `connectionWasEstablished(pinCode:)` |
| `sendFiles` | `OutboundNearbyConnection` |
| `serviceDidUpdateProgress` / `serviceDidFinishTransfer` | `transferProgress` / `transferFinished` |

## Protocol facts

From @grishka's specification — see [grishka/NearDrop](https://github.com/grishka/NearDrop).

- **Discovery:** mDNS service type `_FC9F5ED42C8A._tcp.`, TXT `n=` base64 endpoint info.
- **Transport:** TCP, 4-byte big-endian length-prefixed protobuf frames.
- **Handshake:** UKEY2 (ECDSA P-256), HKDF-SHA256 → 4 keys, yields a 4-digit PIN.
- **Encryption:** AES-256-CBC + HMAC-SHA256 "secure messages".
- **Transfer:** PairedKeyEncryption → Introduction (file list) → Accept/Reject →
  payload chunks → keep-alives every 10s.

## Known platform constraint

macOS can't emit the BLE advertisements Android uses for automatic discovery.
So Mac→Android generally works, but Android auto-seeing the Mac needs same Wi-Fi
+ often the QR/manual path. This is inherent, not fixable in our code — the UI is
designed around it (explicit visibility toggle + QR on the Receive screen).

## Send-flow semantics (important)

Quick Share has no "connect, then later choose files" step — the UKEY2 handshake
happens *when files are offered*. So `sendFiles(_:to:)` is connect+offer in one
call, and the verification PIN only exists afterwards. The UI reflects this:

`idle` → pick device → `staging` (drop zone / picker) → **Send** →
`connecting` → `awaitingConsent` (PIN shown) → remote accepts →
transfer moves to the shared Transfers list.

`SWIFTEngine` correlates each outbound session with the discovered endpoint
identifier and rejects a concurrent second transfer to the same endpoint.

## The protocol layer

`Sources/SWIFTCore/` is ours end to end. No generated code, no external
packages.

| Area | Files | Notes |
|---|---|---|
| Wire format | `Wire/ProtoWire.swift` | Hand-written proto2 reader/writer. Bounds-checked, varints capped, length prefixes validated against remaining bytes *before* allocating, depth-limited, unknown fields skipped rather than retained. |
| Messages | `Wire/Frames.swift` | The ~32 messages the protocol actually exchanges, replacing 15,436 lines of generated code. |
| Crypto | `Crypto/*.swift` | UKEY2 key agreement on CryptoKit P-256; AES-256-CBC + HMAC-SHA256 envelope. |
| Transport | `Transport/*.swift` | Actor-isolated async framing and the two session state machines. |
| Discovery | `Discovery.swift`, `NearbyPeers.swift`, `QuickShareBLE.swift` | mDNS advertise/browse, endpoint info, QR path. |

Two details are load-bearing and easy to get wrong; both are pinned by tests.

**Shared-secret encoding.** The key schedule hashes the ECDH X coordinate as a
*magnitude* — leading zeros stripped. CryptoKit returns a fixed 32 bytes. Using
it directly makes the two peers derive different keys whenever X starts with a
zero byte, roughly 1 handshake in 256. `UKey2.magnitudeBytes` reproduces the
reference behaviour; `CryptoVectors` holds cases cross-checked against the
original implementation, including the divergent ones.

**Public-key validation.** `P256.KeyAgreement.PublicKey(rawRepresentation:)`
does *not* check that the point is on the curve — it accepts all-zero and
arbitrary coordinates. Peer keys go through the X9.63 initialiser, which does
validate, closing an invalid-curve attack on the handshake.

## Wire compatibility

The protocol is undocumented, so "correct" means "byte-identical to something
that demonstrably worked". Before the protobuf dependency was removed, every
message was serialized with it and the bytes captured as `GoldenFixtures`. Each
type must encode to exactly those bytes and round-trip them. Regenerating them
requires temporarily restoring the dependency, which should not be necessary
unless the protocol itself changes.

That covers the wire format and the key schedule. It does **not** prove
interoperability with a real Android device — only a live transfer does.

## Status / next

Done: native engine, `NearbySWIFTService` wrapper, `.app` bundle with
Bonjour + `NSLocalNetworkUsageDescription`, menu-bar app, drag and drop,
transfer history, configurable receive location, bounded parsers, temporary
file writes, disk-space checks, quarantine attributes, and explicit consent.

Next:
1. **Smoke-test against real Android devices**, both directions, using
   `SWIFTProbe` and `REAL_DEVICE_TEST_MATRIX.md`.
2. **Verifiable device identity.** Auto-accept remains absent because
   there is nothing to key it on — see *Device identity* below.

## Device identity (why there is no auto-accept)

Trust needs a name you can verify, and this implementation has none:

- The UKEY2 ECDSA keys are generated per handshake
  (`domain.makeKeyPair()` in `InboundNearbyConnection.processUkey2ClientInit`),
  so a peer-key fingerprint changes every connection.
- The paired-key frames that carry persistent identity in real Quick Share are
  stubbed: NearDrop sends random bytes for `secretIDHash`/`signedData` and always
  answers `pairedKeyResult = .unable`.
- Inbound `RemoteDeviceInfo` carries no id at all — only the remote-supplied,
  unauthenticated display name.

So the app always prompts. `knownDevices` records names you've accepted from and
is used purely as a hint on the prompt. Re-enabling auto-accept safely means
implementing the certificate/contact exchange first.

## Security notes

The network-facing parser is the main attack surface. Frame and payload lengths,
nested depth, file counts, file sizes, names, and offsets are bounded. Received
names are reduced to leaf names, writes stay in the chosen destination, partial
files use unpredictable temporary names, and successful files receive the
macOS quarantine attribute. Randomized parser tests complement golden vectors;
an independent review is still required before a stable public release.
