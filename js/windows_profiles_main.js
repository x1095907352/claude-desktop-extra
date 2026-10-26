/*
 * windows_profiles_main.js - multi-profile support for the Windows build.
 * Injected into .vite/build/index.pre.js by patches/windows/add_windows_profiles.nim,
 * which only the Windows build applies (scripts/windows/build-windows.sh).
 *
 * On Linux the shell launcher (scripts/claude-desktop-launcher.sh) picks the
 * profile, passes --user-data-dir and exports CLAUDE_PROFILE /
 * CLAUDE_CONFIG_DIR. Windows has no launcher: a Start Menu shortcut runs
 * claude.exe --profile=NAME directly, so the same job is done here, as the
 * FIRST code of index.pre.js (package.json's main): it reads
 * CLAUDE_USER_DATA_DIR and takes the single-instance lock before it requires
 * index.js, where the other patches inject.
 *
 *   1. PROFILE. --profile=NAME (or --profile NAME, or CLAUDE_PROFILE=NAME in
 *      the environment) selects a named profile. "default" or nothing is the
 *      default profile, which is left exactly as the official app runs it.
 *      A named profile sets:
 *        CLAUDE_USER_DATA_DIR = %APPDATA%\Claude-NAME  (read by upstream itself:
 *                               it moves userData and logs there, and skips
 *                               its own 3P / MSIX data-folder switching)
 *        CLAUDE_CONFIG_DIR    = %USERPROFILE%\.claude-NAME (Claude Code CLI)
 *        CLAUDE_PROFILE       = NAME (window title: fix_profile_window_title)
 *      userData is also set here, so nothing that reads it before upstream's
 *      own handler runs sees the default profile's folder.
 *      Electron's single-instance lock is keyed on userData, so each profile
 *      is its own instance.
 *
 *   2. SIGN-IN CALLBACKS. claude:// is registered to claude.exe with no
 *      profile argument, so an SSO callback always starts the default
 *      profile. Like fix_profile_url_routing.nim on Linux: a profile that
 *      opens an auth URL in the browser writes a timestamped marker under
 *      %LOCALAPPDATA%\claude-desktop-extra\; a process started with a
 *      claude:// URL and no explicit profile takes the newest marker
 *      (< 5 min) and becomes that profile before upstream asks for the
 *      instance lock. If that profile is running, the lock fails and
 *      Electron hands the URL to it (second-instance), as on Linux.
 *
 *   3. DIAGNOSTICS. Defines globalThis.__cdbDiag (the Linux build gets it
 *      from the Computer Use preamble, which the Windows build does not
 *      carry): <userData>\logs\claude-patches.log, rotated at 2 MiB.
 */
;/*__CDB_WIN_PROFILES__*/(function () {
  "use strict";
  if (typeof process === "undefined" || process.platform !== "win32") return;
  if (globalThis.__cdbWinProfiles) return;

  var _electron = require("electron");
  var _app = _electron.app;
  var _fs = require("fs");
  var _path = require("path");
  var _os = require("os");

  var NAME_RE = /^[A-Za-z0-9_-]{1,64}$/;
  var MARKER_PREFIX = "pending-auth-";
  var MARKER_MAX_AGE_MS = 5 * 60 * 1000;
  var AUTH_RE = /(?:^|[/?&#])(?:oauth|sso|auth|login|signin|callback|accounts)(?:[/?&#=]|$)/i;

  // --- diagnostics -----------------------------------------------------------
  var early = [];
  if (!globalThis.__cdbDiag) {
    globalThis.__cdbDiag = function (msg) {
      var s = String(msg);
      try {
        if (!globalThis.__cdbDiagDir) {
          globalThis.__cdbDiagDir = _path.join(_app.getPath("userData"), "logs");
          _fs.mkdirSync(globalThis.__cdbDiagDir, { recursive: true });
        }
        var f = _path.join(globalThis.__cdbDiagDir, "claude-patches.log");
        try { if (_fs.statSync(f).size > 2097152) _fs.renameSync(f, f + ".old"); } catch (e) {}
        _fs.appendFileSync(f, new Date().toISOString() + " " + s + "\n");
      } catch (e) {}
    };
  }
  // Lines from before userData is final are held and written once it is.
  function log(m) { early.push("[win-profiles] " + m); }
  function flush() {
    var lines = early;
    early = null;
    log = function (m) { globalThis.__cdbDiag("[win-profiles] " + m); };
    lines.forEach(function (l) { globalThis.__cdbDiag(l); });
  }

  // --- 1. which profile -------------------------------------------------------
  // [name, explicit]: explicit when the command line or the environment named
  // one ("default" included), so a callback is never re-routed away from it.
  function requestedProfile(argv) {
    for (var i = 1; i < argv.length; i++) {
      var a = String(argv[i]);
      if (a.indexOf("--profile=") === 0) return [a.slice(10), true];
      if (a === "--profile" && i + 1 < argv.length) return [String(argv[i + 1]), true];
    }
    var env = process.env.CLAUDE_PROFILE;
    if (typeof env === "string" && env !== "") return [env, true];
    return ["", false];
  }

  function markerDir() {
    var base = process.env.LOCALAPPDATA || _path.join(_os.homedir(), "AppData", "Local");
    return _path.join(base, "claude-desktop-extra");
  }

  function applyProfile(name, why) {
    var dir = _path.join(_app.getPath("appData"), "Claude-" + name);
    if (!process.env.CLAUDE_USER_DATA_DIR) process.env.CLAUDE_USER_DATA_DIR = dir;
    else dir = process.env.CLAUDE_USER_DATA_DIR;
    try { _app.setPath("userData", dir); } catch (e) {}
    process.env.CLAUDE_PROFILE = name;
    if (!process.env.CLAUDE_CONFIG_DIR) {
      process.env.CLAUDE_CONFIG_DIR = _path.join(_os.homedir(), ".claude-" + name);
    }
    log("profile '" + name + "' (" + why + "): userData " + dir + ", Claude Code config " + process.env.CLAUDE_CONFIG_DIR);
  }

  // --- 2. route a sign-in callback to the profile that asked for it ----------
  // The newest fresh marker, consumed. null when there is none.
  function takeNewestMarker() {
    var dir = markerDir();
    var best = null;
    var names = [];
    try { names = _fs.readdirSync(dir); } catch (e) { return null; }
    names.forEach(function (n) {
      if (n.indexOf(MARKER_PREFIX) !== 0) return;
      var who = n.slice(MARKER_PREFIX.length);
      if (who !== "default" && !NAME_RE.test(who)) return;
      var p = _path.join(dir, n);
      var t;
      try { t = _fs.statSync(p).mtimeMs; } catch (e) { return; }
      if (Date.now() - t > MARKER_MAX_AGE_MS) return;
      if (!best || t > best.t) best = { who: who, p: p, t: t };
    });
    if (best) { try { _fs.unlinkSync(best.p); } catch (e) {} }
    return best;
  }

  function hasClaudeUrl(argv) {
    for (var i = 1; i < argv.length; i++) {
      if (/^claude:\/\//i.test(String(argv[i]))) return true;
    }
    return false;
  }

  var req = requestedProfile(process.argv);
  var name = req[0];
  var explicit = req[1];
  if (name === "default") name = "";
  if (name && !NAME_RE.test(name)) {
    // Never fall back to the default profile: that would sign a work
    // shortcut into the personal account.
    try {
      _electron.dialog.showErrorBox("Claude",
        "Invalid profile name \"" + name + "\". Profile names use letters, digits, '-' and '_' only.");
    } catch (e) {}
    _app.exit(1);
    return;
  }
  if (name) {
    applyProfile(name, "requested");
  } else if (!explicit && hasClaudeUrl(process.argv)) {
    var m = takeNewestMarker();
    if (m && m.who !== "default") {
      name = m.who;
      applyProfile(name, "sign-in callback, marker " + Math.round((Date.now() - m.t) / 1000) + "s old");
    } else if (m) {
      log("sign-in callback for the default profile");
    }
  }
  flush();

  // Mark auth URLs this profile opens in the browser. "default" for the
  // default profile, so its own callbacks beat a stale named-profile marker.
  try {
    var shell = _electron.shell;
    var origOpen = shell && shell.openExternal;
    if (typeof origOpen === "function") {
      var who = name || "default";
      shell.openExternal = function (url, opts) {
        try {
          if (typeof url === "string" && AUTH_RE.test(url)) {
            var dir = markerDir();
            _fs.mkdirSync(dir, { recursive: true });
            _fs.writeFileSync(_path.join(dir, MARKER_PREFIX + who), String(Date.now()));
            log("auth marker written for profile '" + who + "'");
          }
        } catch (e) { log("auth marker write failed: " + (e && e.message ? e.message : String(e))); }
        return origOpen.call(shell, url, opts);
      };
    }
  } catch (e) { log("shell.openExternal hook failed: " + (e && e.message ? e.message : String(e))); }

  globalThis.__cdbWinProfiles = { profile: name || "default" };
})();
