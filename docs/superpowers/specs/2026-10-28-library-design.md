# Library: games first, and you know before you try

**Date:** 2026-10-28
**Status:** draft for the maintainer's approval

## Why

Stepover's window today is a CrossOver-style settings panel: a Bottles sidebar, then Bottle, Environment and
Tools sections (`app/Sources/StepoverApp/StepoverApp.swift`, `NavigationSplitView`). The Mac players
CrossOver doesn't reach think in games, not bottles.

GameSir's GameHub (Mac beta since April 2026, closed source, needs a GameSir account) goes after the same
people with a cover-art library and Steam and Epic sign-in. The maintainer's point about it: "even though
gamehub has sign in for steam and epic, doesn't mean users can play every game and likely wouldn't even
know that until they tried."

The maintainer's rule for this and everything after it: **always think frictionless.** Tell people what
will and won't work before they spend money, time or disk, and make every default the zero-step one.

## What it is

1. **The Library is the first screen:** your games as cover art with a Play button, and on every game two
   plain answers: will it play on this Mac, and does it work with a controller.
2. **"Can I play it?" before you install:** search any game by name, or paste a Steam store link, and get the
   same two answers plus the next step.
3. **Your Mac's own result counts more than any prediction.**

## Goals

- **G1. Library first.** The app opens on a grid of your games: portrait cover art, the name, the
  playability line and a controller badge. Play is one click (or Return). Most recently played first.
- **G2. Every game says why.** Selecting a game shows the verdict and each reason behind it in one line,
  with its source ("Tested on a MacBook Air M3 with CrossOver 25: perfect. AppleGamingWiki").
- **G3. Search before you install.** A search field takes a game name or a Steam store URL and shows the
  verdict card for a game you don't have yet, with the next step as a button.
- **G4. Games appear by themselves.** Programs already in bottles, every installed Steam game in any bottle,
  and an installer dropped on the window all become tiles with no setup.
- **G5. Your result.** After you play, Stepover records how it went on this Mac without asking when it can
  tell, and with one click when it can't.
- **G6. Private and offline.** No account and no telemetry. Verdicts come from one cached list, and matching
  your games to it happens on the Mac. Stepover talks only to public pages: the list itself, Steam's image
  server for cover art of matched games, and Steam's store pages when you search for a game the list doesn't
  have. It works offline from what it has cached. (my call: art for every matched game is worth Valve's
  image server seeing which covers are fetched; it's the same server Steam itself uses)

## Non-goals

- Signing in to Steam or Epic inside Stepover. Steam runs in its bottle and does its own sign-in.
- Epic and GOG store integration (later). Their installers still work through Add Game.
- A separate app.
- A full-screen, controller-driven "couch mode" (later; the Library is designed so it can grow into one).
- Frame-rate predictions.
- Changing what a bottle can do. Today's bottle page stays, one click away.

## Anti-goals (failure even if it works)

- **A confident badge that's wrong.** "Plays great" on a game that won't start is worse than "Not tested
  yet". Only evidence from a Mac earns a "tested on Mac" verdict.
- **Blocking.** A verdict informs, it never prevents. "Won't run" still has Try Anyway.
- **Tracking.** No telemetry, no account, and no sending someone's list of games anywhere. Matching happens
  on the Mac against the downloaded list.
- **Wine words on the Library.** No "bottle", "runtime", "prefix" or "D3DMetal" on the Library screen or the
  verdict card. They live behind Settings.

## Verdicts

### Will it play? (first match wins)

1. **Your result on this Mac** (G5): "Runs on this Mac (you played 2 h)" or "Had problems on this Mac".
2. **A Mac version exists** (Steam `platforms.mac`, and AppleGamingWiki's `native` isn't `unplayable`):
   "There's a Mac version", with Get It in Steam for Mac. Honest beats keeping someone in Stepover. Try the
   Windows Version stays available. When AppleGamingWiki says the native version is `unplayable` (old 32-bit
   Mac builds that stopped working with macOS Catalina), skip this rule and add "The old Mac version doesn't
   run on current macOS". With no AppleGamingWiki rating for it: "There's a Mac version (not checked on
   current macOS)". (my call)
3. **Tested on Mac and doesn't run** (AppleGamingWiki `crossover` and `wine` both `unplayable`, or one
   `unplayable` and the other unknown): "Doesn't run on Mac yet". A rating dated before June 2023 (before
   Apple's D3DMetal) doesn't trigger this rule when the Steam Deck says Verified or Playable; it shows as an
   older reason instead ("An older Mac test (2022) didn't run"). (my call)
4. **Anti-cheat.** Any game in AreWeAntiCheatYet counts, whatever its Linux status: its Proton support uses
   Linux-only pieces that don't exist under Wine on a Mac. With Steam's "Single-player" category: "Single-player
   only: online play needs anti-cheat that doesn't work on Mac". Without it: "Won't run: needs anti-cheat that
   doesn't work on Mac". An AppleGamingWiki rating of `perfect` or `playable` keeps its verdict from step 5
   and adds the single-player line.
5. **Tested on Mac** (AppleGamingWiki `crossover` or `wine`, the better of the two): `perfect` "Plays great
   (tested on Mac)", `playable` "Playable (tested on Mac)", `runs` "Starts, with problems (tested on Mac)".
6. **Linux evidence only:** Steam Deck Verified or Playable, or ProtonDB gold or platinum: "Should play (works
   on Steam Deck, not tested on Mac yet)". Deck Unsupported or ProtonDB borked: "Probably won't run".
7. **Nothing known:** "Not tested yet. Try it; Stepover will remember how it went."

When Stepover's fix list has a fix for the game, every verdict adds "Stepover applies a fix for this game
automatically".

### The next step on each verdict

| Verdict | Main button | Also |
|---|---|---|
| Your game, any verdict | Play | Settings |
| Not installed, playable or unknown | Install with Steam (Steam games), Choose Installer… (others) | |
| There's a Mac version | Get It in Steam for Mac | Windows Version |
| Won't run, Doesn't run on Mac yet | none | Try Anyway |
| Single-player only | the same as playable | |

**Install with Steam does everything** (frictionless): with no Steam yet, Stepover makes a Steam bottle,
downloads SteamSetup.exe from Valve, installs it silently, starts Steam (with the fix that keeps its window
from going black) and opens the game's install page in Steam (`steam://install/<id>`). The person signs in to
Steam once, in Steam. With Steam in more than one bottle, it uses the one with the most recent game. (my call:
this is the largest piece of plan B, and it is the difference between "you could install this" and "it's
installing")

### Controller

- Steam category "Full controller support": **Full controller support**.
- Steam category "Partial Controller Support" and the Steam Deck report's controller test passes: **Controller
  works; some menus may need a mouse**. (Red Dead Redemption 2 is this case: Steam says partial because of
  Rockstar's launcher, the Deck says the controller works.)
- "Partial Controller Support" alone: **Partial controller support**.
- Steam data but neither category: **Keyboard and mouse**.
- No Steam data: no badge.
- Your result wins: "Played with a controller on this Mac" when a controller sent input during a good
  session (G5).

## Data: one list, built daily

- A CI job (next to the daily runtime job) builds `games.json`. Each entry has a stable id, its names (the
  store name plus other names it goes by, for matching on the Mac), and whichever store IDs are known:
  Steam app ID, Epic, and the others AreWeAntiCheatYet lists. A game with no Steam app ID is still in the list,
  so Valorant or Fortnite through Add Game still gets "Won't run". (my call) Sources:
  - **AppleGamingWiki** (`https://www.applegamingwiki.com/w/api.php`): the `Compatibility/macOS` template
    fields `crossover`, `wine`, `native`, `rosetta 2`, the tester's device and date from the first
    `Refdevice`, and the page's Steam app ID. Licensed CC BY-NC-SA 3.0: Stepover is free, the list keeps that
    license, and the app credits AppleGamingWiki on every verdict that uses it and under Help > Licenses.
  - **AreWeAntiCheatYet** `games.json` (MIT): anti-cheat names and status.
  - **Steam store** `appdetails` (name, `platforms`, categories) and the **Steam Deck report**
    (`resolved_category` and the controller test) for each game in the list.
  - **ProtonDB** tier, only if its terms allow redistribution (the builder checks; otherwise leave it out).
  - **Stepover's fix list**: which games have a fix.
- Which games: every game in AppleGamingWiki, AreWeAntiCheatYet and the fix list, plus Steam's most played
  (a source that needs no key). A few thousand entries.
- **Published as a rolling GitHub release asset** (tag `games-list`), so `main`'s history doesn't change daily.
  Each app release bundles a snapshot for a first launch with no network. (my call)
- The app fetches it at launch when its copy is over a day old, and keeps the cached copy on any failure
  (the same rules as `RuntimeIndex.fetch`). `STEPOVER_GAMES_LIST` (a URL or a file) overrides the location.
- **Search for a game not in the list** looks that one game up from the Mac: Steam store search,
  `appdetails`, the Deck report (and ProtonDB if allowed). The same lookup runs for an installed Steam game
  the list doesn't have, at most once a week per game. (my call)
- No API keys anywhere. Cover art comes from Steam's CDN by app ID (`library_600x900.jpg`), which needs none.

## The Library screen

- **Toolbar:** a search field ("Find a game"), Add Game, and a controller indicator that names the
  connected controller or says "No controller". Seeing the controller before launch saves a trip into a
  game to find out.
- **Grid:** portrait cover art cached under `<root>/Art/<appid>.jpg`. With no art, the program's own icon on a
  tinted tile with the name.
- **Tile:** art, name, the playability line (a word and a color, never color alone), the controller badge.
  Hover or selection shows Play and a menu: Settings (today's bottle page), Show in Finder, Hide from Library,
  and Delete Game….
- **Hide from Library** only hides the tile (View > Hidden Games brings it back). **Delete Game…** says what
  goes and how much space comes back, warns that saves inside the game's folder go with it, and for a game in
  a Steam bottle hands off to Steam's own uninstall instead. Nothing is deleted without that confirmation. (my
  call)
- **Wine runtime, in plain words:** on a first launch the runtime download starts by itself and shows its
  progress in the Library's toolbar; search and verdicts work meanwhile, and Play waits for it. A newer runtime
  shows as a quiet line in the toolbar, "A compatibility update is ready" with Download, and the details stay
  in Wine Runtimes. Updates are still offered rather than installed by themselves, as the runtime design says.
  (my call)
- **Detail panel** for the selected game: large art, the verdict and its reasons with sources, the fixes
  Stepover applies, Play, Settings.
- **Order:** last played first (`recent.json`), then by name.
- **Empty Library:** the search field front and center, and Import from CrossOver when CrossOver bottles exist.
- **Bottles stay reachable:** View > Bottles shows today's panel for people who want it. (my call)

## Games appear by themselves (G4)

- Each program in a bottle's `stepover.json` is a tile. In practice a bottle is named after its game, so it
  is one tile.
- Each installed Steam game in any bottle (`SteamLibrary.apps`) is a tile with its app ID known. Play starts it
  through Steam in its bottle. Steam itself is one tile.
- **Matching non-Steam games** (for art and a verdict): against the names in the downloaded list, on the
  Mac, accepting only a close match. Otherwise no art and "Not tested yet" rather than a wrong game: a Steam
  store search for "Sainthood" returns Saints Row, which is exactly the mistake to avoid. The detail panel has
  "Not this game?" to search and pick another, or none. (my call)
- **Add Game, or dropping a setup.exe or .msi on the window:** shows the verdict card for the matched game
  first, then creates a bottle named after the game and runs the installer (`WindowsSetup.install`). One step
  from file to installing.

## Your result (G5)

- Sessions are watched by the same session watcher the runtime design's section 7 describes for plan 4, and
  "crashed" means what that section says (not "quit quickly": launchers exit on purpose). Whichever of plan C
  and runtime plan 4 comes first builds the watcher; the other uses it. (my call)
- A session that lasts at least 10 minutes and doesn't crash marks the game "Runs on this Mac (you played
  N h)" with no prompt. The detail panel shows it with a Change link.
- A crash marks "Had problems on this Mac" and offers the report from plan 4 when that exists.
- A controller (GameController framework) that sends input during a good session records "Played with a
  controller on this Mac".
- Results stay on this Mac. Sharing them to improve the list is a later, opt-in feature.

## Constraints

- macOS 14 or later, SwiftUI, logic in StepoverKit so it is unit tested, no new dependencies.
- No em dashes in UI copy. Plain words, as in the rest of the app.
- Endpoints come from env vars with defaults (`STEPOVER_GAMES_LIST`), like `STEPOVER_RUNTIME_INDEX`.
- Steam's public endpoints are rate limited: CI throttles itself, and the app makes at most a few requests
  per search.
- The maintainer's design rules: no colored rail on the left of a rounded card, no emoji as markers, a look
  made for this audience rather than a generic one.

## Order and phasing

After 0.3.0 is merged and released, branched from `main` then (the Library replaces window code that 0.3.0
changes), and before runtime plans 3 to 5 (nothing publishes runtimes automatically yet).

- **Plan A, the games list:** CI job, `games.json` format, the app's loader and the verdict and controller
  rules as pure functions with tests.
- **Plan B, the Library screen:** grid, art cache, tiles, detail panel, search, Add Game and drop, View > Bottles.
- **Plan C, your result:** session outcome and controller detection.

A and B ship together as 0.4.0; C can follow. The r/macgaming post waits for 0.4.0, since screenshots of
this screen are what make that post land.

## Left to the builder

- Layout, sizes, spacing and colors within the constraints above.
- The CI job's structure and how often Steam data is refreshed per game (daily is not required).
- The name-matching threshold.
- Whether ProtonDB can be used.
