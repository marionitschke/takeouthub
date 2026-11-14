#!/usr/bin/env python3
"""Checks the file dates after extraction against <archive>.expected.json.

  check_dates.py <photos-folder> <archive.zip>
"""
import json
import os
import sys
import unicodedata

folder, archive = sys.argv[1], sys.argv[2]
with open(archive + ".expected.json") as handle:
    expected = json.load(handle)

errors = 0
for relative, ts in expected["dated"].items():
    path = os.path.join(folder, relative)
    # The disk may store umlauts decomposed (NFD)
    if not os.path.exists(path):
        path = unicodedata.normalize("NFD", path)
    try:
        info = os.stat(path)
    except FileNotFoundError:
        print(f"FEHLT: {relative}")
        errors += 1
        continue
    ok = int(info.st_mtime) == ts and int(info.st_birthtime) == ts
    if not ok:
        print(f"FALSCH: {relative} – geändert {int(info.st_mtime)}, erstellt {int(info.st_birthtime)}, erwartet {ts}")
        errors += 1

for relative in expected["undated"]:
    info = os.stat(os.path.join(folder, relative))
    if any(int(info.st_mtime) == ts for ts in expected["dated"].values()):
        print(f"UNERWARTET DATIERT: {relative}")
        errors += 1

for relative in expected["absent"]:
    if os.path.exists(os.path.join(folder, relative)):
        print(f"SOLLTE FEHLEN: {relative}")
        errors += 1

print("Dateidaten:", "alle richtig" if errors == 0 else f"{errors} Fehler")
sys.exit(1 if errors else 0)
