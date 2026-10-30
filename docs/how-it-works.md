# How Stepover works

Stepover is CodeWeavers' published CrossOver Wine source, with a few patches, plus Apple's D3DMetal,
DXMT and DXVK, and open replacements for the two closed parts of CrossOver that games rely on:
per-program graphics picking and the bottle app.

## Layout

| Path | What |
|---|---|
| `runtime/` | Build scripts: `build-deps.sh` (x86_64 gmp, nettle, gnutls, freetype, SDL2, MoltenVK, FFmpeg, libinotify-kqueue for folder-change notifications), `build-wine.sh` (CrossOver 26.3 Wine plus the patches in `patches/wine`), `build-dxvk.sh` (CodeWeavers' DXVK 1.10.3 plus two header fixes in `patches/dxvk`), `install-runtime.sh` (assembles the runtime and its `licenses/`) |
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
D3DMetal. Rockstar's `SocialClubHelper.exe` is Chromium too and gets the same argument.

Rockstar Games Launcher (matched by its full path, since other games ship a `Launcher.exe`) needs
Direct3D 10.1. D3DMetal doesn't offer it, and DXVK and wined3d's default Vulkan renderer need
geometry shaders MoltenVK lacks (wined3d on Vulkan stops at 9.3), so it runs on wined3d with
`WINE_D3D_CONFIG=renderer=gl`, which gives 10.1 on OpenGL.

Every bottle gets `C:\users\Public\Downloads` (when it's made and before each launch), which Windows
makes at setup and Wine doesn't (Rockstar's launcher service fails without `FOLDERID_PublicDownloads`).
Install and Add Game pick a program's graphics with the built-in fixes in mind, since a program's
backend wins over a built-in fix's.

## Wine patches

`runtime/patches/wine` holds Stepover's changes to the CrossOver tree; `build-wine.sh` applies them
(once; `build-wine.sh patch` only applies them). Today: Spatial Audio streams on a stereo device are
mixed down to two channels. Wine opened them with one channel per static object, and the macOS
driver keeps only the channels the device has, so center (dialogue), sides and backs were silent
(GTA V Enhanced). `runtime/check-runtime.sh` checks both this and folder-change notifications
(`ReadDirectoryChangesW`, which Epic's launcher and its install helper use to talk; Wine needs
libinotify for them on macOS).

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

## Adding games from an installer or folder

Spec: `docs/superpowers/specs/2026-10-29-add-game-from-folder-design.md`. A folder, a setup `.exe` or `.msi`, or an
`.iso` dropped on the Library window or the Dock icon, chosen with File > Add Game from Installer or Folder…, picked
in couch mode's Menu > Add a Game, or passed to `stepover add`, goes through `AddGame` in StepoverKit:

- **What it is** (`GameFolder.plan`): installers are told by what they hold (Inno Setup's loader signature
  `rDlPtS`, NSIS's `NullsoftInst`, `.msi`, else a `setup*`/`install*` name). A folder with several installers is one
  game: the base (the shortest cleaned name), then add-ons, then `patch*` updates in version order. A folder of
  installer folders is several games; a folder with no installer but a windowed `.exe` is an installed game, copied
  into the bottle (`cp -Rc`: an instant clone on the same disk). Archives, partial downloads and empty folders get one
  sentence each.
- **Which game** (`FolderName.clean`, `Recognize`): generic rules turn the folder's name into the game's ("Some.Game.
  v1.0.2-TAG" is "Some Game"); the cleaned name, the installer's file name and its version resource's product name
  are matched against the games list, then one Steam store lookup by the first name (the Library's rules). A game
  already in the Library offers Play or Install Again; anti-cheat with no single-player waits for Install Anyway.
- **Its bottle** (`AddGame.makeBottle`): 64-bit Windows 10, MSync on, High Resolution Mode at 96 DPI, Wine's menu
  builder off, and Documents, Desktop, Downloads, Music, Pictures and Videos as real folders inside the bottle (each
  with `.stepover-keep`), so no macOS access dialog can stall an install and saves stay with the game.
- **Running the installer** unattended: Inno Setup with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=… /LOG=…`,
  NSIS with `/S /D=…` through a one-line batch file (NSIS needs `/D=` raw, and Wine would quote it), MSI with `/qn`;
  anything else runs with its window ("The installer needs you"). The game goes to `C:\Games\<Game>`. Nothing is
  written into the dropped folder; `winebrowser.exe` is off so no installer opens a web page on the Mac, and Wine's
  audio driver is off while it runs, so installer music stays quiet (the game keeps its sound).
- **The watcher** (`InstallWatch`, every half second, sizes every 10 s) looks at the bottle's processes and the
  installer's own (which run in the installer's folder, outside the bottle):
  - redistributable installers and checksum tools that hang under Wine (`dxwebsetup.exe` and the `dxwsetup.exe` it
    unpacks, `vc_redist*.exe`,
    `QuickSFV.exe`, `UE4PrereqSetup*.exe`, …) are ended;
  - an Inno Setup `setup.tmp` that is large-address-aware is paused and a copy without that flag runs in its place
    with the loader's own `/SL5=…` arguments and a log of its own: unarc.dll overflows a 32-bit sum when Wine lets that
    process reserve 2 GB, and loops forever (the "16.9%" freeze);
  - under 5 GB free the installer is paused ("Paused: the disk is nearly full…") and continues at 10 GB;
  - nothing written to the game's folder for 10 minutes with the installer idle, or for 30 minutes at all, ends it
    ("The installer stopped responding."); the dropped folder going away (an unplugged drive) ends it too.
  A failed installer's checksum lists (`.md5`, `.sfv`) are checked: damaged files get their own sentence; otherwise
  the error is the last suppressed message box in Inno Setup's log.
- **Afterwards:** the game's program is found (`GameFinder`: an exe the games list names, a new shortcut's target, a
  top-level exe named like the game or its initials, the only top-level exe, then the largest windowed exe that loads
  graphics; never uninstallers, installers, redistributables, crash reporters or settings tools), its graphics are
  picked, MetalFX is on when the game ships `nvngx_dlss.dll`, winetricks installs what its files import that Wine
  doesn't cover (`NeededComponents`: d3dx9, d3dx10, d3dx11, d3dcompiler_43, xact, physx) instead of the bundled
  redistributables, and the fix list's components are applied. The Mac doesn't idle-sleep meanwhile.
- **Records:** `<STEPOVER_HOME>/installs.json` is the queue the app and `stepover add` share (one install at a
  time; an install whose process is gone reads Interrupted, with Try Again). `<bottle>/stepover-install.json`
  (`InstallOutcome`) names the job that made the bottle (only it may delete the bottle) and keeps the stage reached,
  the installer kinds, exit status, fixes, components and the log's tail with the dropped folder as `<folder>` and
  the home folder as `~`, for reporting later.
- **The Trash offer:** after 10 minutes of play, the game's screen offers once to move the installer folder (or the
  original of a copied game) to the Trash, with its size; never for a folder on a network share or one another
  install still uses.

A fresh bottle spends about 40 seconds inside Wine on its first installer (seen with `stepover install` too), so
each added game takes a minute or two more than its installer alone.

Checks: `app/Tests/install/make-installers.sh <dir>` builds small Inno Setup, NSIS, add-on, installed-game and
disk-image test cases (Inno Setup's compiler runs under Stepover's Wine; NSIS from Homebrew's `makensis`);
`app/Tests/install/add-check.sh <dir>` runs `stepover add` on them, and `app/Tests/ui/add-check.sh <dir>` drives the
app. `STEPOVER_LARGE_ADDRESS_FIX=always` (checks only) applies the large-address fix to installers that don't need
it, so the recipe runs end to end with the small test installer.

## The Dock menu

Every start through `Launcher.run` (the app, `stepover run` and the Mac launchers) is recorded in
`<STEPOVER_HOME>/recent.json`, which orders the Dock menu's recent games. Running games are found
without the app having started them: Wine names each process after its Windows path (argv[0] is
`C:\...\game.exe`) and keeps its working directory inside the bottle, so `RunningPrograms` matches a
process to a bottle by that directory (Wine overwrites the environment, so `WINEPREFIX` can't be
read). In a bottle with one program, any running non-system process counts as that program, because
launchers often exit once the game starts. Bring to Front activates the game's process, which Wine
registers as a regular macOS app.

## Runtimes

Runtimes ship apart from the app. `runtime/index.json` on `main` lists every published runtime (name,
download, SHA-256, size, summary, release date, `current` / `available` / `pulled`, a note for users,
`minApp`, `compatFormat`). The app fetches it at launch (`STEPOVER_RUNTIME_INDEX`, a URL or a file path,
overrides where from), keeps the last good copy in `<STEPOVER_HOME>/runtime-index.json`, and falls back
to the entry built into `Stepover.app/Contents/Resources/runtime.json`. Entries whose name isn't a plain
folder name or whose download isn't HTTPS are ignored.

A runtime (about 290 MB, 1.2 GB unpacked) downloads into its own folder under
`~/Library/Application Support/Stepover/Runtimes/` after a free-space check, its checksum is verified,
and nothing installed is replaced. The app offers the list's current runtime when it isn't installed
and this app can use it (`minApp`), never while a game is running; `stepover runtime status`,
`install [<name>]` and `remove <name>` do the same from Terminal. File > Wine Runtimes lists them and
keeps the two newest that aren't pulled.

Each bottle picks its **Wine version** on its page: Newest (the default, follows new runtimes) or one
runtime. A bottle runs on its pinned runtime, else `STEPOVER_RUNTIME`, else the pulled runtime it last ran
on (recorded in `<bottle>/.stepover-last-runtime`; a bottle is never moved off a runtime by itself), else
the newest runtime that isn't pulled. Marking a runtime `pulled` with a `note` in the list tells everyone
on it, with a button to switch.

`stepover-compat.conf` starts with `version = 3`; a runtime's `VERSION` records the format its plug-in
reads (`compat_format`), so the Fixes section can say when a bottle's runtime can't apply a fix.

## Library

The window opens on the Library (`LibraryView`); **View > Bottles** shows the bottle pages instead and is
remembered. Its tiles (`Library.games` in StepoverKit) are every program in each bottle's `stepover.json`,
every installed Steam game (`SteamLibrary.apps`; Play runs `steam.exe -applaunch <id>`, so it records in
the recent list under the game's name), and one Steam tile per bottle with Steam; a program inside a Steam
game's folder is folded into that game's tile. Each tile is matched to the games list on the Mac (Steam app
id, else the exe name, else the program's or bottle's name) and ordered by the last time it was played.

The selected game (else the last played) fills the top: its cover, blurred and tinted by the cover's own
average color, the verdict and controller answers, Play, and the reasons with their sources. Each program in your bottles (or
installed Steam game) the list doesn't know is looked up once on Steam's store (`SteamLookup`: only its name,
or its app id for a Steam game; exact single matches only; at most 20 a launch, one request every 1.5 s;
offline or refused stops until the next launch) and remembered in `<STEPOVER_HOME>/learned-games.json`, misses
for 30 days. View > Look Up Unknown Games on Steam turns this off. Covers come
from Steam's CDN by app id and are cached in `<STEPOVER_HOME>/Art` (a game Steam has no cover for, a 404, is
remembered with `<id>.none` for 30 days; being offline, a server error or a captive portal's page isn't); games without one get a cover made from their icon and
name. Hidden games are listed in `<STEPOVER_HOME>/library.json` (View > Show Hidden Games). On a first
launch the runtime download starts by itself, Play (and New Bottle, on an empty Library) waits for it, and a
failed download offers Retry beside Your games. A tile's Settings opens its bottle page without changing
what the app opens on; View > Library or Bottles (or the Library button) does. `app/Tests/ui/library-check.sh <games.json>` checks the screen through the accessibility tree.

## Couch mode

Couch mode (`CouchView`) is the Library full screen for a TV, driven by a controller: View > Couch Mode (⌘⇧F),
or by itself when a controller connects within 8 s of launch (View > Open in Couch Mode with a Controller turns
that off). It fills the display Stepover's window is on. Left and right (d-pad or stick) move along the row of
games, A plays (Resume when it runs, "Quit X and Play" when another game runs), X opens Details (every reason
with its source), Y hides a game or, with Show Hidden Games on, puts it back, and Menu (Start) has Make This the
Main Display, Leave Couch Mode, Show Hidden Games, Stop Everything, Retry Download and Open at Login. The
keyboard stands in: arrows, Return = A, Escape = B, Space = X, Delete = Y, Tab = Menu. No Mac alert opens while
it's up; messages show on the screen with B to dismiss. The rules (focus movement, what A does, the shortcut,
what counts as the game running) are in `Couch.swift` in StepoverKit, with tests.

The screen shows the selected game's key art from Steam (`library_hero.jpg`), its logo (`logo.png`; a mostly
dark logo, `LogoTone`, gives way to the typed name), the verdict and controller answers, Steam's short
description (`GameAbout`, from appdetails, with a promotional lead-in dropped) and Play. They are fetched once
per Steam game and kept in `<STEPOVER_HOME>/Art` beside the covers: `<id>-hero.jpg`, `<id>-logo.png`,
`<id>-about.json`, and a `.none` marker for 30 days when Steam has none. Games without them keep the blurred
cover and the typed name.

After Play the button says "Starting <game>" and A waits until one of the game's processes appears (a Steam
game's from its folder; a program's exe, or anything run from its folder, since launchers hand off, as Red Dead
Redemption 2's does); it gives up after a minute. When the game's first real window opens (layer 0, at least
640 by 360), Stepover brings it to the front, so a game that opens on another desktop or behind couch mode's
full screen isn't out of sight. Games go full screen on the main display; when couch mode's display isn't the
main one, a line says so and Menu > Make This the Main Display moves the displays' origins
(`DisplayLayout.originsMakingMain`, `CGConfigureDisplayOrigin`).

While a Stepover game runs, Stepover listens to the controller in the background
(`GCController.shouldMonitorBackgroundEvents`). Holding Select + Start for a second shows a panel over the
game (`InGamePanel`: a non-activating `NSPanel`, so the game keeps focus) with Resume and Quit Game. The game is
paused while it's up (its processes get `SIGSTOP`), so the panel's buttons don't act in it; Resume continues it
once every button is let go (`PausedGame`), and the game is continued if it ends or Stepover quits. Quit Game
asks first, then ends just the game: a Steam game's own processes (Steam keeps running), else its bottle. Couch
mode comes back with that game selected, reopening the window if it was closed; it does the same when a game
ends by itself. Holding Start on 8BitDo controllers for about 3 s turns them off, which is why the hold is one
second. The Home button stays with macOS (on macOS 26 holding it opens Apple's Games app); if macOS passes Home on to
apps, holding it for half a second shows the panel too.

Stopping a bottle (Quit Game, Stop, Stop Everything, `stepover stop`) ends the bottle's programs itself, then
runs `wineserver -k`: `wineserver -k` alone gives up on the server after 10 s and left a hung or busy game
running, frozen, with no server. `app/Tests/ui/couch-check.sh <games.json>` checks the screen through the
accessibility tree and `app/Tests/ui/stop-check.sh` checks stopping; `STEPOVER_NO_CONTROLLER=1` makes a copy
ignore controllers, so a controller in someone's hands can't press anything in a scripted check's test copy.

## Games list

What Stepover knows about a game before anyone plays it here comes from one file, `games.json`, built
every day by the Games list workflow (`.github/workflows/games-list.yml`, the `games-list` command in
`app/Sources/games-list`) and published as the asset of the rolling release `games-list`. Each entry has
the game's names, whichever store ids are known (Steam, Epic) and the exe names Stepover's fix list uses,
plus:

- **Mac test results** from AppleGamingWiki's Compatibility/macOS ratings (native, Rosetta 2, CrossOver,
  Wine; the tester's Mac, method and date). Pages that don't record a Steam app id are matched to Steam by
  the store search, taking only an exact same-named result.
- **Anti-cheat** from AreWeAntiCheatYet. Its Linux status doesn't carry over: Proton's anti-cheat support
  uses pieces that don't exist under Wine on a Mac.
- **Steam facts** (Mac version, single-player, controller support) and the **Steam Deck** result, refreshed
  about weekly per game within a request budget (`STEPOVER_GAMES_STEAM_BUDGET`, default 1200 a run, one every
  `STEPOVER_GAMES_STEAM_DELAY` seconds, default 1.5).
- Whether the **fix list** has a fix for it.

A source that fails keeps the previous list's data, and a list that shrank by more than 10% isn't published.
ProtonDB isn't used: its data is ODbL, which can't be combined with AppleGamingWiki's CC BY-NC-SA 3.0. The
list keeps that license and credits both sources (its `credits` field).

The app downloads the list at most once a day (`STEPOVER_GAMES_LIST`, a URL or a file path, overrides where
from), keeps the last good copy in `<STEPOVER_HOME>/games-list.json`, and falls back to the snapshot built
into `Stepover.app/Contents/Resources/games.json` (release builds; `STEPOVER_GAMES_JSON` for
`app/build-app.sh`). Matching a program to a game happens on the Mac: Steam app id, else the exe name, else
the normalized name, and no match rather than a guess when two games fit. Nothing else about which games you
have is sent anywhere. The verdicts (will it play, does it work with a controller) are `Verdicts` in
StepoverKit; their rules and wording are in `docs/superpowers/specs/2026-10-28-library-design.md`.

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
`STEPOVER_DXVK_DIR`, `STEPOVER_WINETRICKS`, `STEPOVER_DOWNLOADS`, `STEPOVER_RUNTIME_INDEX`, `STEPOVER_RUNTIME_MANIFEST`, `STEPOVER_RUNTIME_URL`;
build and release: `STEPOVER_SRC`, `STEPOVER_BUILD`, `STEPOVER_DOWNLOADS`, `STEPOVER_GPTK_DMG`, `STEPOVER_APP`,
`STEPOVER_BIN`, `STEPOVER_BUNDLE_ID`, `STEPOVER_VERSION`, `STEPOVER_SOURCE_URL`, `STEPOVER_SPONSOR_URL`, `STEPOVER_RUNTIME_JSON`,
`STEPOVER_GITHUB_REPO`.

## Not included

GStreamer (Wine 11's FFmpeg path, `winedmo`, decodes media instead), most of CrossOver's per-game
hack database (Stepover's open fix list grows instead), and its anti-cheat integration.
