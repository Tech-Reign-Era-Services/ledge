# Security policy

Ledge holds on to files, text and links you put on the Shelf, so we take problems that could lose, expose or misplace them seriously.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub instead:

1. Go to the [Security tab](https://github.com/Tech-Reign-Era-Services/ledge/security) → **Report a vulnerability**.
2. Describe what happens, how to reproduce it, and which version of Ledge and macOS you're using.

Only the maintainers can see your report. We aim to reply within 7 days, keep you updated, and credit you in the release notes unless you'd prefer not to be named.

## What counts

For example:

- Ledge moving, deleting or changing a file (it should only ever point to files, never touch them)
- A crafted file name, text or link on the Shelf that runs code, or reaches the island's page with more than the `window.shelf` functions in `web/bridge.js`
- The island's page loading anything from outside the app, or navigating away from `ledge://app/shelf.html`
- A live activity (from `ledge://activity` or the `com.techreignera.ledge.activity` notification) that gets past its limits, shows markup instead of text, or makes Ledge open a file or run a script
- Ledge sending anything over the network. Its only request is to download the album artwork of the song Spotify is playing, from the https link Spotify itself gives it; it sends nothing about you or your files

A bug where the Shelf doesn't open, or looks wrong, but loses nothing, is an ordinary [bug report](https://github.com/Tech-Reign-Era-Services/ledge/issues/new/choose).

## Supported versions

Only the latest release gets fixes. Please update before reporting.

## About unsigned builds

The release downloads are ad-hoc signed, not signed with an Apple Developer certificate, which is why macOS asks you to confirm the first time you open Ledge. Only download it from this repository's [Releases](https://github.com/Tech-Reign-Era-Services/ledge/releases) page, or build it yourself from source.
