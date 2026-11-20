# Abyssal Arcade MIDI: AUv3 plugin (source)

A physics-based MIDI generator for iPad and iPhone. Orbs bounce around an arena of tuned pegs; every collision
becomes a MIDI note, locked to the host's tempo and transport, quantised to a grid, swung and humanised, and kept
in key (D Dorian by default). Route the MIDI to any synth or sampler in a host such as AUM.

It is the same instrument as the web version (41 scales and modes, 54 chord progressions: 37 in key, 16 with chromatic root moves, and an 8-slot Custom editor): pegs, spawners, bumpers, gravity wells, chance and ratchet per peg,
spawner chance, swing, humanize, chord progressions, eight scenes, per-voice mute.

## What is verified and what is not

| Part | Status |
|---|---|
| `Shared/Engine` (physics, scales, progressions, quantise, swing, humanize, chance, ratchet, scenes, JSON state) | Built with Swift 6.0.3 on Linux and checked by `EngineSim`: 57 automated checks pass (see `ENGINE_TEST_RESULTS.txt`). Costs about 3 microseconds per 128-frame buffer. |
| `Extension/AudioUnit.swift`, `AudioUnitViewController.swift`, `ArcadeView.swift`, `App/` | Written against Apple's AudioToolbox / SwiftUI APIs and syntax-checked, **but not compiled or run**: there is no Xcode or iOS device where this was written. Expect to fix a few compile errors or API details on first build. |
| Behaviour inside real hosts (AUM, AudioBus, Loopy Pro, Logic for iPad, ...) | **Untested.** Host support for MIDI-processor ('aumi') plugins varies; check your host first. |

## Requirements

* A Mac with Xcode 14 or newer, and an Apple Developer account (the free tier can run on your own device for 7 days
  at a time; TestFlight and the App Store need the paid program).
* An iPad or iPhone on iOS 15 or newer. AUv3 plugins cannot run in the Simulator with real hosts, so test on a device.
* A host app that loads AUv3 **MIDI** plugins. AUM is the usual choice.

## Build it

### Option A: XcodeGen (quickest)

1. `brew install xcodegen`
2. Edit `project.yml`: set `DEVELOPMENT_TEAM` to your team ID and change both `PRODUCT_BUNDLE_IDENTIFIER` values.
   The extension's identifier **must** start with the app's identifier (for example `com.you.abyssal` and `com.you.abyssal.au`).
3. `xcodegen generate` and open `AbyssalArcade.xcodeproj`.
4. Select your device, choose the **AbyssalArcade** scheme, press Run. This installs the container app, which carries the plugin.

### Option B: by hand in Xcode

1. New iOS App project named AbyssalArcade (SwiftUI). Replace its sources with `App/AbyssalArcadeApp.swift` and `App/Assets.xcassets`.
2. File > New > Target > **Audio Unit Extension** (iOS), named AbyssalArcadeAU. Delete the template Swift/Obj-C/header files it generates.
3. Add `Extension/*.swift` and `Shared/Engine/*.swift` to the extension target only.
4. In the extension's Info.plist set `NSExtensionPrincipalClass` to `$(PRODUCT_MODULE_NAME).AudioUnitViewController` and
   under `NSExtensionAttributes > AudioComponents` use type `aumi`, subtype `Arcd`, manufacturer `Abys`, `sandboxSafe` = YES
   (copy the values from `project.yml`).
5. Set the extension's *Require Only App-Extension-Safe API* to Yes, Swift Language Version to 5.

## Use it

1. Run the app once so iOS registers the plugin.
2. In your host, add **Abyssal Arcade MIDI** as a MIDI plugin and route its MIDI output to your instruments.
   Default channels: Chug 1, Lead 2, Bass 3, Bell 4, Drums 10 (change them in the plugin).
3. Press play in the host. The beat strip at the top of the arena follows the host's position; spawners drop orbs on the grid.
4. No tempo from your host? Set **Sync** to *Internal clock* and use the plugin's own play/stop and tempo.

How the plugin behaves:

* **Transport:** it plays only while the host transport is moving. Stopping or jumping sends all-notes-off and clears the orbs.
* **Harmony** follows the host timeline (bar 1 is the first chord). Changing the progression or recalling a scene that has
  a different one restarts it at the current bar.
* **Scenes** switch on the next bar line while playing. They store pegs, spawners, gravity, swing, humanize, progression, and mutes.
* **State** (settings, arena, scenes) is saved in your host project through the Audio Unit's full state.
* Guitar ("Chug") sends root + fifth + octave by default; turn that off for single notes.
* **Custom progression:** choose *Custom* (last in the Progression menu) and eight slots appear. Each slot is a chord root in semitones from the tonic (-12...+12, "end" stops the list), so you can write moves like a tritone or a semitone slide. Every pitched voice follows it (drums don't). The list is saved with the plugin state; a scene that uses Custom stores its own list and restores it on recall (scenes that use another progression leave your Custom list untouched).

## Compile and test in Xcode (simulator or CI)

`project.yml` also defines an **ArcadeTests** target that compiles the extension's sources and runs on an iOS Simulator:
the real audio-unit render block against a fake host clock (MIDI timing, transport stop, state save/load), the SwiftUI
interface rendered off-screen (and checked for being non-blank), and the model (editing, scenes, Custom editor).

* Locally: `xcodegen generate`, then in Xcode choose the **ArcadeTests** scheme and press Cmd-U, or
  `xcodebuild test -project AbyssalArcade.xcodeproj -scheme ArcadeTests -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO`.
* Without a Mac of your own: push this folder to a GitHub repository. `.github/workflows/ios.yml` builds the app and the
  extension on a macOS runner, runs `EngineSim` and `ArcadeTests`, and uploads the logs and the `.xcresult` as artifacts.

These tests were written without access to Xcode and have not been run yet; the first build may need small fixes.

## Test the engine without Xcode

On macOS or Linux with Swift 5.9 or newer: `swift run -c release EngineSim`. It drives the engine with a fake host clock and
checks pitch, key, progression, quantise, swing, humanize, chance, ratchet, mute, channels, drums, spawner rate, scenes,
persistence, stuck notes after stop, and per-buffer cost.

## Files

```
Shared/Engine/Music.swift          scales, progressions, voices, pitch maths
Shared/Engine/ArcadeEngine.swift   physics + sequencing + MIDI scheduling (+ EngineHost: lock wrapper)
Extension/AudioUnit.swift          AUAudioUnit: transport, MIDI output, state
Extension/AudioUnitViewController.swift   AUv3 view controller / factory
Extension/ArcadeView.swift         SwiftUI arena and controls
App/                               container app (instructions screen, icon)
Tools/EngineSim/main.swift         engine test runner
Package.swift                      builds the engine + EngineSim only
project.yml                        XcodeGen spec
```

## Known limits and ideas

* No incoming-MIDI pass-through and no automatable parameters yet.
* The audio output bus is silent; it exists because some hosts only pull plugins that have one.
* Real-time notes: the render path takes a try-lock and never waits; it keeps its working memory reserved up front. It has not
  been profiled on a device, so run it with Xcode's Instruments (Time Profiler) if you hear glitches.
* Plugin window size is set by the host; the interface scrolls below the arena for small windows.
