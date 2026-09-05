# Eddy

Your desktop is a picture. It has been a picture since 1984.

Eddy fixes that. It fills the space behind your icons with slow, luminous smoke that
swirls, folds into itself and never repeats. Then you press play on a song, and the smoke
starts listening. Bass makes it bloom. Every kick drum sets off a burst. Hi-hats throw
sparks across the screen. The colours drift with the melody.

A wallpaper that is alive. That's the whole app.

![Eddy running behind the desktop icons](docs/screenshot.png)

## What it feels like

- **Silence.** Three plumes of colour wander the screen like ink dropped in water. Slow
  enough to ignore, pretty enough that you won't.
- **A song.** The plumes swell on the low end, detonate on the beat, and shed little
  sparks on the high notes. Loud tracks and quiet tracks both look right. Eddy adjusts.
- **Headphones on.** Still works. Eddy hears what your Mac plays, not what your room hears.
- **Deep focus.** Desktop buried under windows? Eddy notices and takes a nap. Your battery
  won't know it was there.

Your files, folders and widgets stay exactly where they are, floating on top of it all.

## Get it running

### The fast way: paste one line

Open **Terminal** (press ⌘ Space, type `Terminal`, press Return), paste this, press Return:

```sh
curl -L https://github.com/pratikaman/Eddy/releases/latest/download/Eddy.zip -o /tmp/Eddy.zip && ditto -xk /tmp/Eddy.zip /Applications && open /Applications/Eddy.app
```

It downloads Eddy, tucks it into your Applications folder and opens it. Your Mac will ask
you one question (see below), and then your desktop is moving. Thirty seconds, start to
finish.

### The gentle way: four clicks

1. [Download Eddy](https://github.com/pratikaman/Eddy/releases/latest/download/Eddy.zip).
2. Double-click the file to unpack it. Drag **Eddy** into **Applications**.
3. Open Eddy. Your Mac will grumble that it can't check the app for malicious software.
   That's because Eddy is homemade rather than from the App Store. Open **System Settings →
   Privacy & Security**, scroll to the bottom, click **Open Anyway**, then open Eddy again.
4. Click **Allow** when asked about audio. Done.

## Your Mac will ask two things. Here's what to say.

**"Apple could not verify Eddy is free of malware."**
Only appears if you downloaded with a browser. Click **Done**, then **System Settings →
Privacy & Security → Open Anyway**. The one-line install skips this entirely.

**"Eddy would like to record this computer's audio."**
Click **Allow**. This is how Eddy hears the music. Nothing is recorded, nothing is saved,
nothing leaves your Mac. Eddy listens to the rhythm of the moment and forgets it
instantly. Click **Don't Allow** and Eddy still runs, just drifting calmly, deaf to the beat.

## The little wave in your menu bar

Look at the top of your screen for a small wave icon. Click it.

- **Pause** freezes the smoke mid-swirl. **Resume** lets it breathe again.
- **React to Audio** is on by default. Switch it off for the quiet drift only.
- **Launch at Login** makes Eddy the first thing you see every morning.
- **Quit Eddy** and your old wallpaper is back, exactly as you left it.

## Fine print, the short kind

- Made for Macs with Apple silicon running macOS 14.4 or newer.
- Eddy paints over your wallpaper. It never touches the picture underneath.
- More than one screen? Each gets its own pool of colour, moving on its own.
- Nothing is recorded, stored or sent anywhere. Ever.

## Want to look inside?

Curious how the smoke is made, or want to make it pinker, faster, wilder? Everything you
need is in [BUILDING.md](BUILDING.md). The knobs are all in one place and they're labelled.
