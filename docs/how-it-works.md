# How Stepover works

Stepover is CodeWeavers' published CrossOver Wine source, built unmodified, plus Apple's D3DMetal,
DXMT and DXVK, and open replacements for the two closed parts of CrossOver that games rely on:
per-program graphics picking and the bottle app.

## Layout

| Path | What |
|---|---|
| `runtime/` | Build scripts: `build-deps.sh` (x86_64 gmp, nettle, gnutls, freetype, SDL2, MoltenVK, FFmpeg), `build-wine.sh` (CrossOver 26.3 Wine, unpatched), `build-dxvk.sh` (CodeWeavers' DXVK 1.10.3 plus two header fixes in `patches/dxvk`), `install-runtime.sh` (assembles the runtime and its `licenses/`) |
| `compat/stepovercompat.c` | `cxcompatdb.so`: the per-program graphics picker inside Wine |
| `app/` | Swift package: `StepoverKit` (library), `stepover` (command), `StepoverApp` (the Mac app); `build-app.sh` builds and installs both |
| `release/make-release.sh` | Release files and the Homebrew cask; `release/publish.sh` uploads them |
| `downloads/`, `sources/`, `build/` | Source archives, extracted sources, build output (about 2.5 GB; only needed to rebuild) |
| `~/Library/Application Support/Stepover/Runtimes/cx26.3` | The installed runtime (`VERSION` says what is in it) |
| `~/Library/Application Support/Stepover/Bottles/<name>` | Bottles: a Wine prefix plus `stepover.json` and the generated `stepover-compat.conf` |
| `~/Library/Logs/Stepover/<bottle>.log` | Wine output per bottle |
| `~/Applications/Stepover/<game>.app` | Per-game Mac launchers (`stepover make-app`) |

## Per-program graphics picking

CrossOver's Wine (`dlls/ntdll/unix/loader.c`, "CW Hack 24067") `dlopen`s `cxcompatdb.so` from its
own folder in every Wine process, before the program starts, and exports `prepend_dll_path()` for
it. CrossOver ships a closed, signed-database plug-in there; Stepover ships `compat/stepovercompat.c`
instead. It reads `$STEPOVER_COMPAT` (the bottle's `stepover-compat.conf`), matches the program's file
name, prepends `lib/d3dmetal/wine`, `lib/dxmt` or `lib/dxvk` to the DLL path, sets
`CX_ACTIVE_GRAPHICS_BACKEND` (win32u reports WDDM 2.7 scheduling caps for D3DMetal) and the
program's extra variables, and appends any `args =` (raw ASCII text) to the process's command line
in the PEB, before the program reads it. `args` work for 64-bit programs only: for 32-bit ones Wine
builds the WoW64 copy of the command line before the plug-in loads. Because it runs per process, a game started by its launcher gets its
own backend. `STEPOVER_COMPAT_DEBUG=1` logs each decision.

## Built-in fixes

`BuiltInFixes.swift` lists per-program rules that every bottle gets, beneath the bottle's own
`stepover.json` (a bottle's rule wins on graphics and environment; arguments add up;
`"builtInFixes": false` in a bottle's `stepover.json` turns them all off). The first:
Steam's `steamwebhelper.exe` gets `--in-process-gpu`. Current Steam's Chromium draws from its GPU
process into a window the main browser process owns, and Wine's Mac driver drops drawing across
processes (a window surface lives in its owner's process), so the Steam window stayed black on
every graphics backend. With the GPU work in the browser process, Steam runs GPU-accelerated on
D3DMetal.

## The fix list

Per-game fixes are JSON files (format and safety rules: `fixes/README.md`). `FixLibrary` loads them
in this order, later ones winning: the official list (downloaded from the repository's `fixes/`
folder into `<Fixes>/Sources/official`, else the copy inside Stepover.app), sources the user adds
(`<Fixes>/sources.json`), and the user's own folder `<Fixes>/Local`. Invalid fixes are skipped;
flagged items (ones that could run commands) are left out unless the source is trusted or the fix is
the user's own.

A fix matches a bottle by Steam app ID (`SteamLibrary` reads Steam's `appmanifest_*.acf` files and
`libraryfolders.vdf` inside the bottle) or by program file name. Its graphics, environment and DLL
settings go into `stepover-compat.conf` beneath the bottle's own rules; the plug-in applies DLL
overrides with ntdll's exported `add_load_order_override()` and writes environment variables into
the Windows environment block as well as the Mac one (Windows programs read the block, which Wine
builds before the plug-in loads). Components (winetricks) and registry values are installed by
`Launcher.applyFixes` before a program starts, once per bottle, only for games actually present.

`fixes/tools/import-protonfixes.py` converts umu-protonfixes Steam fixes that are plain data into
`fixes/proton/`; files with logic are skipped. `.github/workflows/fixes.yml` checks pull requests
with the checker built from the base branch and merges the clean ones.

`GraphicsPicker` chooses when a program is added: a few known games first, then the exe itself:
64-bit DirectX 11/12 gets D3DMetal, 32-bit DirectX 10/11 gets DXMT (D3DMetal is 64-bit only),
DirectX 9 and older gets WineD3D.

## What the launcher sets (CrossOver parity)

`USER=crossover` (CrossOver bottles keep `C:\users\crossover`; Wine derives the profile from `USER`),
`CX_APPLEGPTK_LIBD3DSHARED_PATH`, `ROSETTA_ADVERTISE_AVX=1`, `DOTNET_EnableWriteXorExecute=0`,
`WINEDEBUG=-all`, then the bottle's and the program's variables. MSync is on only with
`WINEMSYNC=1`, as in CrossOver (CrossOver 26.3 has no ESync). With MetalFX on, D3DMetal's
`nvngx.dll`/`nvapi64.dll` are copied into the bottle's `system32` (Apple's Read Me; originals kept as
`*.stepover-orig`).

Wine redoes a bottle's whole setup when `wine.inf`'s mtime differs from the bottle's
`.update-timestamp`. That is slow, and in a bottle with native .NET it can stop on a .NET error
dialog. `stepover.json`'s `setupInf` records the SHA-256 of the `wine.inf` the bottle was set up with,
so a runtime with an identical `wine.inf` (only its date differs) skips the redo.

## Installing software

`Install Windows Program` (`stepover install`) runs a setup `.exe` or `.msi`, waits for it and every
process it started (`wineserver -w`), then adds the programs whose Start Menu or desktop shortcuts
appeared. Components (`stepover components`) are winetricks verbs run with the bottle's own Wine.

## The runtime download

The app is small; the runtime (`stepover-runtime-<name>.tar.xz`, about 290 MB, 1.1 GB unpacked) is a
release file named with its SHA-256 in `Stepover.app/Contents/Resources/runtime.json`. The app (or
`stepover runtime install`) downloads it once, checks the hash, unpacks it into
`~/Library/Application Support/Stepover/Runtimes/` and clears any quarantine flag.

## Rebuild

    runtime/build-deps.sh && runtime/build-wine.sh && runtime/build-dxvk.sh && runtime/install-runtime.sh
    app/build-app.sh
    cd app && swift test

`install-runtime.sh` keeps the previous runtime as `cx26.3.old`. For a new CrossOver source drop,
change `CX_VERSION`/`CX_SHA256` in `runtime/config.sh`; for a new D3DMetal, point
`STEPOVER_GPTK_DMG` at Apple's Game Porting Toolkit disk image (free Apple developer download).
Building needs Xcode, Rosetta and Homebrew's mingw-w64, bison, flex, ninja, cmake, pkgconf,
autoconf, automake, libtool, llvm, lld, nasm, meson, glslang and freetype.

## Environment

`STEPOVER_HOME`, `STEPOVER_BOTTLES`, `STEPOVER_RUNTIMES`, `STEPOVER_RUNTIME`, `STEPOVER_LOGS`,
`STEPOVER_LAUNCHERS`, `STEPOVER_CROSSOVER_BOTTLES`, `STEPOVER_CROSSOVER_APP`, `STEPOVER_CLI`,
`STEPOVER_WINEDEBUG`, `STEPOVER_COMPAT_DEBUG`, `STEPOVER_D3DMETAL_DIR`, `STEPOVER_DXMT_DIR`,
`STEPOVER_DXVK_DIR`, `STEPOVER_WINETRICKS`, `STEPOVER_RUNTIME_MANIFEST`, `STEPOVER_RUNTIME_URL`;
build and release: `STEPOVER_SRC`, `STEPOVER_BUILD`, `STEPOVER_DOWNLOADS`, `STEPOVER_GPTK_DMG`, `STEPOVER_APP`,
`STEPOVER_BIN`, `STEPOVER_BUNDLE_ID`, `STEPOVER_VERSION`, `STEPOVER_SOURCE_URL`, `STEPOVER_SPONSOR_URL`, `STEPOVER_RUNTIME_JSON`,
`STEPOVER_GITHUB_REPO`.

## Not included

GStreamer (Wine 11's FFmpeg path, `winedmo`, decodes media instead), most of CrossOver's per-game
hack database (Stepover's open fix list grows instead), and its anti-cheat integration.
