# Changelog

What's new in each release, newest first. Written for people using Ledge, not for developers.

## 1.6.0

- **A todo list in the notch.** Press ⌘T in the Shelf (or the checklist button beside the pen) and type what you have to do. Each todo is a line with a circle: click it to tick it off, and it drops below the ones still waiting, struck through, until you × it away or choose **Clear Ticked Off** in the menu bar. Closed, the island shows a green tick and how many are still to do, beside the number of things on the Shelf.
- **Say a todo.** Press **⌃⌥T** (or the microphone in the island) and talk. The island opens, bars move with your voice, the words appear as you say them, and when you stop talking it goes on the list. **Esc** cancels. macOS's own recogniser does the work **on your Mac** — nothing is sent anywhere, nothing is recorded, and there's no model to download: Ledge is still about 1.4 MB. macOS asks once for the microphone and once for speech recognition.
- **Ask Siri.** Say "Ledge todo" and Siri asks what to add. "What's on my Ledge list" reads back what's still to do, "Tick off a todo in Ledge" marks one done, and "Open my Ledge" opens the island. The same four actions are in Shortcuts and Spotlight, so you can put them in a shortcut of your own or on a Stream Deck.
- **Set Up Siri…** in the menu bar icon, for when Siri doesn't know the phrases yet. macOS can take a restart to pick them up after Ledge is first installed; in the meantime, a shortcut of your own built from Ledge's "Add a Todo" action works straight away, and Siri runs any shortcut by its name. The menu item shows the three steps and opens Shortcuts.
- **Anything that can open a URL can add one too**: `open -g "ledge://todo?text=Buy%20milk"`, and `ledge://todo/done?text=milk` to tick it off. Asking for something already on the list doesn't add it twice.

## 1.5.0

- **Text with pictures, for remote desktops.** Copy from Notes, Mail, TextEdit, Pages or Safari and press ⌘V in the Shelf: the text becomes notes and each picture becomes an image file, in order. AnyDesk and other remote desktops pass text and files, but drop pictures inside text, so now you can take the pictures across too: select one and ⌘C, or drag it over. Pasted pictures are deleted when you remove them from the Shelf.
- **Ledge no longer keeps your Mac awake when no music is playing.** While the music bars listen to a song, macOS keeps the Mac awake, and Ledge could keep listening after the music had stopped: when the player quit without saying so, when the sound went silent, or with the display off. Now it lets go in each case, and starts again when the music does.

## 1.4.0

- **Update from inside Ledge.** Choose **Check for Updates…** in the menu bar icon, or let Ledge check once a day (Settings → Updates). A new version shows in the island: click it, and Ledge downloads the installer, makes sure it's exactly the one on GitHub, and opens it. Ledge quits, updates and opens again, and what's on your Shelf is kept.

## 1.3.0

- **Quick notes.** Click the notch and start typing: a note box opens straight away. Press ⏎ to keep the note on the Shelf, ⇧⏎ for a new line, or Esc to cancel. Kept notes work like any text on the Shelf: drag them out, ⌘C, or × to clean them up. There's also a pen button beside Copy all.

## 1.2.0

- **The music bars move to the music itself.** Each bar follows part of the sound, bass to treble, straight from Apple Music or Spotify. macOS asks once to allow System Audio Recording; nothing is recorded or saved. Needs macOS 14.2 or later; otherwise the bars dance as before.
- **The album artwork** shows in the island while a song plays.
- **Music that was already playing** when Ledge starts now shows straight away.
- **Settings** (menu bar icon → Settings…, or ⌘,): the pill's widths, height and gap from the top, the open island's width, whether it opens on hover and how soon, the album artwork, the music bars and their colour. The pill follows each change as you make it.
- **Play, pause and a new song change the island once**, the way the iPhone does, instead of redrawing it two or three times.
- **Brighter buttons**: Copy all, Clear and the other text in the Shelf are white instead of grey.
- **On a screen without a notch**, the pill is always there, small when there's nothing to show, so you can always find it and drop onto it.

## 1.1.0

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
