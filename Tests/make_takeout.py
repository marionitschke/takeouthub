#!/usr/bin/env python3
"""Creates artificial Takeout archives with all known sidecar edge cases and writes the
expectations to <target>.expected.json. No real photos.

  make_takeout.py <target.zip> [<part2.zip>]

- "dated", "undated", "absent", "updated", "unmatched": extracting <target.zip> without month folders.
- "sorted1": the whole photos folder after extracting <target.zip> with month folders,
  "sorted2": after <part2.zip> was extracted on top and sorted again.
  SHA-256 per file and the capture time where set. Months in Europe/Berlin local time (set TZ).
"""
import hashlib
import json
import sys
import zipfile

target = sys.argv[1]
second = sys.argv[2] if len(sys.argv) > 2 else None
root = "Takeout/Google Fotos/"
year = root + "Fotos von 2019/"
album = root + "Geburtstag Jürgen/"
trip = root + "Urlaub/"
ZIP_TIME = (2026, 11, 1, 12, 0, 0)

def meta(title, ts):
    return json.dumps({"title": title, "photoTakenTime": {"timestamp": str(ts), "formatted": "x"},
                       "creationTime": {"timestamp": "1700000000"}}).encode()

part1 = {}
part2 = {}
expected = {}       # without month folders: path → capture time
times = {}          # path → capture time (both parts)
moves1 = {}         # archive path → path after the first sort
moves2 = {}         # additional moves after the second part

def media(path, ts=None, part=part1, to=None):
    part[path] = b"\xff\xd8\xff" + path.encode()
    if ts is not None:
        times[path] = ts
        if part is part1:
            expected[path.removeprefix("Takeout/")] = ts
    if to:
        (moves1 if part is part1 else moves2)[path] = to

def sidecar(path, title, ts, part=part1, to=None):
    part[path] = meta(title, ts)
    if to:
        (moves1 if part is part1 else moves2)[path] = to

def into(folder, path):
    """Same name in the month folder `folder` (relative to "Google Fotos")."""
    return "Takeout/Google Fotos/" + folder + "/" + path.rsplit("/", 1)[-1]

# Regular case and edited version
media(year + "IMG_0001.JPG", 1556712000, to=into("Fotos von 2019/05", "IMG_0001.JPG"))
media(year + "IMG_0001-bearbeitet.JPG", 1556712000, to=into("Fotos von 2019/05", "IMG_0001-bearbeitet.JPG"))
sidecar(year + "IMG_0001.JPG.supplemental-metadata.json", "IMG_0001.JPG", 1556712000,
        to=into("Fotos von 2019/05", "IMG_0001.JPG.supplemental-metadata.json"))
# Live Photo: video without its own sidecar
media(year + "IMG_0002.HEIC", 1556798400, to=into("Fotos von 2019/05", "IMG_0002.HEIC"))
media(year + "IMG_0002.MP4", 1556798400, to=into("Fotos von 2019/05", "IMG_0002.MP4"))
sidecar(year + "IMG_0002.HEIC.supplemental-metadata.json", "IMG_0002.HEIC", 1556798400,
        to=into("Fotos von 2019/05", "IMG_0002.HEIC.supplemental-metadata.json"))
# Old format; taken in 2018 → belongs in "Fotos von 2018/06", but a different IMG_0003.jpg is
# already there → stays put
media(year + "IMG_0003.jpg", 1530000000)
sidecar(year + "IMG_0003.jpg.json", "IMG_0003.jpg", 1530000000)
media(root + "Fotos von 2018/IMG_0003.jpg", 1529000000, to=into("Fotos von 2018/06", "IMG_0003.jpg"))
sidecar(root + "Fotos von 2018/IMG_0003.jpg.supplemental-metadata.json", "IMG_0003.jpg", 1529000000,
        to=into("Fotos von 2018/06", "IMG_0003.jpg.supplemental-metadata.json"))
# Duplicate names
media(year + "IMG_0004.jpg", 1560000000, to=into("Fotos von 2019/06", "IMG_0004.jpg"))
media(year + "IMG_0004(1).jpg", 1561000000, to=into("Fotos von 2019/06", "IMG_0004(1).jpg"))
sidecar(year + "IMG_0004.jpg.supplemental-metadata.json", "IMG_0004.jpg", 1560000000,
        to=into("Fotos von 2019/06", "IMG_0004.jpg.supplemental-metadata.json"))
sidecar(year + "IMG_0004.jpg.supplemental-metadata(1).json", "IMG_0004.jpg", 1561000000,
        to=into("Fotos von 2019/06", "IMG_0004.jpg.supplemental-metadata(1).json"))
# Truncated sidecar suffix
media(year + "Screenshot_20190101-120000_WhatsApp.jpg", 1546344000,
      to=into("Fotos von 2019/01", "Screenshot_20190101-120000_WhatsApp.jpg"))
sidecar(year + "Screenshot_20190101-120000_WhatsApp.jpg.supplemental-met.json",
        "Screenshot_20190101-120000_WhatsApp.jpg", 1546344000,
        to=into("Fotos von 2019/01", "Screenshot_20190101-120000_WhatsApp.jpg.supplemental-met.json"))
# Truncated file name (title longer than the name on disk)
media(year + "Ein sehr langer Dateiname für ein Urlaubsfoto am.jpg", 1563000000,
      to=into("Fotos von 2019/07", "Ein sehr langer Dateiname für ein Urlaubsfoto am.jpg"))
sidecar(year + "Ein sehr langer Dateiname für ein Urlaubsfo.json",
        "Ein sehr langer Dateiname für ein Urlaubsfoto am Strand 2019.jpg", 1563000000,
        to=into("Fotos von 2019/07", "Ein sehr langer Dateiname für ein Urlaubsfo.json"))
# New Year's Eve: 31.12.2019 23:30 UTC = 1.1.2020 0:30 in Berlin → "Fotos von 2020/01" (new folder)
media(year + "IMG_0007.jpg", 1577835000, to=into("Fotos von 2020/01", "IMG_0007.jpg"))
sidecar(year + "IMG_0007.jpg.supplemental-metadata.json", "IMG_0007.jpg", 1577835000,
        to=into("Fotos von 2020/01", "IMG_0007.jpg.supplemental-metadata.json"))
# Album with umlaut; album metadata without capture time (stays in the album)
media(album + "IMG_0005.jpg", 1570000000, to=into("Geburtstag Jürgen/10", "IMG_0005.jpg"))
sidecar(album + "IMG_0005.jpg.supplemental-metadata.json", "IMG_0005.jpg", 1570000000,
        to=into("Geburtstag Jürgen/10", "IMG_0005.jpg.supplemental-metadata.json"))
part1[album + "metadata.json"] = json.dumps({"title": "Geburtstag Jürgen", "date": {"timestamp": "1570000000"}}).encode()
# Album spanning two years → year level
media(trip + "IMG_1001.jpg", 1577000000, to=into("Urlaub/2019/12", "IMG_1001.jpg"))
sidecar(trip + "IMG_1001.jpg.supplemental-metadata.json", "IMG_1001.jpg", 1577000000,
        to=into("Urlaub/2019/12", "IMG_1001.jpg.supplemental-metadata.json"))
media(trip + "IMG_1002.jpg", 1578000000, to=into("Urlaub/2020/01", "IMG_1002.jpg"))
sidecar(trip + "IMG_1002.jpg.supplemental-metadata.json", "IMG_1002.jpg", 1578000000,
        to=into("Urlaub/2020/01", "IMG_1002.jpg.supplemental-metadata.json"))
# Capture time in milliseconds instead of seconds: no usable date, both stay put
media(year + "IMG_0008.jpg")
sidecar(year + "IMG_0008.jpg.supplemental-metadata.json", "IMG_0008.jpg", 1556712000000)
# Sidecar without photo, photo without sidecar (both stay put)
sidecar(year + "VERLOREN.jpg.supplemental-metadata.json", "VERLOREN.jpg", 1500000000)
media(year + "OHNE_JSON.jpg")
# Sidecar in part 1, photo only in part 2
sidecar(year + "IMG_0006.jpg.supplemental-metadata.json", "IMG_0006.jpg", 1575000000)
moves2[year + "IMG_0006.jpg.supplemental-metadata.json"] = into("Fotos von 2019/11", "IMG_0006.jpg.supplemental-metadata.json")
part1["Takeout/archive_browser.html"] = b"<html></html>"

# Part 2: the photo for the sidecar from part 1, an edited version of an already sorted photo and
# the same album photo once more (stays put, its name is taken in the month folder)
media(year + "IMG_0006.jpg", 1575000000, part=part2, to=into("Fotos von 2019/11", "IMG_0006.jpg"))
media(year + "IMG_0002-bearbeitet.HEIC", 1556798400, part=part2, to=into("Fotos von 2019/05", "IMG_0002-bearbeitet.HEIC"))
part2[album + "IMG_0005.jpg"] = part1[album + "IMG_0005.jpg"]
part2[album + "IMG_0005.jpg.supplemental-metadata.json"] = part1[album + "IMG_0005.jpg.supplemental-metadata.json"]

def write(path, entries):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            info = zipfile.ZipInfo(name, ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)

def layout(*parts):
    """The whole photos folder from (entries, moves) per part: path (without "Takeout/") → SHA-256 and,
    for photos and videos, the capture time."""
    result = {}
    for entries, moves in parts:
        for name, data in entries.items():
            if name.endswith("archive_browser.html"):
                continue
            final = moves.get(name, name).removeprefix("Takeout/")
            assert final not in result, final
            result[final] = {"sha": hashlib.sha256(data).hexdigest(),
                             "ts": None if name.endswith(".json") else times.get(name)}
    return result

write(target, part1)
result = {"dated": expected, "undated": ["Google Fotos/Fotos von 2019/OHNE_JSON.jpg", "Google Fotos/Fotos von 2019/IMG_0008.jpg"],
          "absent": ["archive_browser.html", "Takeout"], "updated": len(expected), "unmatched": 2,
          "sorted1": layout((part1, moves1))}
if second:
    write(second, part2)
    result["sorted2"] = layout((part1, {**moves1, **moves2}), (part2, moves2))
with open(target + ".expected.json", "w") as handle:
    json.dump(result, handle, ensure_ascii=False, indent=1)
print(f"{len(part1)} Einträge, {len(expected)} mit Datum" + (f"; Teil 2: {len(part2)} Einträge" if second else ""))
