# Changelog

What's new in each release, newest first. Written for people using Ledge, not for developers.

## Unreleased

- **Live activities, like the Dynamic Island on iPhone.** While Apple Music or Spotify plays, the island shows the app and bars that dance to the music. Hover for the song, a progress bar, and play, pause and skip. (The first time you use a control, macOS asks whether Ledge may control the player.)
- **Other apps can show what they're doing** in the island, like a build, an upload or a timer, with progress. See "Show your app in the island" in the README.
- **On a screen without a notch**, like an external display on a Mac mini or Mac Studio, the island is now a floating pill in the middle of the menu bar that appears when something is live or on the Shelf.

- Uses no CPU at all while it's waiting. Before, the Shelf kept redrawing animations you couldn't see, which cost a few percent of CPU and some battery all day.
- Pictures of your files are ready before you open the Shelf, instead of filling in as it opens.
- Opens a little sooner when you drag something towards the notch.

## 1.0.0

The Shelf from [Inlet](https://github.com/Tech-Reign-Era-Services/inlet), as its own small app. It looks and works just the same.

- Drag files, folders, text or a link towards the notch: the Shelf opens before you get there, so there's room to drop. With it open, ⌘V adds whatever you copied.
- Hover over the notch, press ⌃⌥S from any app, or choose Show Shelf in the menu bar to open it.
- Drag items out to Finder, Mail, Slack or a browser upload box. Or select them, press ⌘C, and ⌘V anywhere pastes the files themselves.
- Space previews with Quick Look, and ← → flip through.
- Files stay where they are: the Shelf only points to them. On a Mac without a notch, it sits in the middle of the menu bar.
- Anything on Inlet's Shelf comes across the first time you open Ledge.
