#!/usr/bin/env python3
"""Reassemble Nest backplate UART frames from an strace -xx -e read=FD -e write=FD log.

Frame: d5 aa 96 | cmd u16le | len u16le | payload | crc16-xmodem(cmd+len+payload) u16le
"""
import re
import sys
from collections import defaultdict

PREAMBLE = b"\xd5\xaa\x96"
CALL = re.compile(r"^\d+\s+(\d\d:\d\d:\d\d\.\d+) (?:(read|write)\(\d+, .*\)|<\.\.\. (read|write) resumed>.*) = (\d+)")
OTHER = re.compile(r"^\d+\s+\d\d:\d\d:\d\d\.\d+ ")
DUMP = re.compile(r"^ \| [0-9a-f]{5}  ")
HEXBYTE = re.compile(r"[0-9a-f]{2}")


def crc16_xmodem(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def streams(path):
    """Return {'read': [(time, bytes)], 'write': [...]} in log order."""
    out = {"read": [], "write": []}
    cur = None
    for line in open(path, errors="replace"):
        m = CALL.match(line)
        if m:
            cur = (m.group(1), m.group(2) or m.group(3))
            continue
        if OTHER.match(line):
            cur = None
            continue
        if DUMP.match(line) and cur:
            # hex area is a fixed 49-column field (16 bytes, extra space after the 8th)
            chunk = bytes.fromhex("".join(HEXBYTE.findall(line[10:59])))
            out[cur[1]].append((cur[0], chunk))
    return out


def frames(chunks):
    buf = b""
    stamps = []
    for t, c in chunks:
        buf += c
        stamps.extend([t] * len(c))
    i = 0
    while True:
        i = buf.find(PREAMBLE, i)
        if i < 0 or i + 7 > len(buf):
            return
        cmd = int.from_bytes(buf[i + 3:i + 5], "little")
        ln = int.from_bytes(buf[i + 5:i + 7], "little")
        end = i + 7 + ln + 2
        if end > len(buf):
            return
        body = buf[i + 3:i + 7 + ln]
        crc = int.from_bytes(buf[end - 2:end], "little")
        yield stamps[i], cmd, buf[i + 7:i + 7 + ln], crc == crc16_xmodem(body)
        i = end if crc == crc16_xmodem(body) else i + 1


def main(path):
    s = streams(path)
    for direction, label in (("write", "HEAD -> BACKPLATE"), ("read", "BACKPLATE -> HEAD")):
        by_cmd = defaultdict(list)
        bad = 0
        for t, cmd, payload, ok in frames(s[direction]):
            if ok:
                by_cmd[cmd].append((t, payload))
            else:
                bad += 1
        print(f"\n=== {label}: {sum(map(len, by_cmd.values()))} good frames, {bad} bad ===")
        for cmd in sorted(by_cmd):
            items = by_cmd[cmd]
            lens = sorted({len(p) for _, p in items})
            print(f"cmd 0x{cmd:04x}  x{len(items):<4} len={lens}  first {items[0][0]}  last {items[-1][0]}")
            shown = []
            for t, p in items:
                if p not in shown:
                    shown.append(p)
                if len(shown) >= 4:
                    break
            for p in shown:
                print(f"    {p.hex(' ')}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "bp_trace.log")
