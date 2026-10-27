# Stepover

Run Windows games on Apple Silicon Macs. Stepover uses the same Wine as CrossOver, built unmodified
from the source CodeWeavers publishes, together with Apple's D3DMetal (DirectX 11/12 to Metal, with
MetalFX upscaling), DXMT and DXVK, and a Mac app for bottles, installers and per-game settings.

Free and open source. Not made, endorsed or supported by CodeWeavers or Apple.

## Install

    brew trust --tap rudolphh/stepover
    brew install --cask rudolphh/stepover/stepover

Homebrew 7 asks you to trust a third-party tap before it installs from it. Stepover is not notarized
by Apple (that needs a paid developer account), so the cask removes macOS's download flag and signs
the app for your Mac when it installs, the same approach Sikarugir uses.

The first time Stepover opens, it downloads its Wine runtime (about 290 MB) and checks it against the
checksum built into the app.

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

Bottle settings cover MSync, High Resolution Mode (full Retina pixels) and Windows scaling. CrossOver
bottles can be imported as instant copies; CrossOver's own bottle is not touched.

Everything also works from Terminal: `stepover help`.

## How it compares

- **CrossOver** is the polished, supported product, with a large database of per-game fixes, Steam
  support and installers that fetch what each game needs. CodeWeavers employs many of Wine's
  developers, and buying CrossOver funds Wine. Stepover runs the same Wine and the same graphics
  layers, without CrossOver's database, its anti-cheat work, or support.
- **Sikarugir** is mature, widely used and turns each game into its own app. Stepover's Wine comes
  straight from CrossOver's source, it picks the graphics layer per program inside a bottle (so a
  game started by its launcher gets its own), and it works with bottles the way CrossOver does.

Stepover is young: so far it has been tested with Red Dead Redemption 2 (with Script Hook .NET mods),
Hi-Fi Rush, Escape from Duckov and L.A. Noire, each matching its CrossOver frame rate, and with the
Steam client (sign-in, store, downloads), which ran Stumble Guys at 117 fps. Games with kernel
anti-cheat will not run.

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
