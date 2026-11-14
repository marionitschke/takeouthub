#!/usr/bin/env python3
"""Creates archives for the extraction safety tests in Tests/run.sh. No real photos.

  make_bad_archives.py corrupt <target.zip>             two good photos and one with a wrong CRC
  make_bad_archives.py links <target.zip> <outside>     symlinks (also to <outside>), an absolute path and a
                                                        read-only folder next to a good photo
  make_bad_archives.py slip <target.zip> <outside>      "..", a symlink to <outside> and a file through it
  make_bad_archives.py many <target.zip>                20000 small photos (time to quit mid-way)
"""
import stat
import sys
import zipfile

mode, target = sys.argv[1], sys.argv[2]
outside = sys.argv[3] if len(sys.argv) > 3 else ""
folder = "Takeout/Google Fotos/Fotos von 2019/"


def add(archive, name, data, kind=stat.S_IFREG | 0o644):
    info = zipfile.ZipInfo(name, (2026, 11, 1, 12, 0, 0))
    info.create_system = 3  # Unix, so the mode in external_attr counts
    info.external_attr = kind << 16
    archive.writestr(info, data)


with zipfile.ZipFile(target, "w", zipfile.ZIP_STORED) as archive:
    if mode == "corrupt":
        add(archive, folder + "A.jpg", b"\xff\xd8\xff" + b"A" * 4000)
        add(archive, folder + "B.jpg", b"\xff\xd8\xff" + bytes(range(256)) * 100)
        add(archive, folder + "C.jpg", b"\xff\xd8\xff" + b"C" * 4000)
    elif mode == "links":
        add(archive, folder + "OK.jpg", b"\xff\xd8\xff ok")
        add(archive, folder + "LINK.jpg", outside + "/geheim.jpg", stat.S_IFLNK | 0o777)
        add(archive, "Takeout/Google Fotos/Fotos von 2020", outside, stat.S_IFLNK | 0o777)
        add(archive, "/Takeout/Google Fotos/Absolut/ABS.jpg", b"\xff\xd8\xff abs")
        add(archive, "Takeout/Google Fotos/Nur lesen/", b"", stat.S_IFDIR | 0o555)
        add(archive, "Takeout/Google Fotos/Nur lesen/RO.jpg", b"\xff\xd8\xff ro")
    elif mode == "slip":
        add(archive, folder + "OK.jpg", b"\xff\xd8\xff ok")
        add(archive, "Takeout/../../../draussen.jpg", b"\xff\xd8\xff out")
        add(archive, "Takeout/Google Fotos/Tunnel", outside, stat.S_IFLNK | 0o777)
        add(archive, "Takeout/Google Fotos/Tunnel/durch.jpg", b"\xff\xd8\xff through")
    elif mode == "many":
        for number in range(20000):
            add(archive, f"{folder}IMG_{number:05d}.jpg", b"\xff\xd8\xff" + b"x" * 509)
    else:
        sys.exit(f"unknown mode {mode}")

if mode == "corrupt":
    data = bytearray(open(target, "rb").read())
    data[data.find(bytes(range(256)) * 2) + 3000] ^= 0xFF
    open(target, "wb").write(data)
