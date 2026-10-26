# Windows 11 (experimental)

A portable Windows build of Anthropic's official Claude Desktop with two of this project's extras:

- **[Custom models](custom-models.md)**: models from other providers in the Code tab's picker, set up in Settings → Extra → Models.
- **Profiles**: several separate Claude instances side by side, each with its own sign-in, settings and Claude Code configuration.

Everything else is Anthropic's Windows app as shipped. The Linux-only extras (Computer Use bridges, themes, Quick Entry socket, the other community features) are not part of this build.

## Install

1. Download `claude-desktop-extra-<version>-windows-x64.zip` (or `-arm64`) from a `windows-v<version>` release, or from the artifacts of a **Build Windows** workflow run.
2. Unzip it and double-click **Install.cmd**. It copies the app to `%LOCALAPPDATA%\Programs\Claude Desktop Extra` and adds **Claude (Extra)** to the Start Menu. No administrator rights are needed.
3. The first start may show "Windows protected your PC": click **More info → Run anyway**. Patching the app invalidates Anthropic's code signature (see [How it is built](#how-it-is-built)).

To update, install the next zip the same way; data and sign-in are kept. `Install.cmd -Uninstall` removes the app and its shortcuts and keeps the data.

**With the official app installed too:** the default profile uses the same data folder (`%APPDATA%\Claude`), so you stay signed in, but only one of the two runs at a time - quit the official app first. Sign-in links (`claude://`) may open either app; quit the one you are not signing in to.

## Profiles

```bat
Install.cmd -Profile work            :: adds "Claude (work)" to the Start Menu
Install.cmd -Profile work -Desktop   :: and to the desktop
Install.cmd -RemoveProfile work      :: removes the shortcut, keeps the data
```

A shortcut runs `claude.exe --profile=work`; `CLAUDE_PROFILE=work` in the environment does the same.

| | Default profile | Profile `work` |
|---|---|---|
| App data (sign-in, settings, logs, `claude-desktop-extra.json`) | `%APPDATA%\Claude` | `%APPDATA%\Claude-work` |
| Claude Code configuration | `%USERPROFILE%\.claude` | `%USERPROFILE%\.claude-work` |
| Window title | `Claude` | `Claude (work)` |

Names use letters, digits, `-` and `_`; an invalid name shows an error instead of starting the default profile. Each profile is its own instance (Electron's single-instance lock is per data folder).

**Signing in.** `claude://` callbacks always start `claude.exe` without a profile. As on Linux, a profile that opens a sign-in page in the browser leaves a timestamped marker in `%LOCALAPPDATA%\claude-desktop-extra\`; a callback that arrives within 5 minutes goes to the profile with the newest marker. Start one sign-in at a time.

Known limits: **Start at login** starts the default profile; all profiles share one taskbar group (tell them apart by the title); a named profile ignores the 3P (`Claude-3p`) data folder switch, because it pins its own folder.

## Custom models

Identical to Linux ([custom-models.md](custom-models.md)), with the Windows paths above. The Settings → Extra area shows the **Models** panel only on Windows.

The model routing loads a preload into the Claude Code CLI through `BUN_OPTIONS`, which cannot carry a space. When the user folder has one (`C:\Users\John Smith`), the preload is passed through the profile folder's 8.3 short name (`C:\Users\JOHNSM~1\...`). On a drive with short names turned off, sessions are not routed and `claude-patches.log` says so; setting `CLAUDE_USER_DATA_DIR` to a folder without spaces is the workaround.

## Logs

`%APPDATA%\Claude\logs\` (or `%APPDATA%\Claude-<name>\logs\`): `claude-patches.log` holds our lines (`[win-profiles]`, `[custom-models]`, `[ExtraSettings]`), `custom-models.log` the routed requests, `main.log` the app's own log.

## How it is built

`scripts/windows/build-windows.sh` runs on Linux, like the other packages:

1. Reads `https://downloads.claude.ai/releases/win32/<arch>/RELEASES` (what the official installer reads), downloads the full Squirrel `.nupkg` and checks its size and SHA1 against it.
2. Prepares the sources: `scripts/windows/prepare-sources.sh` copies the repo's tracked files to a temp folder, so a build never leaves compiled patch binaries or `.nimcache` in the working tree.
3. Extracts `app.asar` and applies the Windows patch set from that copy: `apply_patches.py --windows` runs the shared patches listed in `WINDOWS_PATCH_SET` (custom models, the Extra settings page and its bridge, the profile window title), then everything in `patches/windows/`. The strictness rules are the same as on Linux: a patch that does not match fails the build.
4. Repacks `app.asar` (same unpacked file set as Anthropic's, checked) and rewrites the asar integrity hash in `claude.exe`. On Windows, Electron's `EnableEmbeddedAsarIntegrityValidation` fuse is enforced, unlike on Linux: the exe refuses an archive whose header hash differs from the one it carries. `scripts/windows/asar_integrity.py` replaces that fixed-length hash in place, after checking that the old value matches the original archive. The exe is otherwise byte-identical; its Authenticode signature no longer verifies.
5. Drops the Squirrel updater (the build is portable and does not auto-update) and zips `app\` with `Install.cmd`, `Install-ClaudeExtra.ps1`, `README-Windows.txt` and `VERSION.txt`.

```bash
scripts/windows/build-windows.sh                    # current release, x64
scripts/windows/build-windows.sh --arch arm64
scripts/windows/build-windows.sh --nupkg AnthropicClaude-3.6556.2-full.nupkg --sha1 <SHA1>
```

Needs Node 24+, Nim with the `regex` package, `asar` (or `npx`), `curl`, `unzip` and `zip`. The **Build Windows** workflow (`.github/workflows/build-windows.yml`) builds both architectures, boots the x64 build on a Windows runner with a test profile (checking that the patched bundle loads and logs its startup lines), and publishes a release when run with `publish`.

The Windows version stream is not the Linux one (Windows usually ships first), so a Windows build can meet a bundle the patches were not yet re-fitted to; the build then fails like a Linux build would.

## Staying in sync with upstream

The Windows build lives in the same tree as the Linux packages, so there is no patch layer to keep in sync: the Windows-only edits are ordinary files (the `win32` gates in `js/custom_models_main.js` and `js/extra_settings_main.js`, the Models-only Settings nav in `js/extra_settings_page.js`, the custom models 8.3 short-path fallback, `apply_patches.py --windows`, the `patches/windows/` Makefile rule).

- **Linux builds ignore all of it.** `apply_patches.py` discovers only `linux/`, `core/` and `community/`, and its `EXPECTED_PATCH_COUNT` (61) stays as it was; `patches/windows/` is discovered only with `--windows`. The Windows edits in the shared JS files sit behind `process.platform` checks, so they never change Linux behavior.
- **Upstream sync is an ordinary merge.** A conflict in one of those win32-gated lines is a normal merge conflict, resolved in place.
- **Daily automation:** the **Upstream Sync** workflow (`.github/workflows/upstream-sync.yml`) runs every morning:
  1. syncs master with GitHub's "Sync fork";
  2. compares Anthropic's current Windows version with the newest `windows-v` release;
  3. when either moved, runs Build Windows with `publish`.

  A failed check publishes nothing. The failure is reported in an issue (when Issues are enabled on the repo, otherwise in the run summary; GitHub also emails failed scheduled runs), with a ready-to-paste prompt for fixing it with Claude. A later successful run closes that issue.
- **Workflow files:** syncing upstream commits that change `.github/workflows/` needs a token with the workflow permission. Add a fine-grained personal access token as the `SYNC_TOKEN` repository secret (this repository only; Contents and Workflows: read and write).
