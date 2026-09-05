# Building Eddy

A live wallpaper for macOS. A GPU fluid simulation runs behind your desktop icons and
moves to whatever your Mac is playing.

- **Metal stable-fluids sim** (advection, pressure projection, vorticity confinement) on
  ping-pong textures, one per screen, rendered at the desktop window level.
- **Hears system audio** through a Core Audio process tap (macOS 14.2+), so it works
  with headphones and needs no screen-recording permission. Bass swells the smoke,
  beats detonate bursts, treble throws sparks, mids drift the hue.
- **Stays cheap**: rendering pauses whenever the desktop is fully covered, and the sim
  grid is 256 px wide regardless of screen size.

## Build

```sh
./build.sh            # → build/Eddy.app
./build.sh --install  # → ~/Applications/Eddy.app
```

Shaders compile at launch from the bundled `.metal` source, so no Metal toolchain
download is needed. Ad-hoc signed. First launch asks for system-audio permission.

## Checks

```sh
build/Eddy.app/Contents/MacOS/Eddy --selftest   # FFT band analyzer: 60 Hz → bass, 4 kHz → high
build/Eddy.app/Contents/MacOS/Eddy --levels     # print what the tap hears for 5 s
```

## Tuning

All the taste knobs live in `Tuning` at the top of `Sources/Fluid.swift`: sim/dye
resolution, dissipation, emitter force, beat burst size, sparkle rate.
