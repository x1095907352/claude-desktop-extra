# @patch-target: app.asar.contents/.vite/build/index.js
# @patch-type: nim
#
# Windows build only (patches/windows/ is applied by
# scripts/windows/build-windows.sh, never by the Linux packages).
#
# Left-click on the tray icon opens the main window.
#
# Upstream (v3.6556.2, the tray setup in an index chunk) builds the tray and
# registers every handler but one:
#
#   Y9=new a.Tray(a.nativeImage.createFromPath(X9??r)),Y9.setToolTip(...)
#   Y9.on("click",(()=>{nqa()||xJa()}))
#   Y9.on("right-click",(()=>{...Y9?.popUpContextMenu(Z9)}))
#
# `xJa()` is Quick Entry: it awaits upstream's wake scheduler and then shows
# and focuses `B`, the frameless quick-entry window. `nqa()` returns true when
# a native (Swift) quick entry handled the click first; that branch stays.
#
# We swap the Quick Entry call for `hJ()`, the handler upstream already attaches
# to the tray menu's "Show App" item: restore if minimised, else focus if
# visible, else show. It acts on the same `B`, which is the main window here.
#
# Quick Entry then has no entry point left on Windows - its only other trigger
# is the native Swift overlay (macOS). That is intended.
#
# Anchoring: the whole listener with its exact body, including the two call
# names, which are opaque minified identifiers that change every release. The
# replacement keeps whichever identifiers upstream used for the two functions
# so we never hardcode a name: group 1 is the guard (nqa), and we look up
# "Show App"'s handler separately because that is what hJ is.
#
# Break risk: MEDIUM - the click listener's body is a stable two-call shape but
# the names behind it move. To find it again:
#   grep -aoE '[a-zA-Z0-9_$]{1,3}\.on\("click",\(\(\)=>\{[^}]{1,40}\}\)\)' index.chunk-*.js
#
# Idempotency: the injected form is asserted present exactly once; its absence
# plus the upstream form's presence means "not applied yet".

import std/[os, strformat, strutils]
import regex

const MARKER = "/*__cdb_tray_click_win__*/"
const EXPECTED_PATCHES = 1

# The tray's left-click listener. Group 0 = the tray variable, group 1 = the
# native-quick-entry guard (nqa), group 2 = the quick entry opener (xJa).
let clickRe = re2(
  """([\w$]+)\.on\("click",\(\(\)=>\{([\w$]+)\(\)\|\|([\w$]+)\(\)\}\)\)"""
)

# The same listener once patched: same call names, plus our marker and a swap
# of the second call for the Show App handler. Group 1 = the tray variable.
let doneRe = re2(
  """([\w$]+)\.on\("click",\(\(\)=>\{([\w$]+)\(\)\|\|/\*__cdb_tray_click_win__\*/[\w$]+\(\)\}\)\)"""
)

# "Show App" in the tray menu: `{label:X().formatMessage({defaultMessage:"Show
# App",id:"..."}),click:hJ}`. Group 0 = the handler (hJ).
let showAppRe = re2(
  """\{label:[\w$]+\(\)\.formatMessage\(\{defaultMessage:["`]Show App["`],""" &
  """id:["`][^"`]+["`]\}\),click:([\w$]+)\}"""
)

proc allMatches(s: string, r: Regex2): seq[RegexMatch2] =
  for m in findAll(s, r):
    result.add m

proc apply*(input: string): string =
  result = input
  var patchesApplied = 0

  let done = allMatches(input, doneRe)
  if done.len == 1:
    echo "  [OK] tray left-click -> main window already present (idempotent)"
    return input
  if done.len > 1:
    raise newException(
      ValueError, &"fix_tray_left_click_windows: injection duplicated ({done.len})"
    )

  # The Show App handler stays a plain identifier upstream, but we only inject
  # a reference to it, so capture it rather than naming it.
  let showMs = allMatches(input, showAppRe)
  if showMs.len != 1:
    echo &"  [FAIL] tray \"Show App\" menu item: {showMs.len} matches (want 1)"
    raise newException(
      ValueError, "fix_tray_left_click_windows: Show App anchor moved"
    )
  let showFn = input[showMs[0].group(0)]

  let clickMs = allMatches(input, clickRe)
  if clickMs.len != 1:
    echo &"  [FAIL] tray left-click listener: {clickMs.len} matches (want 1)"
    raise newException(
      ValueError, "fix_tray_left_click_windows: click listener anchor moved"
    )

  let m = clickMs[0]
  let trayVar = input[m.group(0)]
  let guard = input[m.group(1)]
  let oldOpener = input[m.group(2)]

  # Replace only the opener call, keeping the native-quick-entry guard and the
  # listener shape. The marker sits right after the guard so doneRe can find
  # the patched form without depending on a name.
  let at = m.boundaries.a
  let replaced = trayVar & ".on(\"click\",(()=>{" & guard & "()||" & MARKER &
    showFn & "()}))"
  result = input[0 ..< at] & replaced & input[m.boundaries.b + 1 .. ^1]
  echo &"  [OK] tray left-click -> Show App (tray {trayVar}, show {showFn}, was {oldOpener})"
  inc patchesApplied

  # Positive end-state: the injected listener is present exactly once and the
  # old opener no longer runs on click.
  if allMatches(result, doneRe).len != 1:
    echo "  [FAIL] injected listener not found in output"
    raise newException(
      ValueError, "fix_tray_left_click_windows: end-state assertion failed"
    )

  if patchesApplied < EXPECTED_PATCHES:
    echo &"  [FAIL] Only {patchesApplied}/{EXPECTED_PATCHES} patches applied"
    raise newException(ValueError, "fix_tray_left_click_windows: incomplete")

when isMainModule:
  if paramCount() != 1:
    echo "Usage: fix_tray_left_click_windows <path_to_index.js>"
    quit(1)
  let file = paramStr(1)
  echo "=== Patch: fix_tray_left_click_windows ==="
  echo &"  Target: {file}"
  if not fileExists(file):
    echo &"  [FAIL] File not found: {file}"
    quit(1)
  let input = readFile(file)
  var output: string
  try:
    output = apply(input)
  except ValueError as e:
    echo "  [FAIL] " & e.msg
    quit(1)
  if output != input:
    writeFile(file, output)
    echo "  [PASS] tray left-click opens the main window"
  else:
    echo "  [PASS] No changes needed (already applied)"
