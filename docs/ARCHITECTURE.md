# Architecture

SWIFT connects three kinds of devices on the same local network. Everything runs on the devices themselves: there is no server, account or cloud.

```
                 Quick Share (files, both ways)
   ┌──────────┐ ◀────────────────────────────▶ ┌──────────────────┐
   │ Mac app  │   SWIFT clipboard (encrypted)  │   Android app    │
   │ (Swift)  │ ◀───────────────────────────── │    (Kotlin)      │
   └──────────┘                                └────────┬─────────┘
                                                        │ QR code → web page served by the phone
                                                        ▼
                                               ┌──────────────────┐
                                               │ iPhone (Safari)  │  nothing to install
                                               └──────────────────┘
```

| Part | Language | Lives in | Job |
|---|---|---|---|
| **Mac app** | Swift 6, SwiftUI | `SWIFT/`, `SWIFTShareExtension/` | Speaks Quick Share to send and receive files, runs the clipboard receiver, and lives in the menu bar and the Finder share menu. |
| **Android app** | Kotlin | `android/` | Speaks Quick Share's receive side inside SWIFT, sends copies to the Mac, and serves the iPhone page. |
| **iPhone page** | HTML and JS, embedded in the Android app | `android/.../PhotoWeb.kt` | Opened by scanning the QR code. Saves photos to Photos and uploads photos back to Android. |

Neither app has a third-party dependency. The Mac side uses only Foundation, Network and CryptoKit. The Android side uses only the Android SDK and Kotlin standard libraries.

## How devices find each other

| What | Mechanism | Detail |
|---|---|---|
| Quick Share peers | mDNS / Bonjour | Service type `_FC9F5ED42C8A._tcp`, with the endpoint info in the TXT record `n=` (base64) |
| Mac clipboard receiver | Bonjour | `_swift._tcp`, port **47822** |
| SWIFT phones, seen by the Mac | mDNS / Bonjour | The Android app advertises itself as a Quick Share receiver (`Presence.kt`) |
| iPhone page | QR code | `http://<phone Wi-Fi IP>:47825/s/<token>`; the secure page is on **47826** |

macOS can't emit the Bluetooth LE advertisements Android uses for automatic Quick Share discovery. Mac → Android is therefore the reliable direction, and the QR code is the designed fallback for Android → Mac. Both apps only ever hand out a Wi-Fi or hotspot address, never a mobile-data or VPN address (`LocalNetwork.kt`, `AddressRules`).

## Feature flows

### Files: Quick Share, both ways

1. The sender connects over TCP and runs the UKEY2 handshake: ECDSA P-256, then HKDF-SHA256 into four keys.
2. Both screens show the same 4-digit PIN, derived from the handshake.
3. The sender offers a file list (Introduction). The receiver's user accepts or declines; no answer within 60 seconds counts as a decline.
4. Payload chunks flow inside AES-256-CBC + HMAC-SHA256 "secure messages", with keep-alives every 10 s.

On the Mac this is `SWIFTCore`. On Android, `QuickShareSession.kt` speaks the receive side, so the phone stays inside SWIFT and doesn't jump into Google's Receive screen.

### Clipboard: Android → Mac

1. **Pairing**, once. The phone and the Mac each generate a P-256 key pair, swap public keys through `/clip/pair`, and derive a shared key. The key never crosses the network. The 8-digit code or the QR code proves the right Mac is being paired, and the Mac asks the user to **Allow** an unknown phone.
2. **Copy.** `ClipboardAccessibilityService` notices a copy and `ClipSync` seals it with AES-GCM and a rising counter, then posts it to the Mac on port 47822. The Mac rejects any counter it has already seen, so an old copy can't be replayed. It then puts the content on the pasteboard for ⌘V.
3. **Status.** While the app is open, the phone checks `/clip/status` every 2 seconds (once a minute in the background) to show **Connected** or **Not on this Wi-Fi**. If the Mac's address has changed, it rediscovers it, by NSD and then by a subnet scan.

The two implementations must match byte for byte: `ClipCrypto.kt` and `ClipboardSecurity.swift`.

### iPhone ⇄ Android: the photo page

The Android app runs a small HTTP server (`PhotoWeb.kt`) with a secure HTTPS twin. The HTTPS twin uses a self-signed certificate made on the phone (`PhotoTls.kt`), because Safari only allows **Save to Photos** on a secure page.

| Route | Purpose |
|---|---|
| `/s/<token>` | The page. The token is random per session, so only someone who scanned the code can open it |
| `/inbox` | The list of shared photos and videos, as JSON |
| `/thumb/<id>` | Small previews, so Safari doesn't run out of memory |
| `/file/<id>`, `/download/<id>` | The original file, inline or as a download, with Range support so broken downloads resume |
| `/upload` | iPhone → Android. Files land in the gallery's SWIFT album |

The page loads four files at a time and retries with resume. It hands batches of up to 100 items or 300 MB to iOS's share sheet, and halves the batch if Safari refuses it. The server holds a Wi-Fi lock and a wake lock only while requests are in flight.

## Mac app layering

```
Views (SwiftUI)  ──observe──▶  AppModel (@MainActor)
                                   │  intents (connect, sendFiles, respond…)
                                   ▼
                          SWIFTService  (protocol)
                          ├── MockSWIFTService   ← SWIFT_MOCK=1 (simulated, for UI work)
                          └── NearbySWIFTService ← wraps SWIFTEngine (default)
```

The UI never touches sockets, protobufs or crypto. It depends only on `SWIFTService` and its delegate, which is what makes the mock engine possible.

| Area | Where | Notes |
|---|---|---|
| App shell | `Sources/SWIFTApp/App`, `Views`, `Design` | Menu bar app, windows, Send/Receive, Settings |
| State | `Sources/SWIFTApp/Model/AppModel.swift` | The single source of truth and state machine |
| Clipboard | `Sources/SWIFTApp/Engine/ClipboardServer.swift` | Pairing, sealed copies, status, Bonjour `_swift._tcp` |
| Wire format | `Sources/SWIFTCore/Wire` | Hand-written proto2 reader/writer, bounds-checked and depth-limited |
| Crypto | `Sources/SWIFTCore/Crypto` | UKEY2 on CryptoKit P-256; AES-CBC + HMAC envelope |
| Transport | `Sources/SWIFTCore/Transport` | Actor-isolated framing and the two session state machines |
| Discovery | `Sources/SWIFTCore/Discovery*.swift`, `NearbyPeers.swift` | mDNS advertise and browse, endpoint info, QR path |

The Mac app is built in Swift 6 language mode: transport runs on actors, the app on the main actor, and the compiler checks the boundary.

## Android app layout

| File | Role |
|---|---|
| `MainActivity.kt` | The two-tab UI (Mac, iPhone), pairing, setup rows, live Mac status |
| `ClipSync.kt`, `ClipCrypto.kt` | Clipboard pairing, sealing and sending; Mac reachability |
| `ClipboardAccessibilityService.kt`, `ClipForegroundService.kt` | Notice copies; keep running as a connected-device service |
| `QuickShareSession.kt`, `TransferConsent.kt`, `TransferAlerts.kt` | Quick Share receive side, the accept/decline prompt, notifications |
| `PhotoWeb.kt`, `PhotoTls.kt`, `PhotoExchange.kt` | The iPhone page, its HTTPS certificate, and photo bookkeeping |
| `Presence.kt`, `LocalNetwork.kt`, `AddPhone.kt` | Advertising to the Mac, choosing the Wi-Fi address, the QR code to add a phone |

## Two protocol details that are easy to get wrong

Both are pinned by tests.

- **Shared-secret encoding.** The key schedule hashes the ECDH X coordinate as a *magnitude*, with leading zeros stripped. CryptoKit returns a fixed 32 bytes, so using it directly breaks about 1 handshake in 256. `UKey2.magnitudeBytes` reproduces the reference behaviour, and `CryptoVectors` holds cross-checked cases.
- **Public-key validation.** `P256.KeyAgreement.PublicKey(rawRepresentation:)` doesn't check that a point is on the curve. Peer keys go through the X9.63 initialiser, which does, closing an invalid-curve attack.

Every Quick Share message is checked byte-identical against `GoldenFixtures`, captured from a reference encoder. That proves the wire format, but only a live transfer proves compatibility with a real phone.

## Why there is no auto-accept

Quick Share as implemented here has no verifiable device identity:
- UKEY2 keys are generated per handshake.
- The paired-key frames that carry identity in Google's implementation aren't in the public specification.
- The remote name is self-chosen.

So SWIFT always asks, and the 4-digit PIN on both screens is the check.

## Security notes

The network-facing parsers are the main attack surface. Frame and payload lengths, nesting depth, file counts, sizes, names and offsets are bounded. Received names are reduced to leaf names, writes stay inside the chosen folder, partial files use unpredictable temporary names, and finished files get the macOS quarantine attribute. Received links are saved as files, never opened. To report a vulnerability, see [SECURITY.md](SECURITY.md).

The Quick Share protocol was reverse-engineered by [grishka/NearDrop](https://github.com/grishka/NearDrop); see [ATTRIBUTION.md](ATTRIBUTION.md).
