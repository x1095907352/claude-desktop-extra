#!/usr/bin/env python3
"""
asar header hashing and the Windows exe's embedded integrity record.

On Windows (unlike Linux) Electron enforces the EnableEmbeddedAsarIntegrityValidation
fuse: claude.exe carries a resource with the SHA-256 of app.asar's header, and
refuses to load an app.asar whose header hash differs. After repacking a patched
app.asar, the record has to name the new hash. It is a fixed-length hex string in
a JSON blob inside the PE resources, so it is rewritten in place: the PE layout is
unchanged, only Anthropic's Authenticode signature stops matching.

Usage:
  asar_integrity.py header-hash <app.asar>
  asar_integrity.py unpacked <app.asar>          # files flagged "unpacked", one per line
  asar_integrity.py fuses <claude.exe>
  asar_integrity.py fix-exe <claude.exe> <original app.asar> <patched app.asar>

fix-exe refuses unless the exe holds exactly one integrity record for
resources\\app.asar and that record names the ORIGINAL asar's hash: a positive
check that we read the format right before writing anything.
"""
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

# Electron's fuse wire: sentinel, version byte, count byte, one ASCII byte per
# fuse ('0' off, '1' on, 'r' removed). Order from @electron/fuses (FuseV1Options).
FUSE_SENTINEL = b"dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
FUSE_NAMES = [
    "RunAsNode",
    "EnableCookieEncryption",
    "EnableNodeOptionsEnvironmentVariable",
    "EnableNodeCliInspectArguments",
    "EnableEmbeddedAsarIntegrityValidation",
    "OnlyLoadAppFromAsar",
    "LoadBrowserProcessSpecificV8Snapshot",
    "GrantFileProtocolExtraPrivileges",
    "WasmTrapHandlers",
]

RECORD_RE = re.compile(
    rb'\{"file":"resources\\\\app\.asar","alg":"SHA256","value":"([0-9a-f]{64})"\}'
)


def read_header(asar: Path) -> bytes:
    """The raw header JSON string, as Electron hashes it."""
    with asar.open("rb") as f:
        head = f.read(16)
        if len(head) < 16:
            raise ValueError(f"{asar}: too short to be an asar archive")
        # Pickle(uint32 header_size) then Pickle(string header): the second
        # pickle is [payload size][string length][string bytes][padding].
        _, header_size, _, str_len = struct.unpack("<4I", head)
        if str_len > header_size:
            raise ValueError(f"{asar}: corrupt header sizes")
        data = f.read(str_len)
        if len(data) != str_len:
            raise ValueError(f"{asar}: truncated header")
        return data


def header_hash(asar: Path) -> str:
    return hashlib.sha256(read_header(asar)).hexdigest()


def unpacked_files(asar: Path) -> list[str]:
    tree = json.loads(read_header(asar))
    out = []

    def walk(node, prefix):
        for name, entry in node.get("files", {}).items():
            path = f"{prefix}/{name}" if prefix else name
            if "files" in entry:
                walk(entry, path)
            elif entry.get("unpacked"):
                out.append(path)

    walk(tree, "")
    return sorted(out)


def fuses(exe_bytes: bytes) -> dict[str, str]:
    i = exe_bytes.find(FUSE_SENTINEL)
    if i < 0 or exe_bytes.find(FUSE_SENTINEL, i + 1) >= 0:
        raise ValueError("fuse sentinel not found exactly once")
    count = exe_bytes[i + len(FUSE_SENTINEL) + 1]
    raw = exe_bytes[i + len(FUSE_SENTINEL) + 2 : i + len(FUSE_SENTINEL) + 2 + count]
    return {
        (FUSE_NAMES[n] if n < len(FUSE_NAMES) else f"fuse{n}"): chr(b)
        for n, b in enumerate(raw)
    }


def fix_exe(exe: Path, original: Path, patched: Path) -> None:
    data = exe.read_bytes()
    records = list(RECORD_RE.finditer(data))
    if len(records) != 1:
        raise SystemExit(
            f"[FAIL] {exe.name}: {len(records)} integrity records for "
            "resources\\app.asar, expected 1 - re-audit the exe's INTEGRITY resource"
        )
    old_value = records[0].group(1).decode()
    want_old = header_hash(original)
    if old_value != want_old:
        raise SystemExit(
            f"[FAIL] {exe.name}: integrity record names {old_value}, but the "
            f"original app.asar header hashes to {want_old} - the hash scheme "
            "changed; do not ship"
        )
    new_value = header_hash(patched)
    start, end = records[0].span(1)
    data = data[:start] + new_value.encode() + data[end:]
    exe.write_bytes(data)
    # Positive end-state check (re-read from disk).
    again = list(RECORD_RE.finditer(exe.read_bytes()))
    if len(again) != 1 or again[0].group(1).decode() != new_value:
        raise SystemExit(f"[FAIL] {exe.name}: integrity record not updated")
    print(f"  [OK] {exe.name}: asar integrity {old_value[:12]}... -> {new_value[:12]}...")


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "header-hash":
        print(header_hash(Path(argv[1])))
    elif len(argv) >= 2 and argv[0] == "unpacked":
        print("\n".join(unpacked_files(Path(argv[1]))))
    elif len(argv) >= 2 and argv[0] == "fuses":
        for k, v in fuses(Path(argv[1]).read_bytes()).items():
            print(f"{k}={v}")
    elif len(argv) >= 4 and argv[0] == "fix-exe":
        fix_exe(Path(argv[1]), Path(argv[2]), Path(argv[3]))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
