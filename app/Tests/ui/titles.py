# Prints the title the Library gives each program name read from stdin, one per line, for the UI checks: the name of
# the one game in the games list (else in learned games) that the program's own name matches, else the name itself.
# Mirrors GameName.normalized and Library.games' name rule. Usage: titles.py <games.json> [<learned-games.json>]
import json
import re
import sys
import unicodedata

EDITIONS = ["game of the year edition", "goty edition", "goty", "complete edition", "ultimate edition", "deluxe edition"]


def normalized(name):
    text = "".join(c for c in unicodedata.normalize("NFKD", name.casefold()) if not unicodedata.combining(c))
    for mark in "™®©":
        text = text.replace(mark, "")
    words = " ".join(re.sub(r"[\W_]", " ", text.replace("&", " and ")).split())
    for edition in EDITIONS:
        if words.endswith(" " + edition):
            return words[: -len(edition) - 1]
    return words


def index(games):
    keys = {}
    for game in games:
        for key in {normalized(n) for n in [game["name"]] + game.get("names", [])} - {""}:
            keys.setdefault(key, {})[game["id"]] = game["name"]
    return keys


def load(path, field):
    try:
        with open(path) as f:
            return json.load(f).get(field, [])
    except (OSError, ValueError):
        return []


lists = [index(load(sys.argv[1], "games"))] + ([index(load(sys.argv[2], "entries"))] if len(sys.argv) > 2 else [])
for line in sys.stdin.read().splitlines():
    found = [next(iter(m.values())) for m in (keys.get(normalized(line), {}) for keys in lists) if len(m) == 1]
    print(found[0] if found else line)
