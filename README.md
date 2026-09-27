# Ledge

A Shelf in your Mac's notch. Keep files, text and links there for a moment, then drop them where they need to go.

- **Hover** over the notch to peek, **drag** anything toward it to drop it in, or press **⌃⌥S** to open it.
- Drag items out to Finder, Mail, Slack or a browser upload box. Or select them, press **⌘C**, and **⌘V** anywhere.
- **Space** opens Quick Look, just like in Finder. **⌘V** in the Shelf adds whatever is on the clipboard.
- Files are kept by reference: never copied, never moved. On a Mac without a notch, the Shelf sits in the middle of the menu bar.

The Shelf used to be part of [Inlet](https://github.com/Tech-Reign-Era-Services/inlet). The first time Ledge runs, it brings over anything that was on Inlet's Shelf.

## Why it's so small

Ledge is about 840 KB. Inlet's Electron build is 217 MB. The island is still the same HTML, CSS and JavaScript,
so the design and animations haven't changed, but it runs in the WebKit that ships with macOS instead of a bundled
Chromium. Everything else (the window over the notch, dragging, Quick Look, the clipboard, the shortcut) is a few
hundred lines of Swift, with no dependencies.

| | Inlet's Shelf (Electron) | Ledge |
|---|---|---|
| App size | 217 MB (the whole of Inlet) | 840 KB |
| Download | 217 MB `.pkg` | ~470 KB `.zip` or `.pkg` |
| Drag detection | a long-running `osascript` | a system mouse event, then a 50 ms check only while the button is down |

## Build

You need the Xcode Command Line Tools (`xcode-select --install`), not Xcode itself.

```sh
./build.sh          # dist/Ledge.app, universal (Apple silicon + Intel)
./build.sh run      # build and open it
./build.sh test     # run the tests
./build.sh dist     # also dist/Ledge-<version>.zip and .pkg
```

The build is ad-hoc signed, not notarized, so the first time you open it you may need to right-click › Open.

Requires macOS 13 or later.

## Layout

```
Sources/
  App.swift         menu bar item, shortcut, Open at Login, moving over from Inlet
  Island.swift      the panel over the notch, its states and sizes, and the page's bridge
  Native.swift      drag detection, the global shortcut, thumbnails, clipboard, Quick Look
  Layout.swift      where the island sits for each state (no AppKit, tested)
  ShelfStore.swift  the items and shelf.json (no AppKit, tested)
web/                the island itself: shelf.html, shelf.css, shelf.js (from Inlet), bridge.js
tests/main.swift    tests for Layout and ShelfStore
scripts/            the icon, and the installer's pre/postinstall scripts
```

Items are saved in `~/Library/Application Support/Ledge/shelf.json`.

For development, `LEDGE_DEBUG=1` logs state changes, and `LEDGE_SNAPSHOT=out.png LEDGE_STATE=open` draws the island
to a PNG and quits.
