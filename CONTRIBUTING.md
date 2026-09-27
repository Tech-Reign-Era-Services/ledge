# Contributing to Ledge

Thanks for helping make Ledge better. You don't need to write code to contribute. Bug reports, testing on your Mac (especially Macs without a notch, and external displays), and better wording all count.

## Ways to help

| You want to… | Do this |
|---|---|
| Ask a question or get help | Start a [Discussion](https://github.com/Tech-Reign-Era-Services/ledge/discussions) in **Q&A** |
| Suggest an idea | Start a [Discussion](https://github.com/Tech-Reign-Era-Services/ledge/discussions) in **Ideas**. If it gets support, a maintainer turns it into an issue. |
| Report a bug | Open a [bug report](https://github.com/Tech-Reign-Era-Services/ledge/issues/new/choose) |
| Report a security problem | **Don't open an issue.** See [SECURITY.md](SECURITY.md). |
| Fix a bug or build a feature | Read on |

## Before you write code

- **Small fixes** (typos, clear bugs, wording): just open a pull request.
- **Anything bigger** (new features, new menu items, changed behavior): comment on the issue, or open one, first, and say how you plan to do it.
- **Dependencies:** Ledge has none, on purpose: no Swift packages, no JavaScript libraries, no build step for the page. Ask first before adding one.

## Set up

You need a Mac with the Xcode Command Line Tools (`xcode-select --install`) and git. Xcode itself isn't needed.

```bash
git clone https://github.com/<you>/ledge.git   # your fork
cd ledge
./build.sh test   # should pass before you change anything
./build.sh run    # build and open it (quits a running Ledge first)
```

**Keep your dev build apart from an installed Ledge.** They'd share a Shelf and fight over the notch. Quit the installed one first (menu bar icon → Quit Ledge), and run yours with its own folder:

```bash
LEDGE_DATA_DIR=/tmp/ledge-dev dist/Ledge.app/Contents/MacOS/Ledge
```

Useful while working:

- `LEDGE_DEBUG=1 dist/Ledge.app/Contents/MacOS/Ledge` logs every state change (closed, peek, open) to the terminal. Errors in the page are logged there too, as `[page] …`.
- `LEDGE_NO_NOTCH=1` behaves as on a screen without a notch (the floating pill), so you can work on it from a MacBook.
- `LEDGE_SNAPSHOT=/tmp/open.png LEDGE_STATE=open dist/Ledge.app/Contents/MacOS/Ledge` draws the island in that state to a PNG and quits. Handy for before and after screenshots.
- Only the installed app (in `/Applications`) turns on Open at Login by itself, so your dev build in `dist/` won't start with your Mac.

## How the code is organised

- `web/`: the island itself, in plain HTML, CSS and JavaScript with no framework. `shelf.js` draws and animates it; `bridge.js` is the **only** way it can reach the app. Keep that list small and explicit.
- `Sources/Island.swift`: the panel over the notch, its states and sizes, and the other end of the bridge.
- `Sources/Native.swift`: drag detection, the global shortcut, thumbnails, the clipboard and Quick Look.
- `Sources/Layout.swift` and `Sources/ShelfStore.swift`: where the island sits, and the items. No AppKit, so they're tested directly.
- `Sources/App.swift`: the menu bar icon, Open at Login, `ledge://` URLs, and bringing Inlet's Shelf across.
- `Sources/Activities.swift`: live activities: what's accepted from other apps and music players, and the list. No AppKit, so it's tested directly. `Sources/LiveActivities.swift` listens for them, runs the music controls and draws icons.
- `tests/main.swift`: the tests (the Command Line Tools have no XCTest, so it's a small executable).

## Ground rules

1. **Never touch the files.** The Shelf only points to files. It never copies, moves, renames or deletes them.
2. **No network.** Ledge makes no network requests at all. Keep it that way.
3. **Stay small and light.** No dependencies. `./build.sh check` fails if the app grows past its size budget, and CI runs it. Don't add work that runs while the Shelf is idle: nothing polls unless a mouse button is down or the island is open.
4. **Treat live activities as untrusted.** Any app on the Mac can post one. New fields get validated and trimmed in `Activities.parse`, with a test, and links never reach the page.
5. **Keep the page safe.** File names and text are untrusted: build elements with `h()`/`textContent`, never `innerHTML`. Keep the content security policy, the `ledge://` scheme and the navigation block as they are. New bridge commands act on item ids, never on paths the page supplies.
6. **The design is the design.** The island's look and animations come from Inlet. Changes to them should be deliberate, with before and after screenshots.

## Style

- Match the code around you. Swift: 4-space indentation, `final class`, small focused types. JavaScript: plain modern JavaScript, 2-space indentation, single quotes, semicolons.
- Explain *why* in comments, not *what*.
- Words people see speak plainly: "Copied 3 files", not "3 items written to pasteboard".

## Tests

- Changes to `Layout.swift` or `ShelfStore.swift` need a test in `tests/main.swift`. A bug fix should come with a test that fails without it.
- Tests use a temporary folder, never your real Application Support folder.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep a pull request to one change.
3. Make sure `./build.sh test` passes. GitHub runs the tests and a full build on every pull request, and keeps the built app for a week so reviewers can try it.
4. Fill in the pull request template. If the change is visible to users, add a line under a new heading at the top of `CHANGELOG.md`.

Maintainers squash-merge, so your commit history in a pull request doesn't need to be tidy.

## Releases

Only maintainers publish releases (see "Releasing" in the README). Contributors don't need to change `VERSION`.

## License

Ledge is [MIT licensed](LICENSE). By opening a pull request, you agree that your contribution is released under the same license.

## Code of conduct

Everyone taking part agrees to follow our [Code of Conduct](CODE_OF_CONDUCT.md). Be kind, assume good intent, and keep feedback about the work.
