# Troubleshooting

## The phone cannot see the Mac

1. Open SWIFT, choose Receive, and enable visibility.
2. Put both devices on the same non-guest Wi‑Fi network.
3. Grant SWIFT Local Network permission in System Settings.
4. Temporarily disconnect VPNs on both devices.
5. Disable router AP/client isolation.
6. Use SWIFT's QR/manual route when ordinary discovery is unavailable.

macOS cannot emit the BLE advertisement or provide the Wi‑Fi Direct behavior of
Google's complete implementation. SWIFT cannot remove that platform limit.

## The Mac cannot see the phone

Open Quick Share's receive screen on Android and make the phone visible. Keep
that screen open while SWIFT searches.

## The transfer connects but fails

- Confirm the four-digit PIN matches before accepting.
- Check free space on the receiving device.
- Keep both devices awake.
- Retry without a VPN or restrictive firewall.
- Check whether the file changed or moved after it was selected.

SWIFT removes incomplete incoming `.part` files automatically.

## Permission prompt never appeared

Development must run from a packaged `.app`; a bare `swift run` process may not
receive Local Network permission correctly:

```bash
SWIFT/Packaging/build-app.sh debug
open SWIFT/build/SWIFT.app
```

If permission was denied, enable it under System Settings → Privacy & Security →
Local Network, then relaunch SWIFT.

## The phone cannot find the Mac to pair clipboard

1. Keep SWIFT open on the Mac. **Paste phone copies here** is on by default in
   Settings.
2. If macOS asked to accept incoming network connections and you chose Don't
   Allow, open System Settings → Network → Firewall → Options and allow SWIFT.
3. On the phone, type the 8 digits from the Mac's Settings into the box and tap
   **Pair**, or paste the link from **Copy pairing link**. Both work when the
   list is empty.
4. Use one copy of SWIFT at a time. A second copy cannot take over the port or
   the Quick Share name.

## Clipboard does not paste

Follow the copy-and-paste steps in the README. The two locks that stop a first
install are:

**Play Protect blocks the app.** The dialog says the app can request sensitive
data, and the only button is OK. Open the Play Store, tap your profile, open
Play Protect, tap the gear, and turn off Improve harmful app detection. If that
switch is missing, turn off Scan apps with Play Protect. Install SWIFT,
then turn the switch back on.

**Clipboard access says “Controlled by restricted setting”.** Android locks
this because the app was installed from a file. Open Settings → Apps →
SWIFT, tap the three dots, and choose Allow restricted settings. Then open
Accessibility → Downloaded apps, tap SWIFT, and turn it on.

Pairing still needs the Mac switch on, both devices on the same Wi-Fi, and the
phone allowed to keep SWIFT running. Copy again, then press ⌘V.

iPhone copies do not use this path. They paste through Apple Handoff when both
devices are signed into the same Apple ID.

**Clipboard worked, then stopped, or the phone said "SWIFT keeps stopping".**
Update to 0.3.2 or later; versions before it hit an Android 15 time limit.
If the app says **Clipboard access stopped**, tap **Turn clipboard access on
again**, switch SWIFT off, then on. If the app shows **SWIFT stopped last time**,
tap it to copy the crash report and paste it into a GitHub issue.

## The iPhone page

**Safari says "took too long to respond" or "can't be reached".** Both phones
must be on the same Wi-Fi. The address under the code on Android should start
like your other devices' addresses on that Wi-Fi, often `192.168.`. If the
Android phone's Wi-Fi dropped, the code changes by itself within 2 seconds; scan
it again. With no Wi-Fi, SWIFT shows no code. A phone's own hotspot works too:
join it from the iPhone, then scan.

**Saving stops partway.** Keep Safari open on the iPhone and SWIFT open on
Android until the button says **Save all … to Photos**. A photo that stops
coming is asked for again by itself. If the button says **Try again**, the
Android phone stopped answering: check that it is still on the same Wi-Fi.

**Safari says "This Connection Is Not Private" after Save all to Photos.** That
is expected. The page comes from the Android phone on your Wi-Fi, and no
internet authority can vouch for a home address. Tap **Show Details**, then
**visit this website**, then **Visit Website**. Then tap **Save all to Photos**
and choose **Save** in the menu that opens.

**SWIFT says the phone's storage is full.** It keeps a copy of each photo
until you tap **New link** or close the app. Free some space, then send again.

**Only one photo at a time saves.** On the plain page, tap a photo, then touch
and hold it and choose **Save to Photos**. Use **Save all to Photos** for many.

## Report a compatibility problem

Open an issue with the [compatibility template](https://github.com/rian1717/SWIFT/issues/new/choose) and include:

- SWIFT version on the Mac and on the phone
- Mac model and macOS version
- Phone model, Android version, and Quick Share version
- What you tried, what happened, and what you expected
- Whether a VPN or a guest or client-isolated Wi-Fi was in use

Never attach file contents, API tokens, transfer PINs, or packet captures that contain private data.
