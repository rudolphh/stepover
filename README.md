# Stepover

Run Windows games on Apple Silicon Macs. Stepover uses the same Wine as CrossOver, built unmodified
from the source CodeWeavers publishes, together with Apple's D3DMetal (DirectX 11/12 to Metal, with
MetalFX upscaling), DXMT and DXVK, and a Mac app for bottles, installers and per-game settings.

Free and open source. Not made, endorsed or supported by CodeWeavers or Apple.

> Everybody knows the crossover. The move people still replay came right after it: the step-back
> jumper in Game 1 of the 2001 Finals, then one slow step over the defender on the floor.
> Same Wine, one more move.

## Install

    brew trust --tap rudolphh/stepover
    brew install --cask rudolphh/stepover/stepover

Homebrew 7 asks you to trust a third-party tap before it installs from it. Stepover is not notarized
by Apple (that needs a paid developer account), so the cask removes macOS's download flag and signs
the app for your Mac when it installs, as other unnotarized open-source Mac apps do.

The first time Stepover opens, it downloads its Wine runtime (about 290 MB) and checks its checksum.
New runtimes appear in the app as they're published and install next to the one you have; each bottle
picks its Wine version.

**Needs:** an Apple Silicon Mac, macOS 15 Sequoia or later, Rosetta 2
(`softwareupdate --install-rosetta`), and Homebrew's `winetricks` (installed with the cask).

## Use

1. **New Bottle.** A bottle is a Windows folder for one or more games.
2. **Install Windows Program.** Pick the game's installer (`setup.exe` or `.msi`). When it
   finishes, the shortcuts it created become programs with a Play button.
3. **Graphics** is picked per program from what the `.exe` contains: 64-bit DirectX 11/12 runs on
   D3DMetal, 32-bit DirectX 10/11 on DXMT, older games on WineD3D. Change it per program, and turn
   on **MetalFX** for games with DLSS.
4. **Components** installs runtimes games ask for (Visual C++, .NET, DirectX extras, PhysX).
5. **Make Mac App** puts a launcher with the game's icon in `~/Applications/Stepover`.
6. **The Dock menu** (right-click Stepover in the Dock) has your recent games, every game by bottle,
   Run .exe… and Stop Everything. A running game is checked, with Bring to Front and Stop.

Bottle settings cover MSync, High Resolution Mode (full Retina pixels) and Windows scaling. CrossOver
bottles can be imported as instant copies; CrossOver's own bottle is not touched.

Everything also works from Terminal: `stepover help`.

## Fixes

Stepover applies per-game fixes automatically: graphics layer, environment variables, launch
options, DLL overrides, Windows components and registry values. The list is open: anyone can add a
fix for any game (**Share Fix on GitHub** on a program's menu opens a pull request; clean ones merge
automatically), keep their own (**Fixes > Open My Fixes Folder**), or publish their own list and add
it under **Fixes > Fix Sources**. It starts with fixes for the games tested here and 169 converted
from [umu-protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes). See
[fixes/README.md](fixes/README.md).

## What's different

- **Nothing to unlock.** No trial, no license key, no account. The code is GPL-3.0, and every source
  archive a release was built from is attached to it.
- **Graphics per program, not per bottle.** Stepover reads each `.exe` and picks D3DMetal, DXMT or
  WineD3D for it inside Wine itself, so a game started by its launcher still gets its own setting.
- **MetalFX in one switch** for games with a DLSS option.
- **Steam's window works.** Its web views draw in-process, which fixes the black window Steam shows
  under Wine on macOS.
- **An open fix list.** Anyone can add a fix for any game, and a clean one merges in under a minute.
  Add anyone else's list too. The checks guard only your Mac, never a company's rules.
- **Your settings win.** A fix never overrides what you set for a program or a bottle.
- **Bring your bottles.** Existing bottles come over as instant copies; the originals aren't touched.
- **Every Retina pixel.** High Resolution Mode gives games 3456x2234 instead of 1728x1117 on a 16-inch
  MacBook Pro, with Windows scaling per bottle to match.
- **A Mac app for every game,** with its icon, in `~/Applications/Stepover`.
- **A Dock menu that knows what's running:** recent games first, icons, and Bring to Front or Stop
  for a game that's already open instead of starting it twice.
- **All of it from Terminal too:** `stepover help`.
- **Checked downloads, careful updates.** The runtime is verified against a checksum built into the
  app, and an update waits until no game is running.

What it doesn't have: a support team, anti-cheat work (games with kernel anti-cheat will not run) or
years of per-game fixes. The commercial product this Wine comes from is the polished, supported
option, and buying it pays many of Wine's developers.

Stepover is young: so far it has been tested with Red Dead Redemption 2 (with Script Hook .NET mods),
Hi-Fi Rush, Escape from Duckov and L.A. Noire, each at the same frame rate as the commercial build of
this Wine, and with the Steam client (sign-in, store, downloads), which ran Stumble Guys at 117 fps.

## Support

Stepover is free, and every feature stays free for everyone. If it is useful to you, you can support
its development through [GitHub Sponsors](https://github.com/sponsors/rudolphh) (Help > Support
Stepover in the app). Sponsoring does not unlock anything, and Stepover is never sold: Apple's D3DMetal
is licensed for non-commercial use only. Adding a fix for a game you got running helps just as much.

## Licenses

Stepover's own code is GPL-3.0 (`LICENSE`). The runtime includes:

- Wine (LGPL-2.1-or-later), built unmodified from CodeWeavers' CrossOver 26.3 source; that archive
  and every other source Stepover compiles are attached to each release.
- Apple's D3DMetal (Game Porting Toolkit redistributables), included unmodified and **only for
  non-commercial use on Apple hardware**, under Apple's license. Stepover must never be sold.
- DXMT (MIT), DXVK (zlib), MoltenVK (Apache-2.0), FFmpeg, gnutls, nettle, gmp (LGPL), SDL (zlib),
  FreeType (FTL), Wine Mono and Wine Gecko.

Every license is in the app under Help > Licenses and Notices. "CrossOver" is a registered trademark of
CodeWeavers, Inc.

## Building from source

See [docs/how-it-works.md](docs/how-it-works.md).
