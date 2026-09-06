# Building Eddy

Plain `swiftc`, no Xcode project, no package manager.

```sh
./build.sh            # → build/Eddy.app
./build.sh --install  # → ~/Applications/Eddy.app
```

Shaders are compiled **at launch** from the bundled `Sources/Shaders.metal`, so no Metal
toolchain download is needed (the Xcode beta ships without one). A shader error shows up
when the app starts, or earlier if you run the checks below.

**Signing.** `build.sh` signs with the `Pratik Dev Signing` identity if it exists in your
keychain, otherwise ad-hoc. Set `CODESIGN_IDENTITY` to use your own. A stable identity
matters: macOS ties audio and microphone permissions to the code signature, and an ad-hoc
signature changes every build, which resets the grants and re-prompts.

**Icon.** `assets/icon.png` is the 1024 px master; `build.sh` turns it into `AppIcon.icns`.
To replace it from new artwork on a black square, run
`swift tools/makeicon.swift <artwork.png> assets/icon.png`: it cuts out the rounded square and
re-lays it on the transparent canvas with Apple's inset and corner radius.

## Layout

| File | What it is |
|---|---|
| `Sources/App.swift` | One desktop-level `NSWindow` per screen, the menu bar item and its menu. |
| `Sources/Renderer.swift` | Clock, audio smoothing, beat pulse; owns the current `Scene`. `ShaderScene` runs one fullscreen fragment shader. `preview()` renders every scene offscreen. |
| `Sources/Fluid.swift` | The Smoke scene: stable fluids on ping-pong textures. `Tuning` holds the knobs. |
| `Sources/Shaders.metal` | Fluid compute kernels, then the single-pass scenes (`scene_aurora`, `scene_lava`, …) and their shared `Uniforms`. |
| `Sources/AudioInput.swift` | Core Audio process tap (system audio) or `AVAudioEngine` (microphone) → `Analyzer`: 2048-point FFT, three bands with per-band auto-gain, beat counter. |
| `Sources/Settings.swift` | Scene, palette, intensity, source, reactive. Persisted in `UserDefaults`, read every frame. |

## Checks

```sh
build/Eddy.app/Contents/MacOS/Eddy --selftest         # FFT bands land where they should; every shader compiles; no scene renders black
build/Eddy.app/Contents/MacOS/Eddy --levels           # print what the system-audio tap hears for 8 s (levels + raw RMS/bands)
build/Eddy.app/Contents/MacOS/Eddy --levels --mic     # same for the microphone
build/Eddy.app/Contents/MacOS/Eddy --preview docs/scenes   # write <scene>.png for every scene (the README gallery)
```

Run `--levels` via `open -n -W --stdout out.log ~/Applications/Eddy.app --args --levels --mic`
when you need macOS to attribute the permission prompt to Eddy rather than your terminal.

## Adding a scene

1. Write `fragment float4 scene_<name>(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]])`
   in `Shaders.metal`. `u.audio` is bass/mid/high/gain (0..1, already smoothed), `u.beat`
   is 1 on a beat and fades, `u.palette.w` advances by one per beat, and `pal(t, u)` gives
   you the user's palette.
2. Add `case <name> = "<Name>"` to `SceneKind` in `Renderer.swift`.

That's it: the menu, settings and `--preview` pick it up.

## Tuning

- Fluid look: `Tuning` at the top of `Sources/Fluid.swift`.
- Palettes: `Palette.range` in `Settings.swift` (hue base, hue span, saturation).
- Audio: `Analyzer.tilt` (pink-spectrum compensation), `relativeFloor` (how far a quiet band
  may be boosted past the loudest one), `gateAboveNoise` (sound within this factor of the
  running noise floor counts as silence; the floor is the quietest RMS heard, drifting up
  slowly), and `systemFloor` / `roomFloor` (absolute minimum silence RMS and auto-gain floor per
  source). Room numbers were measured on a MacBook Pro's built-in mic; `--levels --mic` prints
  the raw values if yours differ.
