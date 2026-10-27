# Stepover fixes

Per-game settings that Stepover applies automatically: which graphics layer to use, environment
variables, launch options, DLL overrides, Windows components and registry values. Anyone can add a
fix for any game. The files here are data, never scripts.

- `games/`: fixes written for Stepover. Released into the public domain (CC0, see `games/LICENSE`):
  copy, fork and redistribute them freely.
- `proton/`: fixes converted from [umu-protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes),
  under its BSD-2-Clause license (see `proton/LICENSE`). Regenerate with
  `tools/import-protonfixes.py`; don't edit by hand.

## Adding a fix

The quickest way: get the game working in Stepover, then use **Share Fix** on the program's menu.
It opens GitHub with the file filled in; GitHub offers to make a pull request. You can also write
the file yourself, one game per file, named after the game: `games/stumble-guys.json`.

Pull requests that only add or change files in `games/` and pass the checks are merged
automatically. A person looks only at fixes the checks flag (see "Safety" below).

You don't need anyone's approval to use a fix: put it in Stepover's local Fixes folder
(**Fixes > Open Fixes Folder**), or host your own list and add it under **Fixes > Fix Sources**.

## Format

```json
{
  "name": "Stumble Guys",
  "match": { "steam": [1677740], "exe": ["Stumble Guys.exe"] },
  "graphics": "d3dmetal",
  "env": { "SOME_VARIABLE": "1" },
  "args": ["-windowed"],
  "dlls": { "ddraw": "native,builtin" },
  "components": ["vcrun2022"],
  "registry": [
    { "key": "HKCU\\Software\\Wine\\Direct3D", "name": "MaxVersionGL", "type": "REG_DWORD", "value": "0x40006" }
  ],
  "notes": "Why the game needs this.",
  "source": "Who found it, or a link."
}
```

Only `name` and `match` are required. A file may also hold an array of fixes.

| Field | Meaning |
|---|---|
| `match.steam` | Steam app IDs (the number in the game's store URL). Matches the game when it's installed through Steam in a bottle; the settings then go to that game's own files. |
| `match.exe` | Program file names, case-insensitive, without folders. Matches when a bottle has that program (or it sits next to one of the bottle's programs, like a game next to its launcher). |
| `graphics` | `d3dmetal`, `dxmt`, `dxvk` or `wined3d`, for the matched programs. |
| `env` | Environment variables for the matched programs. |
| `args` | Text appended to the matched programs' command lines (64-bit programs only). For Steam matches without `exe`, they go to the programs in the game's top folder. |
| `dlls` | DLL load order for the matched programs: `native`, `builtin`, `native,builtin`, `builtin,native` or `disabled`. |
| `windowsVersion` | The Windows version the matched programs see (`win10`, `win7`, `winxp`, ...), set for those programs only. |
| `components` | [winetricks](https://github.com/Winetricks/winetricks) verbs, installed once per bottle. Not allowed: Windows versions (use `windowsVersion`), winetricks settings (`name=value`) and `ole32`/`oleaut32`, because they change the whole bottle and bottles are shared (Steam and all its games). |
| `registry` | Values set once per bottle: `key` (under `HKCU\` or `HKLM\`), `name`, `type` (`REG_SZ` or `REG_DWORD`), `value`. |
| `notes`, `source` | Free text, shown in the app. |

**When it applies.** A fix applies in a bottle where its game is found. Settings (graphics,
environment, DLLs, arguments) take effect when the program starts. Components, registry values and
Windows versions are installed when Stepover starts a program in that bottle while nothing else
runs there; for Steam games, that's when you start Steam. A component that fails to install isn't
retried automatically (installing it from **Components** tries again).

**One fix per game.** If several fixes match the same game (Steam ID or program name), the most
specific one is used: your own, then sources you added, then the official hand-written fixes
(`games/`), then the converted ones (`proton/`).

**Your settings win.** A program's or process's own settings in the bottle (including its own
`WINEDLLOVERRIDES`), the bottle's environment variables and its `WINEDLLOVERRIDES` all take
precedence over a fix; DLL overrides set in winecfg don't. A bottle can turn fixes off as a whole
or one by one, and registry values a fix set are removed when it stops applying.

## Safety

The checker (`stepover fixes check <files>`) protects one thing: your Mac and your files. Programs
in a bottle can reach your whole home folder, so a fix that arrives automatically must not be able
to run a command by itself (for example `cmd /c del ...`). It does not judge DRM, licensing,
anti-cheat or anyone's terms of service; that is between players and companies.

Always allowed: every DLL override (it only chooses between DLLs already on disk; a fix cannot add
files), launch arguments, winetricks components (within the rule above), number values (`REG_DWORD`)
under a vendor's or game's registry key (`HKCU\Software\<Vendor>\...` or
`HKLM\Software\<Vendor>\...`), and any value under Wine's settings keys (`Direct3D`,
`DirectInput`, `DirectSound`, `Mac Driver`, `X11 Driver`, `DllOverrides`, `Fonts\Replacements`,
and the same per program under `AppDefaults\<exe>`).

Flagged for a person to look at, because numbers can't be commands but text can:

- text values (`REG_SZ`) under vendor keys, such as a license key or a path a launcher reads;
- anything under `Software\Microsoft`, `Software\Classes`, `Software\Policies`, `System`,
  `Control Panel` or `Environment`. That is where every key lives that makes Windows run a
  command: `Run`, `RunOnce`, `Winlogon`, `Image File Execution Options`, `AeDebug` (runs on every
  crash), `AppInit_DLLs`, file-type and COM server commands, services, the screen saver, and the
  environment;
- the rest of `Software\Wine`: `WineBrowser` and `Mailers` hold Mac commands that Wine runs when
  a program opens a web or mail link;
- environment variables that inject code into Wine, move it, or change what programs run:
  `DYLD_*`, `LD_*`, `WINEPREFIX`, `WINESERVER`, `WINELOADER`, `WINEDLLPATH`, `PATH`, `PATHEXT`,
  `COMSPEC`, `HOME`, `STEPOVER_*` (use `dlls` for DLL overrides);
- fixes naming a program many games share, like `steam.exe`, `launcher.exe` or Windows' own
  programs, since they would change it for everyone.

Program names can't contain folders, brackets, `=`, `;` or `#`, and no text may contain line
breaks; those fixes are rejected outright.

A flagged item in a pull request waits for a person instead of merging automatically. From a
source you added, flagged items are left out (and listed) unless you mark that source as trusted.
Your own local fixes are always applied exactly as written.
