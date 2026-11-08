# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Send a private report
to the repository maintainers with:

- the affected version and macOS/Android versions;
- reproduction steps or a minimal proof of concept;
- expected impact;
- any suggested mitigation.

Please allow 90 days for coordinated remediation before public disclosure.

## Security model

SWIFT accepts untrusted traffic from the local network. Every inbound frame,
device name, file name, declared size, and payload is treated as attacker
controlled.

- UKEY2 establishes per-transfer keys and a verification PIN.
- The user must verify the PIN and accept each transfer. Device names are not
  identities and never authorize automatic acceptance.
- Incoming lengths and collection counts are bounded before allocation.
- Received names are reduced to safe leaf names and cannot choose a directory.
- Files are written to temporary names and moved into place only after success.
- URLs and text are saved as files; SWIFT never opens received content.
- The optional localhost control API is disabled by default and token protected.
- Clipboard sync is off until enabled. The listener accepts only private LAN
  addresses, on Wi-Fi or Ethernet. A phone that knows the 8-digit code can
  pair. A phone that does not is refused until the person at the Mac taps
  Allow. The pairing QR carries that code, not the long-lived token. Only a
  paired phone that then presents the token can replace the Mac pasteboard.
  Payloads are size-capped. File names cannot choose a directory. The copied
  text is not written to the system log.
- The iPhone photo page is served only to a private address, and only with a
  128-bit token from the QR code on the Android screen. Uploaded names cannot
  choose a directory. The page does not accept a public-network peer.
- Finder Share cannot open LAN sockets from its sandbox. It hands selected
  files to the running app over `127.0.0.1` and a shared secret. The listener
  rejects non-loopback peers. The secret is compile-time because the extension
  has no App Group; any local process that extracts it can ask the app to send
  files the app can read to a currently visible device.

- Nearby phones are remembered on this Mac as a self-reported name and the
  phone's Wi-Fi hardware address, so a phone that hides its name keeps a
  label. That name is only a label. It never skips the PIN or consent.

SWIFT does not provide anonymity, protection from a compromised endpoint,
or a trusted persistent identity for native Quick Share peers.

## Supported versions

Security fixes are provided for the latest published release. Until a signed and
notarized release exists, all builds are development previews.
