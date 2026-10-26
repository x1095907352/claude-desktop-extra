#!/usr/bin/env node
/*
 * test-windows-profiles.mjs - js/windows_profiles_main.js, the Windows
 * build's profile switch (patches/windows/add_windows_profiles.nim).
 *
 * Runs the real module with electron shimmed, process.platform "win32", a
 * temporary %APPDATA% / %LOCALAPPDATA%, and the argv a Start Menu shortcut or
 * a claude:// callback would give it. Path semantics are the host's; what is
 * asserted is which profile is chosen and where it points.
 */
import { readFileSync, mkdtempSync, writeFileSync, rmSync, existsSync, mkdirSync, utimesSync, readdirSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import Module from "node:module";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const SRC = readFileSync(join(ROOT, "js/windows_profiles_main.js"), "utf8");
let pass = 0, fail = 0;
const ok = (c, n) => { if (c) { pass++; console.log("  ok   " + n); }
  else { fail++; console.log("  FAIL " + n); } };

const base = mkdtempSync(join(tmpdir(), "cdb-winprof-"));
const APPDATA = join(base, "Roaming");
const LOCAL = join(base, "Local");
const MARKERS = join(LOCAL, "claude-desktop-extra");
mkdirSync(APPDATA, { recursive: true });
mkdirSync(LOCAL, { recursive: true });

function run(argv, env, platform) {
  const paths = { appData: APPDATA, userData: join(APPDATA, "Claude") };
  const calls = { setPath: [], exit: [], errorBox: [], opened: [] };
  const electron = {
    app: {
      getPath: (n) => paths[n],
      setPath: (n, v) => { calls.setPath.push([n, v]); paths[n] = v; },
      exit: (c) => { calls.exit.push(c); }
    },
    dialog: { showErrorBox: (t, m) => { calls.errorBox.push(m); } },
    shell: { openExternal: (url) => { calls.opened.push(url); return Promise.resolve(); } }
  };
  const proc = { platform: platform || "win32", argv: ["C:\\Claude\\claude.exe"].concat(argv),
    env: Object.assign({ LOCALAPPDATA: LOCAL }, env || {}) };
  const sandbox = { require: (m) => (m === "electron" ? electron : Module.createRequire(import.meta.url)(m)),
    process: proc, console, Date, Math, String, JSON };
  sandbox.globalThis = sandbox;
  vm.runInNewContext(SRC, vm.createContext(sandbox));
  return { env: proc.env, paths, calls, electron, g: sandbox };
}

function marker(who, ageMs) {
  mkdirSync(MARKERS, { recursive: true });
  const p = join(MARKERS, "pending-auth-" + who);
  writeFileSync(p, String(Date.now() - ageMs));
  const t = (Date.now() - ageMs) / 1000;
  utimesSync(p, t, t);
  return p;
}
function clearMarkers() { rmSync(MARKERS, { recursive: true, force: true }); }

// --- the default profile is the official app's ------------------------------
{
  const r = run([]);
  ok(!("CLAUDE_USER_DATA_DIR" in r.env) && !("CLAUDE_PROFILE" in r.env) && !("CLAUDE_CONFIG_DIR" in r.env),
     "no profile: nothing set, the app runs as Anthropic ships it");
  ok(r.calls.setPath.length === 0, "no profile: userData untouched");
  ok(r.g.__cdbWinProfiles.profile === "default", "no profile: reported as default");
  ok(typeof r.g.__cdbDiag === "function", "__cdbDiag is defined for the other modules");
  const r2 = run(["--profile=default"]);
  ok(!("CLAUDE_USER_DATA_DIR" in r2.env) && r2.calls.setPath.length === 0, "--profile=default is the default profile");
}

// --- a named profile ---------------------------------------------------------
for (const [label, argv, env] of [
  ["--profile=work", ["--profile=work"], {}],
  ["--profile work", ["--profile", "work"], {}],
  ["CLAUDE_PROFILE=work", [], { CLAUDE_PROFILE: "work" }]
]) {
  const r = run(argv, env);
  const dir = join(APPDATA, "Claude-work");
  ok(r.env.CLAUDE_USER_DATA_DIR === dir, label + ": CLAUDE_USER_DATA_DIR is %APPDATA%\\Claude-work");
  ok(r.paths.userData === dir, label + ": userData is set before upstream's code runs");
  ok(r.env.CLAUDE_PROFILE === "work", label + ": CLAUDE_PROFILE for the window title and child processes");
  ok(r.env.CLAUDE_CONFIG_DIR === join(homedir(), ".claude-work"), label + ": Claude Code gets its own config dir");
  ok(r.g.__cdbWinProfiles.profile === "work", label + ": reported");
}
{
  const r = run(["--profile=work"], { CLAUDE_CONFIG_DIR: "D:\\cc", CLAUDE_USER_DATA_DIR: "D:\\ud" });
  ok(r.env.CLAUDE_CONFIG_DIR === "D:\\cc" && r.env.CLAUDE_USER_DATA_DIR === "D:\\ud" && r.paths.userData === "D:\\ud",
     "folders the user set themselves are kept");
  const logged = join(APPDATA, "Claude-work", "logs", "claude-patches.log");
  const r2 = run(["--profile=work"]);
  r2.g.__cdbDiag("hello");
  const text = existsSync(logged) ? readFileSync(logged, "utf8") : "";
  ok(/\[win-profiles\] profile 'work' \(requested\)/.test(text) && /hello/.test(text),
     "the log lands in the profile's own logs folder, early lines included");
}

// --- a bad name never falls back to the default account ----------------------
for (const bad of ["../x", "a b", "x".repeat(65)]) {
  const r = run(["--profile=" + bad]);
  ok(r.calls.exit[0] === 1 && r.calls.errorBox.length === 1 && !("CLAUDE_USER_DATA_DIR" in r.env),
     "invalid name " + JSON.stringify(bad.slice(0, 12)) + ": error box, exit 1, nothing set");
}

// --- sign-in callbacks --------------------------------------------------------
{
  clearMarkers();
  const url = "claude://login/callback?code=x";
  marker("work", 30 * 1000);
  const r = run([url]);
  ok(r.env.CLAUDE_PROFILE === "work" && r.env.CLAUDE_USER_DATA_DIR === join(APPDATA, "Claude-work"),
     "a callback with no profile goes to the profile that opened the sign-in page");
  ok(!existsSync(join(MARKERS, "pending-auth-work")), "the marker is consumed");

  marker("work", 10 * 60 * 1000);
  const r2 = run([url]);
  ok(!("CLAUDE_PROFILE" in r2.env), "a marker older than 5 minutes is ignored");

  clearMarkers();
  marker("work", 60 * 1000);
  marker("default", 5 * 1000);
  const r3 = run([url]);
  ok(!("CLAUDE_PROFILE" in r3.env), "the newest marker wins: the default profile's own sign-in");
  ok(!existsSync(join(MARKERS, "pending-auth-default")) && existsSync(join(MARKERS, "pending-auth-work")),
     "only the winning marker is consumed");

  clearMarkers();
  marker("work", 5 * 1000);
  const r4 = run(["--profile=home", url]);
  ok(r4.env.CLAUDE_PROFILE === "home" && existsSync(join(MARKERS, "pending-auth-work")),
     "an explicit profile is never re-routed, and leaves the marker alone");

  clearMarkers();
  marker("not valid", 1000);
  const r6 = run([url]);
  ok(!("CLAUDE_PROFILE" in r6.env), "a marker whose name is not a valid profile is ignored");

  clearMarkers();
  marker("work", 5 * 1000);
  const r7 = run([]);
  ok(!("CLAUDE_PROFILE" in r7.env) && existsSync(join(MARKERS, "pending-auth-work")),
     "a plain start (no claude:// URL) is not re-routed");
}

// --- the marker writer --------------------------------------------------------
{
  clearMarkers();
  const r = run(["--profile=work"]);
  r.electron.shell.openExternal("https://claude.ai/login?returnTo=x");
  ok(existsSync(join(MARKERS, "pending-auth-work")), "opening an auth URL writes this profile's marker");
  clearMarkers();
  r.electron.shell.openExternal("https://example.com/docs");
  ok(!existsSync(MARKERS) || readdirSync(MARKERS).length === 0, "an ordinary link writes nothing");
  ok(r.calls.opened.length === 2, "the browser is still opened both times");
  const d = run([]);
  d.electron.shell.openExternal("https://claude.ai/oauth/authorize?x=1");
  ok(existsSync(join(MARKERS, "pending-auth-default")), "the default profile writes the 'default' marker");
}

// --- Linux is untouched -------------------------------------------------------
{
  const r = run(["--profile=work"], {}, "linux");
  ok(!("CLAUDE_USER_DATA_DIR" in r.env) && r.calls.setPath.length === 0 && !r.g.__cdbWinProfiles,
     "linux: the module does nothing (the launcher owns profiles there)");
}

rmSync(base, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
