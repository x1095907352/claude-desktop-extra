# @patch-target: app.asar.contents/.vite/build/index.pre.js
# @patch-type: nim
#
# Windows build only (patches/windows/ is applied by
# scripts/windows/build-windows.sh, never by the Linux packages).
#
# Multi-profile on Windows: prefix js/windows_profiles_main.js after
# "use strict"; of index.pre.js - package.json's `main`, which reads
# CLAUDE_USER_DATA_DIR, sets userData and logs, and takes the single-instance
# lock BEFORE it requires index.js, so index.js (where the other patches
# inject) would be too late. It does the Linux launcher's job for a Start Menu shortcut
# that runs `claude.exe --profile=NAME`: points CLAUDE_USER_DATA_DIR (which
# upstream reads itself), CLAUDE_CONFIG_DIR and CLAUDE_PROFILE at the profile,
# and routes claude:// sign-in callbacks to the profile that opened the auth
# page. See the header of the JS file.
#
# Break risk: LOW - the "use strict"; anchor, plus upstream's
# CLAUDE_USER_DATA_DIR handler in index.pre.js, asserted below. To find it
# again: grep -ao 'process.env.CLAUDE_USER_DATA_DIR){.\{0,80\}' index.pre.js

import std/[os, strutils]
import regex

const PROFILES_JS = staticRead("../../js/windows_profiles_main.js")
const MARKER = "/*__CDB_WIN_PROFILES__*/"
# Upstream moves userData (and logs) to CLAUDE_USER_DATA_DIR when it is set:
# `if(...,process.env.CLAUDE_USER_DATA_DIR){let e=process.env.CLAUDE_USER_DATA_DIR;
# E.app.setPath("userData",e),...}`. The profile switch depends on it, so its
# absence fails the build. Groups 0 and 1 must be the same identifier.
let upstreamSiteRe =
  re2"""process\.env\.CLAUDE_USER_DATA_DIR\)\{let ([\w$]+)=process\.env\.CLAUDE_USER_DATA_DIR;[\w$]+\.app\.setPath\("userData",([\w$]+)\)"""

proc upstreamSites(s: string): int =
  for m in s.findAll(upstreamSiteRe):
    if s[m.group(0)] == s[m.group(1)]:
      inc result

const EXPECTED_PATCHES = 2 # A (upstream support asserted), B (injection)

proc apply*(input: string): string =
  result = input
  var patchesApplied = 0

  # A. Precondition: upstream still moves userData to CLAUDE_USER_DATA_DIR,
  # in this file, exactly once.
  let sites = upstreamSites(result)
  if sites == 1:
    echo "  [OK] upstream sets userData from CLAUDE_USER_DATA_DIR in index.pre.js (1 site)"
    inc patchesApplied
  else:
    echo "  [FAIL] expected 1 `if(process.env.CLAUDE_USER_DATA_DIR){let e=...;app.setPath(\"userData\",e)` " &
      "in index.pre.js, found " & $sites &
      " - the profile switch would not move userData; re-audit windows_profiles_main.js"

  # B. Injection. Idempotency: our marker present (positive end-state).
  if MARKER in result:
    echo "  [OK] Windows profiles module already present (idempotent)"
    inc patchesApplied
  else:
    if MARKER notin PROFILES_JS:
      echo "  [FAIL] windows_profiles_main.js lost its marker"
    else:
      let strictPrefix = "\"use strict\";"
      if result.startsWith(strictPrefix):
        result = strictPrefix & PROFILES_JS & result[strictPrefix.len .. ^1]
        echo "  [OK] Windows profiles module injected after \"use strict\""
      else:
        result = PROFILES_JS & result
        echo "  [OK] Windows profiles module prepended"
      if MARKER in result:
        inc patchesApplied
      else:
        echo "  [FAIL] Windows profiles module not present after injection"

  if patchesApplied < EXPECTED_PATCHES:
    echo "  [FAIL] Only " & $patchesApplied & "/" & $EXPECTED_PATCHES &
      " patches applied"
    quit(1)

when isMainModule:
  if paramCount() != 1:
    echo "Usage: add_windows_profiles <path_to_index.pre.js>"
    quit(1)
  let filePath = paramStr(1)
  echo "=== Patch: add_windows_profiles ==="
  echo "  Target: " & filePath
  if not fileExists(filePath):
    echo "  [FAIL] File not found: " & filePath
    quit(1)
  let input = readFile(filePath)
  let output = apply(input)
  if output != input:
    writeFile(filePath, output)
    echo "  [PASS] Windows profiles installed"
  else:
    echo "  [OK] Already applied (no changes needed)"
