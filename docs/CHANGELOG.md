# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/).
SWIFT uses semantic versioning after the first stable release.

## [Unreleased]

## [0.3.2] - 2026-11-17

### Fixed

- Clipboard stopped working after about a day, and some phones showed "SWIFT keeps stopping". Android 15 gives a "data sync" background service 6 hours a day, then stops the app, and the app crashed again each time it came back. SWIFT now runs as a connected-device service, which has no daily limit, and a refusal from Android can no longer crash it.
- A download that an iPhone cut off halfway, or a photo that could not be read, could stop the whole Android app.
- The iPhone page broke at around 17 photos. It showed every photo at full size, which ran Safari out of memory, and refused connections past the eighth. It now shows small previews and has no limit on how many.
- The QR code could hold the phone's mobile-data address instead of its Wi-Fi address (both often start with 10.), so Safari timed out. SWIFT now gives out only a Wi-Fi or hotspot address, never mobile data or a VPN, and the code updates by itself within 2 seconds when Wi-Fi changes. With no Wi-Fi it shows no code and says so. The same fix applies to how the Mac finds the phone.
- Photos could stop partway to the iPhone. Spare connections that Safari opens held the phone's threads for a minute each; now a connection that asks for nothing is closed after 10 seconds. Wi-Fi is kept awake while photos move, and Android can no longer delete the copies when the phone runs low on storage.
- In the background the phone now asks the Mac once a minute, not every 2 seconds, and never with the screen off.
- The app showed the Mac as set up even when the Mac was asleep or on another network. The Mac card now shows live whether it answers: Connected, or Not on this Wi-Fi.
- When the Mac got a new address from the router, the phone could keep using the old one. It now searches the whole network for the Mac, and that search no longer waits on itself and stops.

### Added

- **Save all to Photos** on the iPhone page, straight into Photos, not Files. One tap saves up to 100 photos or 300 MB, so a typical set of 72 goes in one tap. Photos load four at a time with real progress, a broken one resumes where it stopped, and the iPhone screen stays on while they load. If Safari takes fewer at once, the page halves the batch without downloading anything again. Safari allows this only on a secure page, so it warns once: tap Show Details, then visit this website.
- **Save all to Gallery** when the page is opened in Chrome on another Android phone. The photos land in the Download album, which Google Photos and every gallery show.
- The iPhone page keeps **Save all** and **Send to Android** at the bottom of the screen, so a long grid never hides them. Sending from the iPhone retries a file that fails.
- A new Android app layout in the style of Quick Share: two tabs, **Mac** and **iPhone**, rounded cards, and light or dark to match the phone. The iPhone QR code is small and fixed. Pairing a different Mac, removing the Mac and the crash report are in the ⋮ menu; tap the phone name to change it. Clipboard setup shows only what still needs doing.
- When the phone's storage is full, SWIFT says so instead of quietly adding fewer photos.
- Videos go to and from the iPhone, not only photos.
- SWIFT is in Android's Share menu. Pick photos or videos in Google Photos or any app, tap Share, then SWIFT, and the QR code for the iPhone opens with them ready.
- If SWIFT ever crashes, the app offers to copy the crash report the next time it opens.
- The app says when clipboard access is switched on in Settings but Android has stopped it.

## [0.3.1] - 2026-11-11

### Fixed

- A new install now works without hunting for a switch. **Paste phone copies here** is on by default, so the phone can find the Mac and pair straight away. Anyone who already turned it off keeps it off.
- Clipboard kept failing after a phone was removed and paired again. A name left over from the removal ("Rai's Pixel 8") made the Mac refuse every copy from the re-paired phone and tell it that it had been removed. A phone with its own key is now judged by its key, not its name, and pairing again clears the old removal under the short or the long name.
- Removing a phone on the Mac now deletes its key even when the Mac shows it under a longer name than the one it paired with.
- Find Mac no longer loses a Mac or lists it twice, and it still finds the Mac on a router that blocks the usual discovery, by asking the addresses on the Wi-Fi directly.
- A phone whose Mac changed address on the router finds it again and keeps copying, without pairing again.
- The Mac's pairing QR code carries a real Wi-Fi address. It skips unplugged and virtual networks, and no longer assumes the Wi-Fi is `en0`.
- The Mac no longer gives up when its clipboard port is busy. Two copies of SWIFT can no longer fight over it: opening a second copy shows the one already running.

### Added

- **Copy pairing link** in the Mac's Settings, next to the QR code.
- The phone's pairing box takes the pairing link, a link inside a chat message, or just the 8 digits typed with or without a space. The button is now called **Pair**.
- A clearer message when no Mac is found, with the macOS firewall step.


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
