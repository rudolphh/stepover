# Couch mode: the Library on a TV, driven by a controller

**Date:** 2026-10-28
**Status:** approved by the maintainer 2026-10-28

## Why

The maintainer plays on a 4K TV from the couch: "would a frontend work with controller to not have to touch
the mac if switching between games and i can put it fullscreen on my 4k tv". Today every step between games
needs the keyboard or mouse: picking a game, quitting one, starting the next. Couch mode is the Library
(`docs/superpowers/specs/2026-10-28-library-design.md`) at TV distance, where the controller does everything.
The rule stays: always think frictionless.

## What it is

1. A full-screen version of the Library, sized for a TV across the room: the selected game fills the
   screen, a row of covers runs along the bottom, and the two answers (will it play, controller) stay on show.
2. The controller does everything: move between games, Play, see why, hide a game, leave couch mode.
3. From inside a game, one controller shortcut brings Stepover back with Resume and Quit Game, so switching
   games never needs the Mac.

## Goals

- **C1. Enter and leave.** View > Couch Mode (⌘⇧F); Menu > Leave Couch Mode on the controller. When Stepover
  opens with a controller connected, it opens in couch mode. (my call: the controller being on is the
  clearest sign of the couch; a Settings switch turns it off) Couch mode needs Stepover running: its
  settings offer Open at Login (off until switched on), and if the window was closed the in-game shortcut
  reopens it. A game started from a Mac launcher while Stepover is closed has no shortcut. (my call)
- **C2. Full screen on the TV.** Couch mode fills the display Stepover's window is on, in native full screen,
  at the TV's resolution. Text and covers are sized for about 3 m away (titles 2.5x the window's, covers at
  least 1/6 of the screen width).
- **C2b. The screen games open on.** Games go full screen on the main display (the one with the menu bar),
  not necessarily couch mode's. The maintainer's setup varies (TV alone, or beside the Mac's screen), so
  when couch mode is on a display that isn't the main one, it says so on the TV: "Games open on your other
  screen" with Make This the Main Display (A), which moves the menu bar to this screen the way System
  Settings > Displays does, only when pressed. (my call, after the maintainer answered "Not sure / varies")
- **C3. One row of games.** The selected game's art fills the screen behind its title, the verdict and
  controller pills, Play and the reasons; one horizontal row of covers at the bottom, last played first,
  the selected one larger. Same games, order, answers and hidden games as the Library.
- **C4. Controller.** Left stick or d-pad: move (holding repeats). A: Play. X: Why (the reasons, full size).
  Y: Hide from Library (asks once more with A). B: back (closes Why or the in-game overlay; on the row it
  does nothing). Menu (Start): Leave Couch Mode, Show Hidden Games, Stop Everything. The keyboard works the
  same (arrows, Return, Escape, Space for Why) so it can be tested and used without a controller.
- **C5. Back from a game.** While a game Stepover started is running (and only then, so native Mac games,
  Steam for Mac and emulators keep their own Select and Start), Stepover keeps listening to the controller
  (`GCController.shouldMonitorBackgroundEvents`). Holding the Home button for half a second, or holding
  Select and Start together for one second, shows the in-game panel over the game: a small, non-activating
  floating panel above full-screen apps, so the game never loses focus and macOS's limits on apps bringing
  themselves forward don't apply. It offers Resume (A or B: the panel goes away) and Quit Game (X, then A to
  confirm). Quit Game ends just that game: for a Steam game, only the processes running from its folder, so
  Steam stays open and syncs its cloud saves; for any other game, its bottle is stopped. After quitting,
  couch mode is in front again (C6). The Home button only works when macOS isn't using it (System Settings >
  Game Controllers); Select and Start always work. The shortcut's presses also reach the game (GameController
  can listen, not hold presses back); most games pause on Start, which is fine. (my calls)
- **C6. When a game ends,** by itself or through Quit Game, couch mode comes back to the front on the row
  with that game selected. "Ended" is a process check (no process left from the game's folder, or for a
  non-Steam game, its bottle stopped), until plan C's session watcher replaces it. (my call)
- **C6b. Playing a different game while one runs:** A on the running game is Resume; A on another game offers
  "Quit <running game> and play <game>" in one step. (my call: two games at once is never what the couch wants,
  and Steam's own "already running" window can't be answered with a controller)
- **C7. Waiting and failing in plain words.** While the first runtime downloads: "Getting ready to play: N%"
  and Play waits. A failed launch shows its reason on the TV with B to dismiss, never a Mac alert box.

## Non-goals

- Searching and installing games from the couch (an on-screen keyboard); that's B2's search, later.
- Editing a game's settings with the controller; Settings stays on the Mac.
- Steam's own Big Picture mode; launching Steam from couch mode opens Steam as it opens today.
- Picking which display couch mode uses; it uses the one Stepover's window is on.

## Anti-goals

- **Getting stuck.** There is always a way back with the controller alone: from a game (C5), from the
  overlay (B), and out of couch mode (Menu).
- **A Mac dialog on the TV.** No alert box, file picker or sheet ever opens in couch mode; anything that
  needs the Mac says so on screen.
- **Stealing the controller from a game.** Background listening only reacts to the two shortcuts, and only
  while a Stepover game runs; every button press still reaches the game.

## Order

Plan B3, right after the Library screen (B1) and before search and installing (B2), at the maintainer's
request. Its first task is a spike with the maintainer's controller and TV that confirms the technical
assumptions before the rest is planned in detail: that background controller events arrive while a Wine game
uses the controller, which buttons arrive in the background (Home, Select, Start on the maintainer's
8BitDo), that the floating panel shows over a full-screen Wine game, and whether background monitoring asks
for Input Monitoring permission (ad-hoc signing would reset it on every build).

## Constraints

- macOS 14 or later, SwiftUI and GameController (Apple's frameworks), no new dependencies.
- The Library's rules and copy carry over (verdict wording, no Wine words, colors always with words).
- Logic that decides things (focus movement, the shortcut detector with its timings, what the overlay
  offers) lives in StepoverKit with tests; the views stay thin.

## Left to the builder

- The exact sizes, spacing and animation of the row and the hero, within C2 and C3.
- How the row scrolls (centered on the selection or edge-follow).
- Repeat timing for held directions.
