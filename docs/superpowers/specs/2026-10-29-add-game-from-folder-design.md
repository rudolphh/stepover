# Add a game from an installer or folder

**Date:** 2026-10-29
**Status:** written; the maintainer's answers are in; waiting for the maintainer's approval

## Why

The maintainer rarely plays through Steam. They keep installer folders of games they own and want adding one
to be frictionless. Their words: **"drag the folder in and come back to a Play button"**.

Today every one of those games took a Claude session of hand work:

- Escape from Duckov's installer froze at 16.9% forever (unarc's large-address bug, below);
- Sainthood and I Am Jesus Christ needed the same fix, plus ending three steps that hang under Wine;
- a DODI-style installer failed with "Unarc error -11" because of one environment variable;
- Hi-Fi Rush needed the right Windows DPI to render at full size;
- each game needed its `.exe` found and added by hand.

None of that is particular to one game. It is the same few problems every time, so Stepover can do it.
The standing rule applies: always think frictionless.

Steam-library work is shelved. Public reporting is project 2 and comes after this one (the maintainer's
order, 2026-10-29); it builds on the moments this project creates (see "Project 2 hooks").

## What it is

1. Drag a game's folder onto Stepover (its window or its Dock icon) and walk away.
2. Its tile appears at once in the Library with the game's art and the will-it-play answer, then says what
   is happening in plain words while Stepover installs it.
3. Stepover makes the game its own bottle, runs the installer silently with the known installer fixes
   applied, adds what the game needs, finds the game's program, applies its settings, and the tile turns
   into **Play**.
4. If something fails, the tile says so in one plain sentence, with Try Again.
5. A folder that is already an installed game (no installer in it) just gets its program found.

In the app it is always "add a game from an installer or folder". Never "repack": Stepover is a public
open-source app and must not read as a piracy tool. **Stepover never downloads, cracks or touches DRM; it
only runs the installer already in the folder.**

## Goals

- **D1. Ways in.**
  - Drag onto the Library window (either view, Library or Bottles) or onto Stepover's Dock icon.
  - File > Add Game from Installer or Folder… (an open panel that takes folders and files), for anyone who
    doesn't think to drag. (my call)
  - `stepover add <path>...` does the same from Terminal and prints each stage, for scripted checks. (my call)
  - What it takes: a folder; a single setup `.exe` or `.msi` (the rest of its folder comes along); a disk
    image (`.iso`), mounted read-only for the install and ejected afterwards. An archive (`.zip`, `.rar`,
    `.7z`) gets one sentence: "Unpack it first, then drag in the folder." (my call: unpacking is a project of
    its own and macOS already does `.zip`)
  - On an empty Library the empty screen says "Drag a game's installer or folder here". (my call; it fits
    the empty-screen redesign already queued)

- **D1b. What counts as one game.** (my calls, after the builder check)
  - A folder with several installers for one game (GOG's offline folders: the base `setup_<game>.exe`, DLC
    and update installers, each with its `.bin` files) is one game: the base installer first, then DLC, then
    updates in version order, all into the same bottle, on one tile. A failed add-on doesn't fail the game:
    the tile is ready and says "Ready; the <add-on> add-on didn't install", with Details.
  - A folder holding several game folders becomes several queued games (D10), one per subfolder that holds
    an installer or a game.
  - A folder that is already an installed game is **copied into its bottle** at `C:\Games\<Game>`: an instant
    APFS clone on the same disk, else a copy with progress ("Copying, 12 GB of 40 GB") under D11's pause. Every
    game is then self-contained, keeps working with the drive unplugged, and writes its saves and settings in
    its bottle, not in the player's folder. The original is handled like an installer folder (D13).

- **D2. Recognize the game before anything else happens.**
  - The name comes from the folder (or file) name, cleaned by generic rules only: text in brackets or
    parentheses goes, dots and underscores become spaces, version and build numbers go (`v1.0.20`,
    `Build 1436.28`), a trailing `-WORD` tag goes, and so do words like Setup, Installer, Repack, x64.
    No installer group's name is ever written in Stepover's code or copy; the rules are generic.
  - If the folder name doesn't match, try the installer's own product name (Inno Setup's app name, or the
    setup file's version information). (my call)
  - The cleaned name is matched like any program today: the games list first (`GameIndex`, exact normalized
    name), then one Steam store lookup with the existing `SteamLookup` rules (name only, exact single match).
  - After the install, the game's `.exe` name is a second chance to match (the games list has exe names).
  - No match: the tile uses the cleaned name, "Not tested yet", and a cover made from the icon, as today.

- **D3. The answer shows, and the install starts.**
  - The tile appears within a second with its art and both answers (will it play, controller), and the
    install starts straight away, whatever the verdict: the verdict is advice, never a gate.
  - The one exception is the only firm no: "Won't run: needs anti-cheat that doesn't work on Mac" (anti-cheat
    and no single-player). That tile waits with **Install Anyway**, matching the Library's Try Anyway. (my
    call: it is the one case where installing 80 GB is almost certainly wasted, and Install Anyway keeps it
    from being a gate)
  - A game that already has a tile: "Already in your Library", with Play and Install Again (a second copy in
    its own bottle). (my call)

- **D4. Its own bottle, set up for this Mac.**
  - One new bottle per game, named after the game ("Name 2" if taken), 64-bit Windows 10, MSync on, made the
    way `Importer.create` makes one today. The game installs to `C:\Games\<Game>` (as the existing bottles
    do).
  - **Screen:** High Resolution Mode on, with Windows DPI at 96, for every new bottle. (my call, after the
    builder check) The builder compared the bottles on this Mac: Hi-Fi Rush and I Am Jesus Christ declare no
    DPI awareness and need 96 (192 halves them to 1728 by 1117); Sainthood declares itself DPI-aware and runs
    at full size at 96; only Red Dead runs at 192. So a DPI-aware game gets the full screen at 96 too, and 96
    is the one value that fits all four. Red Dead's 192 came with CrossOver's High Resolution Mode setting and
    has not been tried at 96 (my reading of the notes). The builder tries Red Dead at 96 on an APFS clone of
    its bottle; if it needs 192, that becomes a per-game setting (`GraphicsPicker.known`), not a rule.
  - **Documents, Desktop, Downloads, Music, Pictures and Videos live inside the bottle** (the maintainer's
    call): after the bottle is made, Wine's links from `C:\users\crossover\...` to the Mac's own folders are
    replaced with real folders. No macOS access dialog can stall an install, a game's saves stay with the game
    (where save sync can reach them), and nothing lands on the Mac's Desktop. They no longer show in the Mac's
    Documents. Because saves now live in the bottle, removing such a game says its saves go with it. (my call)
    Existing bottles are not changed.
  - Wine's own menu builder is off in these bottles (Stepover reads shortcuts itself). (my call)

- **D5. Run the installer silently, with the known fixes applied up front.** The type is detected from the
  file itself, not from the folder's name.
  - **Inno Setup** (most installer folders, GOG's offline installers too): `/VERYSILENT /SUPPRESSMSGBOXES
    /NORESTART /SP- /DIR="C:\Games\<Game>"`; components and languages are the installer's defaults. (my call:
    a choices screen would break "walk away", and the defaults are what a person clicking Next gets)
  - **Inno Setup that unpacks with unarc** (an `unarc.dll` or `ISDone.dll` alongside, or big `.bin` archives):
    the large-address-aware fix in Appendix A is applied every time, not after a hang.
  - **NSIS:** `/S /D=C:\Games\<Game>`. **MSI:** `msiexec /i <file> /qn` with the install folder set.
  - **Anything else** (InstallShield, custom setups): it runs with its window showing and the tile says "The
    installer needs you: it's open on the Mac". Everything after it ends is automatic again. (my call)
  - **Steps that hang or aren't wanted under Wine are ended, by what they are, not by who made the
    installer:** redistributable installers (DirectX web setup, Visual C++ redistributable), checksum tools
    launched at the end, and anything that would open a web page: no installer ever opens a page in the Mac's
    browser (for example, `winebrowser.exe` is disabled while installing). What the installer otherwise does
    inside the bottle is its business.
  - The launcher always removes `NoDefaultCurrentDirectoryInExePath` from Wine's environment (it caused
    "Unarc error -11").
  - **Stepover never writes, moves or deletes anything in the dragged folder**, except moving it to the Trash
    when the player says yes (D13). Installers run from it as they are, with no sandbox: they don't normally write to their own
    folder, and copying the folder first would double the space and time for no gain. (my call, after the
    builder check)
  - **No macOS permission dialog mid-install.** The builder checks whether reading a folder in Downloads, or
    on an external drive, from Wine makes macOS ask Stepover for access. If it does, Stepover asks at the
    moment of the drop, while the person is at the Mac, never during the install. (my call)
  - The Mac doesn't idle-sleep while an install runs (closing the lid still sleeps it). (my call)
  - **Finished** = the installer and everything it started have ended (`wineserver -w`, as `stepover
    install` does today). **Stuck** = nothing new written to the game's folder and the installer's
    processes idle for a long stretch, or busy with no progress for longer still; then it is ended and the
    tile says "The installer stopped responding". (the builder picks the times)

- **D6. What the game needs, without running the bundled extras.**
  - The bundled DirectX and Visual C++ installers are never run: they hang under Wine, and Wine's own
    versions covered every game installed by hand so far.
  - Instead Stepover installs, through winetricks (already a dependency of the Homebrew cask), the components
    the fix list names for the game, plus the ones the game's own files ask for that Wine doesn't cover
    (L.A. Noire needed `d3dx11_43` and `d3dcompiler_43`). The builder owns the table from imported DLL to
    component; the principle is "only what the game's files call for".
  - This happens during the install, not at first Play, so Play is instant and works offline.

- **D7. Find the game, not the uninstaller.**
  - Candidates: the new Start Menu and desktop shortcuts (`Importer.programs`), plus every windowed `.exe` in
    the game's folder.
  - Never: uninstallers, installers, redistributables, crash reporters, and settings or config tools.
  - Ranking (my call): an exe the games list names for the matched game; a shortcut's target; a top-level exe
    whose name resembles the game's; the largest windowed exe that loads graphics DLLs. For Unreal Engine
    games the top-level `<Game>.exe` (what shortcuts point at), not the `-Win64-Shipping` one, whose
    per-process rules still apply when it starts.
  - One program is added as the tile's Play. When two candidates are close, Details names the one chosen
    and Settings can change it.
  - Acceptance: from the real file listings of the games installed on this Mac (Red Dead Redemption 2,
    Hi-Fi Rush, Sainthood, I Am Jesus Christ, plus L.A. Noire's and Escape from Duckov's from their known
    layouts, with any installer group's name taken out) the ranking picks the program the maintainer
    actually plays.

- **D8. Settings and art.** The graphics pick (`GraphicsPicker`), the fix list, and the art all work as they do
  for any program today. One addition: when the game folder holds `nvngx_dlss.dll`, MetalFX is turned on for
  the game (`D3DM_ENABLE_METALFX=1`), as Red Dead and I Am Jesus Christ were set by hand. (my call)

- **D9. The tile says what is happening, in plain words.**
  - Waiting to install (queued) / Getting ready / Copying (an installed game, D1b) / Installing (12 GB so far, or a percentage when the
    installer's own size is readable) / Adding what the game needs / Finding the game / then Play.
  - Failure is one sentence plus Try Again, and Details for the log. The sentences (my wording, the builder
    may tighten):
    - "The installer stopped with an error: <its message>."
    - "Some of the installer's files are damaged. Download them again, then Try Again." Shown when the folder
      has a checksum file (`.md5`, `.sfv`) and, checked after a failure only, files don't match. (my call: no
      time spent on the happy path, and damaged downloads are the commonest real failure)
    - "The installer stopped responding."
    - "Installed, but Stepover couldn't tell which program is the game." with Choose the Game…
    - "This folder doesn't have an installer or a game in it."
    - "The folder isn't there anymore." (an unplugged drive)
  - Try Again starts over in a fresh bottle; removing a failed tile deletes its bottle (nothing of the
    player's is in it). (my call)
  - No Wine words on the Library: no "bottle", "prefix", "unarc" or "Inno Setup" outside Details.

- **D10. Several at once.** Several folders dragged together (or one after another) queue up and install one at
  a time, in the order dropped; each waiting tile says "Waiting to install". (my call: unarc uses every core
  and the disk, so two at once each take longer and need twice the free space at the peak)
  - The queue is kept in `<STEPOVER_HOME>/installs.json`. Quitting Stepover while an install runs asks first;
    quitting ends the install, and the tile says "Interrupted" with Try Again next time. (my call)

- **D11. Disk space.** The install always starts; Stepover doesn't guess sizes and refuse. If free space falls
  under a floor (about 5 GB) during the install, the installer is paused and the tile says "Paused: the disk is
  nearly full. Free up some space and it carries on." It continues by itself once there is room. (my call: a
  pause is recoverable; a failed 40 GB unpack isn't)

- **D12. Couch mode.** Couch mode shows the same tiles, states and progress; a finished game is ready to Play from
  the couch; a failure reads from across the room with A for Try Again and B to dismiss.
  - **Starting an install from the couch** (the maintainer's call): Menu > Add a Game lists the folders and
    disk images in `~/Downloads` (top level) that hold an installer or a game, newest first, each with its
    recognized name, art and verdict. A queues one exactly as a drop would. Games already in the Library are
    marked, and folders still downloading (partial-download files, or files changed in the last minute) are
    left out. (the details are my calls)
  - macOS guards Downloads, and its access dialog needs a mouse. Stepover asks for Downloads access at the Mac
    (with the Documents and signing follow-up already queued). Until it has it, the couch menu item says "Allow
    Stepover to see your Downloads on the Mac first". (my call)

- **D13. The folder afterwards** (the maintainer's call: offer once). After the game's first good run, its tile
  offers once: "Move the installer to the Trash (frees 32 GB)", with Move to Trash and Keep (A and B in couch
  mode). It is a line on the game's screen, not a Mac alert, and nothing happens unless the player says yes.
  The same goes for the original of a game folder Stepover copied in ("Move the original folder to the Trash").
  (the details are my calls)
  - **A good run** is the game running for 10 minutes, the same threshold the Library design uses for "your
    result".
  - It is offered only when the folder is still there and can go to the Trash. A network share can't: there,
    the system would delete the folder for good, so no offer is made.
  - The offer is never made while another queued install still uses the folder.
  - Keep is remembered, so the offer is not made again.

## Non-goals

- Downloading games, store sign-ins, cracks, DRM. Stepover only runs the installer that is in the folder.
- Setting the game's own resolution and quality (the maintainer: not yet).
- Archives (`.zip`, `.rar`, `.7z`) in this version.
- Installing to an external drive. Bottles stay where they are today.
- Mods.
- Updates and patches for a game already installed. A patch's installer dragged in becomes a new game in v1;
  dropping it onto the game's tile to install into that game is a natural later step.
- Reporting (project 2), beyond the hooks below.

## Anti-goals (failure even if it works)

- **Saying a game won't work when it does.** The verdict is advice; weak evidence reads weak; the only firm no
  is online play that needs anti-cheat, and even that has Install Anyway.
- **Reading as a piracy tool.** "Installer or folder" in the app. How far the no-names rule reaches (my call,
  after the builder check; it matches the reporting rule agreed earlier):
  - Stepover's own code, copy and messages never name an installer group.
  - The player's own file and folder names, in the log and Details on their own Mac, are theirs and shown as
    they are.
  - Anything that leaves the Mac (project 2's reports) or goes into the public repository (test fixtures,
    including D7's acceptance listings) is redacted or renamed to neutral names. The outcome record stores the
    installer type, not paths.
  - Leftover files an installer puts in the game's folder stay; they are the installer's business.
- **A question while the person walked away.** Nothing waits on a click mid-install except the two cases
  above that are named on the tile (Install Anyway before starting, and an installer type that can't run
  silently). A macOS permission dialog popping up mid-install counts as failure (D4 and D5 prevent it).
- **Touching the player's folder without asking.**
- **A Play button on a half-installed game.**

## Project 2 hooks

Reporting will trigger on an installer failure, the game quitting within its first minute, and a "Didn't work"
button. So this project records each install's outcome in a small structured form beside the bottle: the
stage it reached, the installer type ("Inno Setup installer (unarc)", never its source), exit status, which
fixes were applied, and the log's tail. Project 2 then reads it instead of re-deriving it. (my call)

## Constraints

- macOS 15 or later on Apple silicon, Rosetta, the current runtime (cx26.3), D3DMetal from GPTK 4.
- Wine from a shell that Claude Code started needs `env -u NoDefaultCurrentDirectoryInExePath` (D5 makes the
  launcher do it always).
- Never send WM_CLOSE to a game the player might be using. Stuck Wine processes need SIGKILL.
- Unit tests for name cleaning, installer detection, silent arguments, exe ranking and the import-to-component
  table, from real file listings. An end-to-end check with tiny Inno Setup and NSIS installers built for the
  test. A hands-on check with one of the maintainer's real installer folders at the end.
- Same process as before: plan, native execution with a ledger, a fresh reviewer, merge only on the
  maintainer's OK.

## Left to the builder

- The exact name-cleaning rules and how the installer type is detected.
- The exe-ranking heuristics, within D7's rules and acceptance set.
- The DLL-to-component table (D6).
- Stuck-installer times and the progress measure (D5, D9).
- Where the queue and outcome records live, and the tile's layout for each state (within the Library and couch
  designs already approved).
- A cleaner way to apply Appendix A, if one gives the same result.

## Decided by the maintainer (2026-10-29)

1. **In-game settings: not yet.** Stepover stops at the Wine side (D4, D8). The game's own resolution and
   quality (full screen at the screen's resolution, a preset reaching 1440p at 75 fps) stay with the player
   in this version; setting them is a later project.
2. **Personal folders inside the bottle.** See D4.
3. **The folder afterwards: offer once to move it to the Trash.** See D13.
4. **Couch mode can start an install, from Downloads.** See D12.

## Appendix A: installer fixes proven on this Mac

**unarc's large-address bug (the 16.9% freeze).** unarc.dll finds the largest free memory block by halving with
32-bit `lo + hi`, which overflows once a 2 GB `VirtualAlloc(MEM_RESERVE)` succeeds. Under Wine it does for a
large-address-aware process, and the installer then loops on `VirtualAlloc(size 0)` forever. Recipe that worked
for Escape from Duckov, Sainthood and I Am Jesus Christ:

1. Run `setup.exe` with the silent arguments. Its loader unpacks `setup.tmp` into `%TEMP%\is-*.tmp\` and
   starts it with `/SL5="$<hwnd>,<offset>,<offset>,<path to setup.exe>"` plus the arguments.
2. Copy that `setup.tmp`, clear the large-address-aware flag (PE characteristics `0x20`) in the copy, pause the
   original (`SIGSTOP`), and run the copy with the loader's own `/SL5=...` argument and the silent arguments.
   Escape from Duckov then unpacked 2.2 GB in about 45 s.
3. After it finishes, end the paused original and the copy so the install counts as finished.

**Steps after unpacking that hang under Wine.** A checksum tool (QuickSFV) and the DirectX web setup and
Visual C++ redistributable installers wait forever: end them (D5) and supply components instead (D6). A script
that edits the hosts file only edits the bottle's own and is left alone. The end-of-install web link is blocked
(D5).

**"Unarc error -11: unable to write data to disk".** Caused by `NoDefaultCurrentDirectoryInExePath=1` in the
environment (unarc can't find a bare `xtool.exe`). Remove the variable (D5).
