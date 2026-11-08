# SWIFT control API + `swiftapp` CLI

A guide for humans **and agents** to drive SWIFT (send/receive files with nearby
Android devices) from the command line or over HTTP.

## Prerequisites
- The **SWIFT.app must be running** (it hosts the API). It's a menu-bar app;
  launching it once is enough — it keeps running in the background.
- The API must be **enabled**: SWIFT > Settings > Automation > "Allow the
  swiftapp command line". It is **off by default** — while on, anything running
  under your account can ask SWIFT to send any file it can read to a nearby
  device.
- The API is **localhost-only** (`http://127.0.0.1:47821`), bound to `127.0.0.1`.
- Every request needs a bearer token, read from `~/.config/swift/token`
  (created by the app on first launch; file mode `0600`).

## CLI (recommended for agents)

```bash
swiftapp list [--json]                 # devices currently visible for sending
swiftapp send <file>... --to <name>    # send file(s); blocks until done
swiftapp status [--json]               # active/recent transfers
swiftapp --help
```

- `--json` prints raw JSON (parse this). Without it, output is human-formatted.
- `--to` takes a device **name** (from `swiftapp list`) or its `id`.
- `swiftapp send` **blocks until the transfer completes**, exits **0** on success,
  non-zero on failure (prints `✗ Failed: <reason>` to stderr).
- Paths may be relative or use `~`; they're resolved to absolute before sending.

### Agent recipe
1. `swiftapp list --json` → parse the array, pick a device by `name`.
2. `swiftapp send /abs/path/file.jpg --to "<name>" --json` → check `.ok == true`.
   The response also includes `.pin` (the verification code shown on the phone).

## HTTP API (for other languages / direct use)

Base URL `http://127.0.0.1:47821`. Header on every request:
`Authorization: Bearer $(cat ~/.config/swift/token)`

| Method | Path | Body | Response |
|--------|------|------|----------|
| GET | `/health` | — | `{"ok":true}` |
| GET | `/devices` | — | `[{"name","id","type","known"}]` |
| GET | `/transfers` | — | `[{"title","device","percent","phase"}]` |
| POST | `/send` | `{"paths":["/abs/f1",…],"to":"<name|id>"}` (or `"path":"/abs/f"`) | blocks, then `{"ok":bool,"pin":string?,"error":string?}` |

`type` is one of `phone` / `tablet` / `computer` / `unknown`.

### Examples
```bash
TOKEN=$(cat ~/.config/swift/token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:47821/devices

curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"paths":["/Users/me/pic.jpg"],"to":"Noise'\''s phone"}' \
     http://127.0.0.1:47821/send
# → {"ok":true,"pin":"8374","error":null}
```

### Status codes & errors
- `200` success · `400` bad request body · `401` missing/invalid token ·
  `403` bad `Host` header · `404` unknown path · `502` send failed.
- `/send` error strings: `device_not_found`, `no_readable_files`, `timeout`,
  `busy` (a send is already in flight — the flow is single-slot and shared with
  the window), `control_api_disabled` (switched off mid-transfer), or an engine
  message (e.g. `Declined`, `Connection lost`).

## Behaviour notes
- **Sending always needs the receiver to accept** (a PIN prompt on the phone).
  There is no auto-accept: Quick Share exposes no verifiable device identity, so
  `known: true` on `/devices` only means "you've accepted from that name before".
- Device `id`s can change between sessions; prefer matching by `name`.
- `/send` reuses the app's send flow, so an in-progress CLI send also shows in
  the app window.
- If `swiftapp` reports it can't reach the app, launch SWIFT.app and retry.
