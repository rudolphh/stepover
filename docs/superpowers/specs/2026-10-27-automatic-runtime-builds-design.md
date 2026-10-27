# Automatic runtime builds and safe runtime updates

**Date:** 2026-10-27
**Status:** design, awaiting the maintainer's approval

## Intent

When CodeWeavers publishes a new CrossOver source drop, Stepover users should get a runtime built
from it without the maintainer building, testing or publishing anything by hand. The maintainer
explicitly does not want to play-test every new runtime. Users are the testers, so the product has
to make that safe for them:

- going back to the previous runtime is one click, per game, with no download, and actually works;
- a broken game is noticed without false alarms;
- reporting a problem is quick and carries every detail needed to fix it;
- a bad runtime can be pulled from everyone, including people who already have it.

The maintainer's words: "let the user do it themselves and report somehow if it broke with all
relevant details and make it super easy to rollback and use prev version, frictionless", and on the
edge cases below: "include all of them".

## Goals

1. A daily job notices a new `crossover-sources-<version>.tar.gz` and, with no human step, builds a
   runtime from it, checks it automatically and publishes it if the checks pass.
2. Runtimes are published independently of the app. A new CrossOver source drop never needs a new
   app release, so the automated pipeline can never break the app. (Changes to Stepover's own code in
   the runtime ship with app releases; see section 10.)
3. The app keeps old runtimes next to new ones and lets each bottle choose its Wine version.
4. The first launch of a bottle on a new runtime is reversible, including the changes Wine makes to
   the bottle.
5. A crash after a runtime change leads to a single prompt offering to go back and to report it.
6. Reports are prefilled, private paths removed, and work with or without a GitHub account.
7. The maintainer can mark a runtime as bad, and every app that has it tells its user.

## Non-goals

- Automatically bumping DXMT, DXVK, MoltenVK, FFmpeg, SDL, nettle or gmp. Those stay manual.
- Automatically updating D3DMetal. Apple's Game Porting Toolkit download needs the maintainer's Apple
  sign-in, so a new D3DMetal is still assembled on the maintainer's Mac (see "D3DMetal" below).
- Telemetry or automatic crash uploads. Nothing leaves the user's Mac unless they choose to send it.
- Supporting games with kernel anti-cheat.

## Anti-goals (it fails even if it works if...)

- A user loses game saves or their own files when going back.
- A user is nagged: prompts while playing, repeated prompts, false crash alarms on launchers.
- The pipeline publishes something whose source changed silently under the same version number.
- A runtime update stops a bottle from starting at all, with no way back short of reinstalling.

## Current state (facts this design builds on)

- **Building:** `runtime/build-deps.sh`, `build-wine.sh`, `build-dxvk.sh`, `install-runtime.sh`
  (`docs/how-it-works.md`, "Rebuild"). Wine is cross-compiled for x86_64 on an arm64 host and runs
  under Rosetta. Versions and checksums are pinned in `runtime/config.sh` (`CX_VERSION`,
  `CX_SHA256`, `CX_URL`, Mono and Gecko versions and checksums, `DXMT_VERSION`). D3DMetal comes
  from the Game Porting Toolkit disk image (`STEPOVER_GPTK_DMG`). Building needs Xcode, Rosetta and
  the Homebrew packages listed in `docs/how-it-works.md`.
- **Runtime naming:** `RUNTIME_NAME="cx${CX_VERSION%.0}"` (26.3.0 is `cx26.3`). The unpacked runtime
  is about 1.2 GB; the archive about 290 MB.
- **Packing is deterministic:** re-packing the same runtime folder with `release/make-release.sh`
  gave a byte-identical archive (0.2.0 and 0.2.1 share SHA-256 `18e87ca7…fac3`).
- **Distribution today:** the runtime manifest (name, URL, SHA-256, size, summary) is embedded in
  the app at build time (`Stepover.app/Contents/Resources/runtime.json`, read by
  `RuntimeManifest.bundled()`; `STEPOVER_RUNTIME_MANIFEST` and `STEPOVER_RUNTIME_URL` override it).
  So a new runtime currently requires a new app release.
- **Updating today:** `RuntimeInstaller.install` checks the SHA-256, unpacks into
  `~/Library/Application Support/Stepover/Runtimes/`, and when the name is unchanged moves the old
  one to `<name>.old`. It refuses to update while a bottle is running (checked before the download
  and before the swap). The app shows "Update available" when the bundled manifest differs from the
  installed runtime's record (`RuntimeManifest.isCurrent`).
- **Choosing a runtime:** `BottleConfig.runtime` can pin a runtime by name; otherwise
  `Runtime.resolve(nil)` uses `STEPOVER_RUNTIME` or the newest installed one (numeric name sort).
  The app has no UI for the pin.
- **Bottle setup:** Wine redoes a bottle's setup when `wine.inf` changes; `SetupStamp` skips the
  redo when only the date differs. A newer Wine rewrites the registry and Windows system files.
- **Mac launchers** in `~/Applications/Stepover` call `stepover run <bottle> <program>`, so they
  follow the bottle's runtime choice.
- **Reports today:** `FixLibrary.reportURL` builds a prefilled GitHub issue: game, how it ran,
  Stepover version, runtime summary, graphics, MSync, macOS version, applied fixes.
- **CI today:** `.github/workflows/fixes.yml` only. The repository is public, so GitHub-hosted macOS
  runners are free.

## Design

### 1. Noticing a new source drop

A scheduled workflow (daily) reads `https://www.codeweavers.com/crossover/source` and looks for
`crossover-sources-<version>.tar.gz` names newer than `CX_VERSION`. For a new version it downloads
the archive, records its SHA-256, and starts the build (section 2) with that version and checksum.

- If the archive for an already-pinned version changes (its SHA-256 no longer matches `CX_SHA256`),
  nothing is built or published; the workflow fails loudly so the maintainer gets a GitHub
  notification. A changed archive under the same name is never treated as a new release.
- The new version's Mono and Gecko versions are read from the new tree
  (`dlls/appwiz.cpl/addons.c`). If they differ from `config.sh`, the workflow fetches them from
  WineHQ's download server over HTTPS and records their checksums (my call: trust on first download,
  as `config.sh` was filled originally). The source archive is pinned by the checksum recorded at
  discovery.
- When the build is published, the workflow commits the new `CX_VERSION`, `CX_SHA256` and any Mono
  or Gecko changes to `runtime/config.sh` on `main`, so the repository always says what the newest
  runtime was built from.

### 2. Building on a GitHub macOS runner

The same scripts the maintainer runs locally, on a GitHub-hosted Apple Silicon macOS runner, with
the Homebrew packages installed and Rosetta present. The scripts already take their paths from
environment variables (`STEPOVER_SRC`, `STEPOVER_BUILD`, `STEPOVER_DOWNLOADS`, `STEPOVER_RUNTIMES`).

- **D3DMetal:** the runner cannot download the Game Porting Toolkit. `install-runtime.sh` gains a
  second source for D3DMetal: the `lib/d3dmetal` folder (and its license files) of the newest
  published runtime, downloaded from Stepover's own release and checked against its recorded
  SHA-256. The disk image path stays for the maintainer's manual D3DMetal updates.
- **DXMT, Mono, Gecko:** downloaded as today, checked against `config.sh`.
- **Runtime identity:** a runtime's name is the CrossOver version plus a Stepover build number, so a
  rebuild of the same CrossOver version (a plug-in change, a new D3DMetal) gets a new name instead of
  replacing the old one in place: `cx26.4`, then `cx26.4-2`, and so on. Names must keep sorting
  correctly with the existing numeric sort; the builder checks that `cx26.4-2` sorts after `cx26.4`
  and before `cx26.5`, and adjusts the separator if not.
- **Things to verify first, before building anything else** (a spike): the runner has Rosetta; the
  full build fits in the runner's disk and memory and under GitHub's 6-hour job limit; and whether
  the runner can create a Metal device at all (it decides check 3e below).

### 3. Automated checks (all must pass to publish)

a. The archive unpacks and every file the app relies on exists: `bin/wine`, `bin/wineserver`,
   `lib/wine/x86_64-unix/cxcompatdb.so`, `lib/d3dmetal`, `lib/dxmt`, DXVK, Mono and Gecko.
b. Under Rosetta, `wine --version` runs and `wineboot -i` creates a fresh bottle without errors.
c. A small console test program (built in CI with mingw) runs in that bottle and exits 0.
d. The compat plug-in loads: with `STEPOVER_COMPAT_DEBUG` set, the bottle log shows the plug-in
   choosing a graphics layer for the test program.
e. If the runner has Metal: a tiny Direct3D 11 program and a tiny Direct3D 12 program each create a
   device and present one frame through D3DMetal. This is the check that catches a new Wine that
   needs a newer D3DMetal than the one carried over. If the runner has no Metal, this check is
   skipped and the release notes say so.
f. An existing bottle created by the previous runtime (made in CI with the previous runtime) starts
   on the new one, so the setup redo itself works.

A failed check stops the pipeline; nothing is published, and the maintainer gets the workflow
failure notification. Users keep the runtime they have.

### 4. Publishing a runtime without an app release

- The runtime archive is published as a GitHub release named for the runtime (for example
  `runtime-cx26.4`), with the CrossOver source archive, the other source archives and `SHA256SUMS`
  attached, as app releases do today (the LGPL obligations).
- **The runtime index** is a file on `main`, `runtime/index.json`, read by the app over HTTPS from
  the official repository (the one in the app's `StepoverSourceURL`). It lists every published
  runtime: name, URL, SHA-256, size, summary, release date, and a status of `current`, `available`
  or `pulled` with an optional note for users. The pipeline appends the new runtime as `current`.
  My call: no separate signature in this version. The index has the same trust as the cask and the
  releases, which already come from this repository.
- The app reads the index at launch (and when the user asks for updates), caches the last copy, and
  falls back to the bundled `runtime.json` when it has never reached GitHub. App releases stop
  needing a new runtime; `make-release.sh` stops packing the runtime and embeds the index's current
  entry as the offline fallback.
- **Pulling a runtime:** the maintainer sets its status to `pulled` with a note (one commit, by hand
  or with a small `release/pull-runtime.sh`). New users never get it; existing users see the note and
  a button to move every bottle that uses it back to the newest good runtime.

### 5. In the app: runtimes side by side

- "Update available" downloads the new runtime into its own folder; nothing is replaced or deleted.
- Before downloading, check free disk space for the archive plus the unpacked runtime plus a margin
  (about 2 GB); if short, say how much is needed instead of failing halfway.
- A failed or interrupted download (offline, checksum mismatch) leaves the current runtime untouched
  and says what happened. The existing "refuse while a bottle is running" rule stays, and the update
  banner is not shown while a game is running.
- Stepover keeps the two newest good runtimes. Older ones are listed with a Remove button.
- Each bottle gets a **Wine version** setting: "Newest" (the default, follows updates) or a specific
  runtime. Switching is instant. This is the UI for the existing `BottleConfig.runtime` pin.
- A bottle pinned to an older runtime shows "On 26.3, newest is 26.5" with a one-click way back to
  Newest, so nobody stays behind by accident.
- Removing a runtime that a bottle is pinned to asks first and names the bottles. If a pinned
  runtime is missing anyway (deleted by hand), the bottle runs on the newest and says so once.
- **The runtime belongs to the bottle, not the game.** One Wine runs per bottle, so going back moves
  every game in that bottle. Every prompt and the picker name the bottle and, when it holds more than
  one program, list the others ("Steam bottle: Stumble Guys and 2 other games").
- **"Newest" skips pulled runtimes for new downloads, but never moves a bottle by itself.** A bottle
  that has already run on a runtime that later gets pulled stays on it until the user chooses; the
  pulled runtime stays installed, and the user sees its note with the go-back button (section 4).
  (My call: a silent move could land a bottle on an older Wine with no snapshot to restore.)
- **Going back when there is no snapshot** (it expired, the bottle was created or imported on the
  newer runtime, or the user jumps back more than one runtime): allowed, with a warning that Wine will
  redo the bottle's setup and that switching forward again is the fix if it won't start. The newer
  runtime stays installed for exactly that reason. Before such a switch Stepover makes an instant
  APFS clone of the whole bottle (no extra space until files change) and keeps it until the bottle
  has started successfully once on the older runtime, then deletes it. (My call.)

### 6. Making "go back" actually work: the first-launch snapshot

The first time a bottle starts on a runtime it hasn't run on before, Stepover first takes an
instant APFS clone (`cp -c`, no extra space until files change) of the parts Wine's setup rewrites:
the registry files (`system.reg`, `user.reg`, `userdef.reg`), `drive_c/windows`, `winetricks.log`,
and Stepover's own setup records for that bottle (`stepover.json` fields such as `setupInf`,
`appliedRegistry`, `failedComponents`). It does not include `drive_c/users` (saves, documents), game
folders or anything else.

**Software installed after the switch** (a new game's installer, components): going back is still
allowed, but the confirmation lists what was installed since the switch, from the bottle's programs
list and `winetricks.log`. Because `winetricks.log` is restored with the snapshot, components that
fixes ask for reinstall automatically on the next launch. Programs the user installed are listed as
"may need reinstalling". (My call: blocking going back exactly when a newly installed game broke
would defeat the point.)

Going back to the previous runtime for that bottle restores that snapshot, then starts on the old
runtime. Saves and the user's files are untouched. Trade-off, stated in the prompt: registry changes
the game itself made while on the new runtime are undone too (some games keep settings, rarely
saves, in the registry). One snapshot per bottle per runtime change; it is deleted once the bottle
has run on the new runtime for a while without the user going back (builder's call on how long).

### 7. Noticing a broken game

The signal is the bottle, not the program the user clicked: launchers such as Steam, the Rockstar
Games Launcher and game-specific launchers exit right after starting the real game, so "the program
quit quickly" alone is a false alarm.

Stepover asks only when all of these hold:

- the bottle is on a runtime change (first runs on a new runtime), and
- the bottle's Wine processes ended (the wineserver for that bottle exited), and
- either the bottle log shows a crash (Wine's unhandled exception or page fault messages, or a
  crash dialog), or no window from the bottle ever appeared on screen.

Then one prompt: **Go back to 26.3 for this bottle** and **Report it**, either or both, plus "Don't
ask again for this game". Never more than once per game per runtime, never while another game in
that bottle is running.

**Who watches.** Games often start from their Mac launchers in `~/Applications/Stepover`, which
`exec stepover run` and exit while Stepover.app may not be open. So `stepover run` stays alive as a
lightweight watcher for the session, but only while its bottle is on a runtime change (otherwise it
exits as today). It watches the bottle's wineserver, the log and whether a window from the bottle
appeared. After a crash it opens Stepover.app straight to the prompt for that bottle, even if the
app was not open. (The maintainer's decision: "Open Stepover's prompt", chosen over a notification
banner or prompting only for games started inside the app.) Games started from inside the app use
the same watcher.

### 8. Reporting

Extends today's per-program Report button, and is also offered by the prompt above.

- **Contents:** game and executable; Stepover version; the runtime it broke on and the one it worked
  on; Mac model (for example "MacBook Pro, M4 Max, 36 GB"); macOS version; graphics layer, MSync,
  High Resolution Mode and Windows scaling; applied fixes; whether going back fixed it; and the last
  part of the bottle log.
- **Privacy:** the user's home folder becomes `~`, and their macOS user name and Windows user name
  are replaced in paths. The user sees the full report before anything is sent.
- **Length:** GitHub's prefilled issue links break past a few thousand characters, so the link
  carries the summary and the log goes on the clipboard, with a "paste the log here" line in the
  issue body.
- **No GitHub account:** a **Copy Report** button puts the whole report on the clipboard, to post
  anywhere.
- **Duplicates:** titles have one format, `[cx26.4] <game>: <what happened>`. Before opening a new
  issue, Stepover searches the repository's open issues for that runtime and game (GitHub's public
  search API, no sign-in) and shows matches ("2 people reported this; going back fixed it for
  them") with a link to add to the existing one.

### 9. What the maintainer sees

GitHub notifications for: each published runtime, each failed pipeline run (including a changed
source archive), and each report. Pulling a runtime is one index change.

### 10. Stepover's own code inside each runtime

Each runtime contains Stepover code: the compat plug-in (`compat/stepovercompat.c`, built by
`install-runtime.sh`), which reads `stepover-compat.conf` written by the app and silently ignores
settings it doesn't know (the format grew in 0.1.2 and 0.2.0). Runtimes now ship apart from the app
and old ones stay installed, so (my calls):

- **The pipeline builds Stepover's parts from the latest app release tag, never from `main`.**
  Unreleased plug-in or script changes cannot reach users through an automatic runtime build.
- **Changes under `compat/` or `runtime/`, and manual DXMT, DXVK or MoltenVK bumps, ship with an app
  release:** publishing an app release whose tag changed those folders since the current runtime
  was built runs the same pipeline to build and publish a new runtime build number (section 2).
- **The plug-in has a format version.** The app writes `version = <n>` at the top of
  `stepover-compat.conf`; the plug-in records the highest version it understands in the runtime's
  `VERSION` file, and the index carries it with a `minApp` (the oldest app that can use the
  runtime). The app hides runtimes that need a newer app, and when a bottle is pinned to a runtime
  whose plug-in is older than a fix needs (for example `dll =` before 0.2.0), the bottle's Fixes
  section says which settings that runtime can't apply.

### D3DMetal

A new D3DMetal (a new Game Porting Toolkit) is the one input that stays manual: the maintainer runs
`install-runtime.sh` with the disk image on their Mac and publishes through the same release and
index steps, as a new runtime build number. From then on the pipeline carries that D3DMetal forward.

## Edge cases, and where each is handled

| Edge case | Handled in |
|---|---|
| A newer Wine rewrites the bottle; the old Wine may not run cleanly on it | 6 (snapshot and restore) |
| Removing a runtime a bottle is pinned to | 5 |
| Users who went back and forgot | 5 (pinned indicator) |
| Launchers that exit on purpose look like crashes | 7 (whole-bottle signal) |
| Report logs too long for a link | 8 (clipboard) |
| Users without a GitHub account | 8 (Copy Report) |
| Many duplicate reports | 8 (title format, search) |
| A bad runtime must reach people who already have it | 4 (index status `pulled`) |
| A new Wine that needs a newer D3DMetal | 3e (Metal check), D3DMetal section |
| CodeWeavers changes an archive under the same version | 1 (checksum mismatch stops everything) |
| Not enough disk space | 5 |
| Offline or interrupted download | 5 |
| Update offered while a game is running | 5 |
| Rebuild of the same CrossOver version | 2 (runtime build numbers) |
| Going back with no snapshot, or more than one runtime back | 5 (warning, whole-bottle clone) |
| A pulled runtime, and bottles created on it | 4, 5 (never moved silently) |
| Shared bottles (several games, one Wine) | 5 (prompts name the bottle and its games) |
| Software installed after switching runtimes | 6 (listed; components reinstall) |
| An old pinned runtime with a new app, or the reverse | 10 (format version, `minApp`) |
| Unreleased plug-in code reaching users | 10 (built from the release tag) |
| A crash in a game started from its Mac launcher, app closed | 7 (`stepover run` watches, opens the prompt) |

## Left to the builder

- The workflow layout, runner image and caching (Homebrew packages, the build-deps output).
- How the D3D11/D3D12 test programs are written and built.
- The exact crash signatures read from the bottle log.
- How long a first-launch snapshot is kept.
- The index's exact JSON shape, and how the app caches it.
- Migration for existing installs: `cx26.3` (and `cx26.3.old` on the maintainer's Mac) enter the index
  as `available`, and today's bundled manifest keeps working for apps that predate the index.

## What would change this design

- The runner cannot build Wine within its limits: then the pipeline runs on a self-hosted runner (the
  maintainer's Mac), with the same scripts.
- The runner has no Metal and a D3DMetal mismatch ships: then add a manual "approve" step only for
  runtimes whose CrossOver version is a new minor release (26.x to 27.0), keeping patch releases
  automatic.
