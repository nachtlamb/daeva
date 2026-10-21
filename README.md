# Daeva

A launcher for running AION 2 on Apple Silicon Macs through the native macOS Steam client.

Daeva sets up a Wine build (winecx-gptk with a patch that bridges the game to macOS Steam), imports Apple's D3DMetal from the Game Porting Toolkit, and registers a Steam Play compatibility tool. Once that's done, you launch the game from Daeva or from Steam like any other title.

## Installing

Download the DMG from Releases and drag Daeva to Applications. The app isn't notarized, so open it the first time with right-click → Open, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Daeva.app
```

Click **Set Up** and Daeva does most of the work itself. Three steps are up to you:

- Download the [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/) from Apple and drop the `.dmg` onto the Daeva window. D3DMetal can't be redistributed, so it gets imported from your copy.
- Install AION 2 in Steam.
- In Steam, open AION 2 → Properties → Compatibility and select **Daeva (winecx-gptk)**.

The first launch is slow while shaders compile.

## What gets changed

- `/Applications/Steam.app`: NotProton's Steam Play dylib is added and the app is re-signed ad-hoc. The original `Info.plist` is backed up. Steam updates can revert this, in which case Daeva will ask to redo it.
- `~/Library/Application Support/Steam/compatibilitytools.d/daeva`
- `~/Library/Application Support/Daeva`: engine, prefix, logs, settings

Daeva never signs you out of Steam and never runs the Windows Steam client.

## NC Guard

Rosetta can't execute NC Guard's 32-bit CPUID check, so without help the game hangs on the splash screen. Daeva includes [aion2-wine-compat](https://github.com/Yuki-fox/aion2-wine-compat), which handles that check the way Windows would. Game and NC Guard files are never modified, but this still alters how NC Guard runs, and NCSOFT doesn't support Macs. Use at your own risk. You can turn the fix off in Settings.

## Building

```sh
scripts/build-app.sh --dmg
```

CI builds a DMG on every push to `main`. When `VERSION` names a version that hasn't been released yet, it tags it and publishes the DMG as the latest release, which is what the in-app updater picks up. The engine tarball and `steam.exe` come from the `payload-4.7.903-daeva` release. aion2-wine-compat is built from source at a pinned commit.

The backend is a small Python package that also works from a terminal:

```sh
bin/daeva-engine doctor
bin/daeva-engine setup
bin/daeva-engine play
```

## License notes

See `licenses/NOTICE`.
