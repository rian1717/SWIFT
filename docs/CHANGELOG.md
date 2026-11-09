# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/).
SWIFT uses semantic versioning after the first stable release.

## [Unreleased]

## [0.3.0] - 2026-11-09

### Changed

- The app is SWIFT. The Mac bundle id is `app.swift.mac`, the Android application id is `app.swift.clip`, clipboard discovery is `_swift._tcp`, and pairing links are `swift://clip`. Install both apps again and pair them once more. Quick Share discovery stays `_FC9F5ED42C8A._tcp`.
- A name you type for this Mac or this phone is the name other devices see. A shorter model name no longer replaces it.
- A finished transfer posts a notification. On the device that received the file, one tap opens it.

### Security

- Clipboard sync gives each phone its own key. Pairing works the key out on both sides without sending it, or the 8-digit code, over the Wi-Fi. Every copy is encrypted and numbered, so someone on the same network cannot read it, send their own, or replay an old one. A phone paired before this moves to its own key by itself, with no pairing again. Removing a phone deletes its key.
- A pairing link asks before it pairs, and shows which Mac it will pair with.
- The Android app no longer saves a file on its own. Every Quick Share transfer shows the PIN and Accept or Decline first, including from a paired Mac. No answer within 60 seconds is a decline. Clipboard sync is unchanged.

### Fixed
- A paired phone keeps its full name ("Rai's Pixel 8") when its screen wakes and the SWIFT app announces only the model ("Pixel 8").
- macOS no longer asks for Bluetooth and Local Network again after each new build. The app is signed as "app.swift.mac" rather than as one exact build, so the answers carry over to updates.
- A paired phone whose name grew from its model to its full name is no longer listed twice.
- The clipboard pop-up on the Mac says Copying and Copied.

- A phone added by scanning a QR code keeps its name even when it stops advertising right after the scan.

### Added
- SWIFT opens by itself when you log in and waits quietly in the menu bar, so a phone can find the Mac without opening the app first. The first run of an installed copy turns this on once, and **Open at login** in Settings turns it off.
- `SWIFT/Packaging/install.sh` builds the Mac app from source and installs it in one command, and says why when it cannot.
- The Android project has a Gradle wrapper, so `./gradlew assembleDebug` builds an installable app with no setup beyond Android Studio.

- A phone keeps its real name on this Mac once it has been seen or has sent a file, even if it hides its name later.
- Native Swift 6 menu-bar application for macOS 26 and newer
- Android Quick Share LAN discovery, UKEY2 handshake, encrypted transfer, and
  bidirectional streaming
- Drag-and-drop, file/folder picker, QR connection, transfer progress, and
  configurable receive destination
- Finder Share extension with live send progress, and opt-in localhost CLI/API
- Phone clipboard sync: an Android copy becomes the Mac pasteboard, so ⌘V pastes
  text, images, and files
- Headless real-device protocol probe
- Golden vectors, randomized parser tests, loopback integration tests, and
  deterministic performance tests
- Signed/notarized release automation

### Security

- Explicit consent and matching PIN required for every inbound transfer
- Bounded frame, payload, file-count, file-size, and parser-depth limits
- Safe destination names, temporary partial files, disk-space checks, and
  quarantine attributes

## [0.2.0] - 2026-11-07

### Changed

- Renamed identifiers for the first public release. Phones that paired before this version pair again.
