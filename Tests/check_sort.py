#!/usr/bin/env python3
"""Checks the whole photos folder after sorting against <archive>.expected.json: every file in the
expected place with the expected content and capture date, and no extra files.

  check_sort.py <photos-folder> <archive.zip> sorted1|sorted2
"""
import hashlib
import json
import os
import sys
import unicodedata

folder, archive, stage = sys.argv[1], sys.argv[2], sys.argv[3]
with open(archive + ".expected.json") as handle:
    expected = json.load(handle)[stage]

# The disk may store umlauts decomposed (NFD); compare them composed.
found = {}
for directory, _, names in os.walk(folder):
    for name in names:
        path = os.path.join(directory, name)
        found[unicodedata.normalize("NFC", os.path.relpath(path, folder))] = path

errors = 0
for relative in sorted(set(expected) - set(found)):
    print(f"FEHLT: {relative}")
    errors += 1
for relative in sorted(set(found) - set(expected)):
    print(f"UNERWARTET: {relative}")
    errors += 1
for relative in sorted(set(expected) & set(found)):
    path = found[relative]
    with open(path, "rb") as handle:
        if hashlib.sha256(handle.read()).hexdigest() != expected[relative]["sha"]:
            print(f"FALSCHER INHALT: {relative}")
            errors += 1
    ts = expected[relative]["ts"]
    if ts is not None:
        info = os.stat(path)
        if int(info.st_mtime) != ts or int(info.st_birthtime) != ts:
            print(f"FALSCHES DATUM: {relative} – geändert {int(info.st_mtime)}, erstellt {int(info.st_birthtime)}, erwartet {ts}")
            errors += 1

print(f"Monatsordner ({stage}, {len(found)} Dateien):", "alles am richtigen Ort" if errors == 0 else f"{errors} Fehler")
sys.exit(1 if errors else 0)
