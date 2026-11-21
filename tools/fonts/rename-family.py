"""Renames a font family inside a TrueType or OpenType file. Standard library only.

Used once to give the Source Serif 4 build of commit 52ed247 (then called "Ensemble Serif") its own
family name, "Ensemble Serif 4", so it can ship next to the Roboto Serif build that now has the old name.
Only the `name` table changes: every string has OLD replaced by NEW (with and without spaces), all other
tables are copied byte for byte, and the table checksums and `head.checkSumAdjustment` are recomputed.

    python3 tools/fonts/rename-family.py in.ttf out.ttf "Ensemble Serif" "Ensemble Serif 4"
    python3 tools/fonts/rename-family.py in.ttf          # lists the names, changes nothing
"""
import struct
import sys


def checksum(data: bytes) -> int:
    padded = data + b"\0" * (-len(data) % 4)
    return sum(struct.unpack(f">{len(padded) // 4}I", padded)) & 0xFFFFFFFF


def read_tables(font: bytes):
    version, count = struct.unpack(">4sH", font[:6])
    tables = []
    for i in range(count):
        tag, _, offset, length = struct.unpack(">4sIII", font[12 + 16 * i:28 + 16 * i])
        tables.append((tag, font[offset:offset + length]))
    return version, tables


def encoding(platform: int) -> str:
    return "mac_roman" if platform == 1 else "utf-16-be"


def read_names(table: bytes):
    fmt, count, storage = struct.unpack(">HHH", table[:6])
    if fmt != 0:
        raise SystemExit("name table format 1 is not handled")
    names = []
    for i in range(count):
        platform, enc, lang, name_id, length, offset = struct.unpack(">6H", table[6 + 12 * i:18 + 12 * i])
        raw = table[storage + offset:storage + offset + length]
        names.append((platform, enc, lang, name_id, raw.decode(encoding(platform))))
    return names


def write_names(names) -> bytes:
    records, strings, seen = b"", b"", {}
    for platform, enc, lang, name_id, text in names:
        raw = text.encode(encoding(platform))
        if raw not in seen:
            seen[raw] = len(strings)
            strings += raw
        records += struct.pack(">6H", platform, enc, lang, name_id, len(raw), seen[raw])
    return struct.pack(">HHH", 0, len(names), 6 + len(records)) + records + strings


def write_font(version: bytes, tables) -> bytes:
    count = len(tables)
    entry_selector = count.bit_length() - 1
    search_range = 16 << entry_selector
    header = struct.pack(">4sHHHH", version, count, search_range, entry_selector, count * 16 - search_range)
    offset = 12 + 16 * count
    directory, body = b"", b""
    for tag, data in tables:
        if tag == b"head":
            data = data[:8] + b"\0\0\0\0" + data[12:]
        directory += struct.pack(">4sIII", tag, checksum(data), offset, len(data))
        padded = data + b"\0" * (-len(data) % 4)
        body += padded
        offset += len(padded)
    font = bytearray(header + directory + body)
    adjustment = (0xB1B0AFBA - checksum(bytes(font))) & 0xFFFFFFFF
    head = next(struct.unpack(">I", directory[16 * i + 8:16 * i + 12])[0]
                for i, (tag, _) in enumerate(tables) if tag == b"head")
    font[head + 8:head + 12] = struct.pack(">I", adjustment)
    return bytes(font)


def main():
    if len(sys.argv) not in (2, 5):
        raise SystemExit(__doc__)
    source = open(sys.argv[1], "rb").read()
    version, tables = read_tables(source)
    names = read_names(dict(tables)[b"name"])
    if len(sys.argv) == 2:
        for platform, enc, lang, name_id, text in names:
            print(platform, enc, hex(lang), name_id, repr(text))
        return
    old, new = sys.argv[3], sys.argv[4]
    pairs = [(old.replace(" ", ""), new.replace(" ", "")), (old, new)]
    renamed = []
    for platform, enc, lang, name_id, text in names:
        for before, after in pairs:
            # Skip text that already has the new name, so a second run changes nothing.
            if after not in text:
                text = text.replace(before, after)
        renamed.append((platform, enc, lang, name_id, text))
    tables = [(tag, write_names(renamed) if tag == b"name" else data) for tag, data in tables if tag != b"DSIG"]
    open(sys.argv[2], "wb").write(write_font(version, tables))
    print(f"{sys.argv[2]}: {sum(a != b for a, b in zip(names, renamed))} of {len(names)} names changed")


if __name__ == "__main__":
    main()
