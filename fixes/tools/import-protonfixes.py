#!/usr/bin/env python3
"""Convert umu-protonfixes Steam game fixes into Stepover fix files.

Usage: python3 -I import-protonfixes.py <umu-protonfixes dir> <output dir>

The input is untrusted: its Python is only parsed with `ast`, never imported or run.
A gamefix is converted only if main() consists solely of calls to supported util.*
functions with literal arguments. See fixes/README.md for the output format.
"""
import ast
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

REPO_URL = "https://github.com/Open-Wine-Components/umu-protonfixes"
WINETRICKS = "/opt/homebrew/bin/winetricks"

# Linux/Proton-only environment variables.
DROP_ENV_PREFIXES = ("PROTON_", "DXVK_", "VKD3D_", "PULSE_", "MESA_", "RADV_", "__GL_",
                     "UMU_", "STAGING_", "WINE_DISABLE_VULKAN", "SDL_VIDEODRIVER", "LD_")
DROP_ENV_NAMES = {"SteamDeck"}
# fixes/README.md "Safety": variables that inject code into Wine or move it.
FLAGGED_ENV_PREFIXES = ("DYLD_", "LD_", "STEPOVER_")
FLAGGED_ENV_NAMES = {"WINEPREFIX", "WINESERVER", "WINELOADER", "WINEDLLPATH", "PATH", "HOME"}

IGNORED_UTILS = {"disable_esync", "disable_fsync", "disable_ntsync"}
SUPPORTED_UTILS = IGNORED_UTILS | {"protontricks", "winedll_override", "set_environment",
                                   "append_argument", "regedit_add"}
ORDER_NAMES = {"": "disabled", "n": "native", "b": "builtin", "n,b": "native,builtin",
               "b,n": "builtin,native"}


class Reject(Exception):
    pass


def load_winetricks_verbs():
    out = subprocess.run([WINETRICKS, "list-all"], capture_output=True, text=True,
                         check=True).stdout
    verbs, in_section = set(), False
    for line in out.splitlines():
        if line.startswith("====="):
            in_section = True
        elif in_section and line.strip() and not line[0].isspace():
            verbs.add(line.split()[0])
    if not verbs:
        sys.exit("could not read any verbs from `winetricks list-all`")
    return verbs


def load_override_order(util_py):
    """Map OverrideOrder member name -> Stepover order, from util.py via ast."""
    tree = ast.parse(util_py.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == "OverrideOrder":
            members = {}
            for st in node.body:
                if (isinstance(st, ast.Assign) and len(st.targets) == 1
                        and isinstance(st.targets[0], ast.Name)
                        and isinstance(st.value, ast.Constant)
                        and st.value.value in ORDER_NAMES):
                    members[st.targets[0].id] = ORDER_NAMES[st.value.value]
            return members
    sys.exit("OverrideOrder not found in util.py")


def literal(node, order_members):
    """Literal str/int argument, or util.OverrideOrder.<NAME> as ('order', name)."""
    if isinstance(node, ast.Constant) and isinstance(node.value, (str, int, float)) \
            and not isinstance(node.value, bool):
        return node.value
    if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Attribute)
            and node.value.attr == "OverrideOrder"
            and isinstance(node.value.value, ast.Name) and node.value.value.id == "util"):
        if node.attr not in order_members:
            raise Reject("unknown OverrideOrder." + node.attr)
        return ("order", order_members[node.attr])
    raise Reject("non-literal argument")


def registry_key_flagged(key):
    segs = [s.lower() for s in key.split("\\")]
    for i, s in enumerate(segs):
        if s in ("winlogon", "image file execution options", "services", "environment"):
            return True
        if s in ("run", "runonce", "runonceex", "runservices", "runservicesonce") \
                and i > 0 and segs[i - 1] == "currentversion":
            return True
        if s == "shell" and "command" in segs[i + 1:]:
            return True
    return False


WINDOWS_VERSIONS = {"win11", "win10", "win81", "win8", "win7", "win2008r2", "win2008", "vista",
                    "win2003", "winxp64", "winxp", "win2k", "nt40", "winme", "win98", "win95"}
WHOLE_BOTTLE_VERBS = {"ole32", "oleaut32"}


def convert_file(path, appid, verbs, order_members, stats):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    mains = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "main"]
    if not mains:
        raise Reject("no def main")
    # Module-level code runs on import in umu, so only allow inert statements.
    for n in tree.body:
        inert = (isinstance(n, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef,
                                ast.AsyncFunctionDef))
                 or (isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant))
                 or (isinstance(n, (ast.Assign, ast.AnnAssign))
                     and isinstance(getattr(n, "value", None), ast.Constant)))
        if not inert:
            raise Reject("module-level code")
    main = mains[0]

    env, args, dlls, components, registry = {}, [], {}, [], []
    windows_version = [None]  # a list so the loop can set it
    seen_call = False
    for st in main.body:
        if isinstance(st, ast.Pass):
            continue
        if isinstance(st, ast.Expr) and isinstance(st.value, ast.Constant) \
                and isinstance(st.value.value, str):
            continue
        if not (isinstance(st, ast.Expr) and isinstance(st.value, ast.Call)):
            raise Reject("main has a non-call statement (%s)" % type(st).__name__)
        call = st.value
        f = call.func
        if not (isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name)
                and f.value.id == "util"):
            raise Reject("main calls something other than util.*")
        if f.attr not in SUPPORTED_UTILS:
            raise Reject("unsupported util." + f.attr)
        if call.keywords or any(isinstance(a, ast.Starred) for a in call.args):
            raise Reject("keyword/starred arguments in util." + f.attr)
        vals = [literal(a, order_members) for a in call.args]
        seen_call = True
        name = f.attr
        if name in IGNORED_UTILS:
            continue
        if name == "protontricks":
            if len(vals) != 1 or not isinstance(vals[0], str):
                raise Reject("bad util.protontricks arguments")
            verb = vals[0]
            if verb in WINDOWS_VERSIONS:
                # Proton gives each game its own prefix; Stepover bottles are shared, so the
                # Windows version becomes a per-program setting instead of a whole-bottle verb
                windows_version[0] = verb
            elif verb not in verbs or "=" in verb or verb in WHOLE_BOTTLE_VERBS:
                # unknown to winetricks, a winetricks setting (whole bottle; sound=alsa is Linux
                # audio), or a core Windows part replaced for the whole (shared) bottle
                stats["verbs"][verb] += 1
            elif verb not in components:
                components.append(verb)
        elif name == "winedll_override":
            if len(vals) != 2 or not isinstance(vals[0], str) \
                    or not (isinstance(vals[1], tuple) and vals[1][0] == "order"):
                raise Reject("bad util.winedll_override arguments")
            dlls[vals[0]] = vals[1][1]
        elif name == "set_environment":
            if len(vals) != 2 or not isinstance(vals[0], str) or isinstance(vals[1], tuple):
                raise Reject("bad util.set_environment arguments")
            k = vals[0]
            if k.startswith(DROP_ENV_PREFIXES) or k in DROP_ENV_NAMES:
                stats["env"][k] += 1
            elif k.startswith(FLAGGED_ENV_PREFIXES) or k in FLAGGED_ENV_NAMES:
                stats["env_flagged"][k] += 1
            else:
                env[k] = str(vals[1])
        elif name == "append_argument":
            if len(vals) != 1 or not isinstance(vals[0], str):
                raise Reject("bad util.append_argument arguments")
            args.append(vals[0])
        elif name == "regedit_add":
            if len(vals) != 4 or not all(isinstance(v, (str, int)) for v in vals):
                raise Reject("regedit_add without all four literal arguments")
            key, rname, typ, value = vals
            if typ not in ("REG_SZ", "REG_DWORD"):
                raise Reject("regedit_add type " + str(typ))
            key = re.sub(r"^HKEY_CURRENT_USER\\", "HKCU\\\\", str(key))
            key = re.sub(r"^HKEY_LOCAL_MACHINE\\", "HKLM\\\\", key)
            if not key.startswith(("HKCU\\", "HKLM\\")):
                stats["reg_skipped"]["key outside HKCU/HKLM"] += 1
            elif registry_key_flagged(key):
                stats["reg_skipped"]["flagged key"] += 1
            else:
                registry.append({"key": key, "name": str(rname), "type": typ,
                                 "value": str(value)})
    if not seen_call:
        raise Reject("main has no util calls")

    fix = {}
    doc = ast.get_docstring(tree)
    title = doc.splitlines()[0] if doc and doc.strip() else ""
    title = re.sub(r"\s*-\s*ID\s*\d+\s*$", "", title).strip()
    title = re.sub(r"^Game fix(es)?( for)?\s+", "", title, flags=re.I).strip()
    fix["name"] = title or "Steam app %d" % appid
    fix["match"] = {"steam": [appid]}
    for k, v in (("env", env), ("args", args), ("dlls", dlls),
                 ("components", components), ("registry", registry), ("windowsVersion", windows_version[0])):
        if v:
            fix[k] = v
    if len(fix) == 2:
        raise Reject("nothing usable after mapping")
    return fix


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    full = subprocess.run(["git", "-C", str(src), "rev-parse", "HEAD"], capture_output=True,
                          text=True, check=True).stdout.strip()
    short = subprocess.run(["git", "-C", str(src), "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, check=True).stdout.strip()
    verbs = load_winetricks_verbs()
    order_members = load_override_order(src / "util.py")
    gf = src / "gamefixes-steam"
    files = sorted((int(p.stem), p) for p in gf.glob("*.py") if p.stem.isdigit())

    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("steam-*.json"):
        if old.stem[6:].isdigit():
            old.unlink()

    stats = {"verbs": Counter(), "env": Counter(), "env_flagged": Counter(),
             "reg_skipped": Counter()}
    rejected, converted = Counter(), 0
    for appid, path in files:
        try:
            fix = convert_file(path, appid, verbs, order_members, stats)
        except Reject as e:
            rejected[str(e)] += 1
            continue
        except (SyntaxError, UnicodeDecodeError) as e:
            rejected["unparseable (%s)" % type(e).__name__] += 1
            continue
        fix["notes"] = "Converted from umu-protonfixes."
        fix["source"] = "umu-protonfixes %s, gamefixes-steam/%d.py" % (short, appid)
        (out / ("steam-%d.json" % appid)).write_text(
            json.dumps(fix, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        converted += 1

    lic = (src / "LICENSE").read_text(encoding="utf-8")
    (out / "LICENSE").write_text(
        "These files are converted from umu-protonfixes (%s, commit %s).\n\n%s"
        % (REPO_URL, full, lic if lic.endswith("\n") else lic + "\n"), encoding="utf-8")

    print("umu-protonfixes %s" % short)
    print("files seen: %d" % len(files))
    print("converted:  %d" % converted)
    print("rejected:   %d" % sum(rejected.values()))
    for reason, n in sorted(rejected.items(), key=lambda kv: (-kv[1], kv[0])):
        print("  %4d  %s" % (n, reason))
    for label, c in (("dropped winetricks verbs (unknown)", stats["verbs"]),
                     ("dropped env names (Linux/Proton-only)", stats["env"]),
                     ("dropped env names (flagged by Safety)", stats["env_flagged"]),
                     ("skipped registry items", stats["reg_skipped"])):
        print("%s: %d total, %d distinct" % (label, sum(c.values()), len(c)))
        for k, n in sorted(c.items(), key=lambda kv: (-kv[1], kv[0])):
            print("  %4d  %s" % (n, k))


if __name__ == "__main__":
    main()
