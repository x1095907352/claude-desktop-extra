#!/usr/bin/env bash
# Build the portable Windows 11 package of claude-desktop-extra.
#
# Runs on Linux (CI or a dev box), like the other packages: downloads
# Anthropic's official Windows build (the Squirrel .nupkg the official
# installer fetches), verifies it against the RELEASES manifest, patches
# app.asar with the Windows patch set (apply_patches.py --windows, from a copy
# of the sources prepared by scripts/windows/prepare-sources.sh),
# repacks it, rewrites the asar integrity hash embedded in claude.exe, and
# zips the result with an installer script.
#
# Why the exe is touched: on Windows Electron enforces the
# EnableEmbeddedAsarIntegrityValidation fuse, so claude.exe refuses an
# app.asar whose header hash differs from the one it carries. The record is a
# fixed-length hex string, rewritten in place (scripts/windows/asar_integrity.py);
# Anthropic's code signature no longer matches the modified exe.
#
# Usage:
#   scripts/windows/build-windows.sh [--arch x64|arm64] [--version X.Y.Z]
#                                    [--nupkg FILE --sha1 HEX] [--out DIR]
#
# Needs: curl, unzip, zip, python3, node >= 24 (the bundle uses `await using`),
# nim + the regex package (to compile the patches), and asar
# (npm i -g @electron/asar; otherwise npx fetches @electron/asar@3.4.1).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PKG_DIR="$REPO_DIR/packaging/windows"
BASE_URL="https://downloads.claude.ai/releases/win32"

ARCH="x64"
VERSION=""
NUPKG=""
SHA1=""
OUT_DIR="$REPO_DIR/dist"

log() { echo "[build-windows] $*"; }
die() { echo "[build-windows] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?}"; shift 2 ;;
        --arch=*) ARCH="${1#*=}"; shift ;;
        --version) VERSION="${2:?}"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --nupkg) NUPKG="${2:?}"; shift 2 ;;
        --nupkg=*) NUPKG="${1#*=}"; shift ;;
        --sha1) SHA1="${2:?}"; shift 2 ;;
        --sha1=*) SHA1="${1#*=}"; shift ;;
        --out) OUT_DIR="${2:?}"; shift 2 ;;
        --out=*) OUT_DIR="${1#*=}"; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "$ARCH" in x64|arm64) ;; *) die "--arch must be x64 or arm64" ;; esac

for dep in curl unzip zip python3 node make nim git; do
    command -v "$dep" >/dev/null || die "$dep is required"
done
node -e 'new Function("async function f(){await using x=null}")' 2>/dev/null ||
    die "node $(node --version) cannot parse the bundle (it uses \`await using\`): Node 24 or newer is needed"
if command -v asar >/dev/null; then
    ASAR=(asar)
else
    ASAR=(npx --yes @electron/asar@3.4.1)
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cdb-windows.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. The official package, verified
# ---------------------------------------------------------------------------
# RELEASES lines: "<SHA1> AnthropicClaude-<version>-full.nupkg <size>".
if [ -n "$NUPKG" ]; then
    [ -f "$NUPKG" ] || die "no such file: $NUPKG"
    [ -n "$SHA1" ] || die "--nupkg needs --sha1 (from the RELEASES file it was listed in)"
    if [ -z "$VERSION" ]; then
        VERSION="$(basename "$NUPKG" | sed -n 's/^AnthropicClaude-\(.*\)-full\.nupkg$/\1/p')"
        [ -n "$VERSION" ] || die "cannot read the version from $(basename "$NUPKG"); pass --version"
    fi
    cp "$NUPKG" "$WORK/claude.nupkg"
else
    log "Reading $BASE_URL/$ARCH/RELEASES"
    curl -fsSL --retry 3 -o "$WORK/RELEASES" "$BASE_URL/$ARCH/RELEASES"
    # The file starts with a UTF-8 BOM and uses CRLF.
    sed -i '1s/^\xEF\xBB\xBF//; s/\r$//' "$WORK/RELEASES"
    if [ -z "$VERSION" ]; then
        VERSION="$(sed -n 's/^[0-9A-Fa-f]\{40\} AnthropicClaude-\(.*\)-full\.nupkg [0-9]*$/\1/p' "$WORK/RELEASES" |
            sort -V | tail -1)"
        [ -n "$VERSION" ] || die "no full package listed in RELEASES"
    fi
    line="$(grep -F " AnthropicClaude-$VERSION-full.nupkg " "$WORK/RELEASES" || true)"
    [ -n "$line" ] || die "version $VERSION is not in RELEASES (it lists the current release only); download it yourself and pass --nupkg FILE --sha1 HEX"
    read -r SHA1 _name SIZE <<< "$line"
    log "Downloading AnthropicClaude-$VERSION-full.nupkg ($ARCH, $((SIZE / 1048576)) MiB)"
    curl -fsSL --retry 3 -o "$WORK/claude.nupkg" "$BASE_URL/$ARCH/AnthropicClaude-$VERSION-full.nupkg"
    got_size="$(stat -c %s "$WORK/claude.nupkg")"
    [ "$got_size" = "$SIZE" ] || die "size mismatch: got $got_size, RELEASES says $SIZE"
fi
got_sha1="$(sha1sum "$WORK/claude.nupkg" | cut -d' ' -f1)"
[ "${got_sha1,,}" = "${SHA1,,}" ] || die "SHA1 mismatch: got $got_sha1, expected $SHA1"
log "Verified SHA1 $got_sha1 (version $VERSION)"

# ---------------------------------------------------------------------------
# 2. Unpack the app and its asar
# ---------------------------------------------------------------------------
unzip -q "$WORK/claude.nupkg" 'lib/net45/*' -d "$WORK/nupkg"
APP_TREE="$WORK/nupkg/lib/net45"
RES="$APP_TREE/resources"
[ -f "$APP_TREE/claude.exe" ] && [ -f "$RES/app.asar" ] || die "not a Claude Desktop package: claude.exe or resources/app.asar missing"
cp "$RES/app.asar" "$WORK/original.asar"

log "Fuses: $(python3 -I "$SCRIPT_DIR/asar_integrity.py" fuses "$APP_TREE/claude.exe" | tr '\n' ' ')"
python3 -I "$SCRIPT_DIR/asar_integrity.py" unpacked "$WORK/original.asar" > "$WORK/unpacked.before"

mkdir -p "$WORK/app"
( cd "$RES" && "${ASAR[@]}" extract app.asar "$WORK/app/app.asar.contents" )

# ---------------------------------------------------------------------------
# 3. Patch
# ---------------------------------------------------------------------------
# The Windows build's sources: a copy of this repo (see prepare-sources.sh).
SRC="$WORK/src"
"$SCRIPT_DIR/prepare-sources.sh" "$SRC"
log "Compiling patches"
make -C "$SRC/patches" -j"$(nproc)" >/dev/null
log "Applying the Windows patch set"
python3 "$SRC/scripts/apply_patches.py" --windows "$SRC/patches" "$WORK/app"

log "Validating JavaScript syntax"
bad=0
for js in "$WORK/app/app.asar.contents/.vite/build/"*.js; do
    node --check "$js" 2>/dev/null || { echo "  syntax error: $(basename "$js")" >&2; bad=1; }
done
[ "$bad" = 0 ] || die "patched JavaScript does not parse"

# The V8 bytecode cache covers the files we patched: V8 would reject it and
# recompile anyway (see build-patched-tarball.sh).
rm -rf "$WORK/app/app.asar.contents/compile-cache"

# ---------------------------------------------------------------------------
# 4. Repack and re-sign the integrity record
# ---------------------------------------------------------------------------
log "Repacking app.asar"
( cd "$WORK/app" && "${ASAR[@]}" pack app.asar.contents app.asar --unpack "{**/*.node,**/*.dll,**/*.exe}" )
python3 -I "$SCRIPT_DIR/asar_integrity.py" unpacked "$WORK/app/app.asar" > "$WORK/unpacked.after"
diff -u "$WORK/unpacked.before" "$WORK/unpacked.after" >&2 ||
    die "the repacked asar unpacks a different set of files than the official one"
# Electron also checks every file it reads from the archive against its block
# hashes, so each file entry must carry them.
node -e '
  const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  let n = 0, missing = 0;
  (function walk(d) { for (const e of Object.values(d.files || {})) {
    if (e.files) walk(e); else if (!e.unpacked && !e.link) { n++; if (!e.integrity || !e.integrity.hash) missing++; } } })(h);
  if (!n || missing) { console.error("integrity blocks missing on " + missing + " of " + n + " files"); process.exit(1); }
' <(python3 -I -c 'import sys,struct;f=open(sys.argv[1],"rb");_,_,_,n=struct.unpack("<4I",f.read(16));sys.stdout.write(f.read(n).decode())' "$WORK/app/app.asar") ||
    die "the repacked asar has no per-file integrity"

rm -rf "$RES/app.asar" "$RES/app.asar.unpacked"
mv "$WORK/app/app.asar" "$RES/app.asar"
mv "$WORK/app/app.asar.unpacked" "$RES/app.asar.unpacked"
python3 -I "$SCRIPT_DIR/asar_integrity.py" fix-exe "$APP_TREE/claude.exe" "$WORK/original.asar" "$RES/app.asar"

# The Squirrel updater and its shortcut stub only work inside Squirrel's own
# install layout; this build is portable.
rm -f "$APP_TREE/squirrel.exe" "$APP_TREE/claude_ExecutionStub.exe"

# ---------------------------------------------------------------------------
# 5. Package
# ---------------------------------------------------------------------------
NAME="claude-desktop-extra-$VERSION-windows-$ARCH"
STAGE="$WORK/$NAME"
mkdir -p "$STAGE"
mv "$APP_TREE" "$STAGE/app"
cp "$PKG_DIR/Install-ClaudeExtra.ps1" "$PKG_DIR/Install.cmd" "$STAGE/"
sed 's/$/\r/' "$PKG_DIR/README-Windows.txt" > "$STAGE/README-Windows.txt"
{
    echo "claude-desktop-extra Windows build"
    echo "Upstream Claude Desktop: $VERSION ($ARCH)"
    echo "Upstream package SHA1:   $got_sha1"
    echo "Source commit:           $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} | sed 's/$/\r/' > "$STAGE/VERSION.txt"

mkdir -p "$OUT_DIR"
# Absolute: zip runs from inside $WORK below.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
ZIP="$OUT_DIR/$NAME.zip"
rm -f "$ZIP"
( cd "$WORK" && zip -qr -X "$ZIP" "$NAME" )
( cd "$OUT_DIR" && sha256sum "$NAME.zip" > "$NAME.zip.sha256" )
log "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
