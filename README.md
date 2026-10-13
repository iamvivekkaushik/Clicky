# Clicky

A macOS menu bar app that controls a Samsung **The Frame** TV over your local network. No cloud, no Samsung account.

It started as a Samsung port of an LG webOS menu bar remote. LG's picture sliders became Art Mode controls, since that's what The Frame does that other TVs don't.

## Tabs

| Tab | What it does | How it talks to the TV |
|---|---|---|
| **Now Playing** | TV mockup showing what's on screen (an app, an input or Art Mode with the current artwork), Art Mode switch, volume, favorite apps, named HDMI inputs | REST `:8001` app status, UPnP RenderingControl `:9197`, remote WebSocket `:8002` |
| **Remote** | D‑pad, Home/Back/Settings/Exit, media keys, pointer pad, channel ±, keyboard input, Source/Info/Guide. Arrow keys, Return and Delete work while this tab is open | `samsung.remote.control` WebSocket |
| **Apps** | Installed apps and named HDMI inputs; click to open, right‑click to quit, hide or add to favorites. The Now tab has Close for the app on screen | `ed.installedApp.get`, falling back to REST status probes on Tizen 6.5+ |
| **Art Mode** | Art Mode on/off, current artwork, matte style and color, your collection with thumbnails, drag‑and‑drop photo upload, delete, slideshow, art brightness, color tone, motion sensor and auto brightness | `com.samsung.art-app` WebSocket, plus a TLS socket for image transfers |
| **Cast** | AirPlay mirroring shortcut; plays a local video, song or photo on the TV | This Mac serves the file over HTTP; DLNA AVTransport on the TV pulls it |
| **Activity** | Screen time for today, 7 days or 30 days: per app, per input and Art Mode | Counted locally while the Mac is awake; stored in `~/Library/Application Support/Clicky/activity.json` |

The power button wakes the TV with Wake‑on‑LAN and turns it fully off with a long‑press `KEY_POWER`. A short press on The Frame only toggles Art Mode.

**Several TVs.** The arrows next to the TV name switch between saved TVs or add another. Each TV keeps its own pairing token, inputs, favorites, hidden apps and app list; Clicky controls one at a time. Screen time is shared across them.

## Build and run

Requires macOS 13+ and Xcode 15 (Swift 5.9).

```bash
scripts/build-app.sh --install
open /Applications/Clicky.app
```

Clicky was called FrameTV; on its first launch it picks up FrameTV's TVs, pairing, settings and screen time. The first launch finds TVs with SSDP. Pick yours, then choose **Allow** on the TV. The pairing token is stored in the `com.vivekkaushik.clicky.settings` defaults domain.

To turn the TV on from the Mac, enable **Settings › General › Network › Expert Settings › Power On with Mobile** on the TV.

## Sharing

```bash
scripts/package.sh
```

This writes `dist/Clicky-<version>.dmg`: a universal (Apple silicon + Intel) app, an Applications shortcut and `Read Me First.txt` with setup steps. The app is ad-hoc signed, not notarized, since that needs an Apple Developer ID. Gatekeeper therefore blocks the first launch: on macOS 15+ people allow it under System Settings › Privacy & Security › Open Anyway, on 13–14 with Control-click › Open. With a Developer ID certificate, sign with it and the hardened runtime instead of `-`, then notarize with `xcrun notarytool` and staple the DMG.

Bump `CFBundleShortVersionString` in `Resources/Info.plist` before sharing a new build.

## Probe mode

The same binary has a command-line mode for checking the protocols against a real TV:

```bash
swift build
.build/debug/Clicky --probe discover
.build/debug/Clicky --probe use 192.168.0.205
.build/debug/Clicky --probe tvs
.build/debug/Clicky --probe add 192.168.0.206
.build/debug/Clicky --probe switch 1
.build/debug/Clicky --probe forget
.build/debug/Clicky --probe pair
.build/debug/Clicky --probe status
.build/debug/Clicky --probe wake
.build/debug/Clicky --probe launch AprZAARz4r.Jellyfin
.build/debug/Clicky --probe close AprZAARz4r.Jellyfin
.build/debug/Clicky --probe art-raw get_artmode_settings
.build/debug/Clicky --probe upload-test
.build/debug/Clicky --probe snapshot ./snapshots
```

`upload-test` uploads a generated image to My Photos, reads it back and deletes it. `snapshot` renders every tab to PNG with live data. Set `CLICKY_DEBUG=1` to print raw WebSocket traffic.

## What Samsung doesn't expose locally

- **Current input.** The TV doesn't report the active source, so Clicky shows the input you last picked in the app until an app becomes visible.
- **Choosing an HDMI port.** `KEY_HDMI1`…`KEY_HDMI4` are ignored on Tizen 6.5. Plain `KEY_HDMI` switches to the last-used HDMI input, so every input button lands there. Fine with one HDMI device; with more, use the TV's Source menu.
- **Picture settings** (backlight, contrast and so on for TV mode). Only Art Mode display settings are available locally. SmartThings can switch picture modes, but its personal tokens now expire after 24 hours.
- **Volume** works through UPnP only on the TV speakers. With a soundbar on ARC, the ± buttons fall back to remote keys.

## Code map

```
Sources/Clicky/
  Net/        REST + SSDP + Wake-on-LAN, WebSocket channels, Art API + image transfer, UPnP, DLNA file server
  Model/      TVController (polling, state, actions), preferences, activity store, cast session, catalogs
  Views/      Menu bar popover and one view per tab
  Probe.swift Command-line diagnostics
```

Notes from testing on a 2022 Frame (QA50LS03B, Tizen 6.5, Art API 4.3.4.0):
- Art replies carry our `request_id` and are named after the request (`get_current_artwork`, not `current_artwork`). Transfer replies hold `conn_info` directly, with no `ready_to_use` event, and the image socket is TLS.
- The TV serves one image socket at a time; a second transfer while one is open fails with error `-1`. Transfers are queued.
- `get_content_list` lists a piece once per category: `MY-C0002` My Photos, `MY-C0004` Favorites, `MY-C0008` recently shown. User photos (`MY_F…`) appear in several categories, so lists are de-duplicated.
- A newly uploaded image has no thumbnail for a few seconds; the app shows a local preview instead.
- `ed.installedApp.get` and `ed.apps.icon` get no reply, and no REST or DIAL endpoint lists apps. Apps are found by probing about 220 known store ids over REST (`AppCatalog` plus community lists in `KnownApps.swift`), 8 at a time, and the list is cached. An app whose id isn't in those lists can't be found; add its id to `KnownApps.swift`. System apps answer 401 and are skipped. Apps open over REST; `ed.apps.launch` on the remote channel goes unanswered when the TV-side host is missing, and is only a fallback. `sdb shell 0 applist` would list everything, but only from the Developer Mode host IP.

## App icons

TVs that list their apps can supply icons themselves. When they don't, Clicky looks up the same app on Apple's public App Store API (`itunes.apple.com/lookup`) by a hard-coded App Store id. For apps outside the catalog it searches by name and accepts only an exact title match. Icons are cached in `~/Library/Caches/com.vivekkaushik.clicky/Images/`, so each one is fetched once. Only App Store ids or app names are sent. Apps with no iOS version (Samsung TV Plus, the Samsung browser) keep a branded tile.
- Power-on depends on how deeply the TV sleeps. For about 20 s after power-off it stays in network standby: REST reports `PowerState: standby` and the remote channel accepts connections, but Wake-on-LAN is ignored; a short `KEY_POWER` wakes it in about half a second. It then leaves the network, and for a few more seconds magic packets are lost. After that, Wake-on-LAN (broadcast or unicast) wakes it in about 2 seconds. The power button keeps sending whichever signal fits until REST reports `on`.
- After a power cut the art channel can be up with no TV-side host (`isHost: true` client) on it, and requests go unanswered. Clicky checks for the host and retries instead of waiting.
- App status over REST can time out while the TV is busy. Only a 404 means "not installed"; timeouts keep the cached entry.
