Claude Desktop Extra for Windows 11
===================================

Anthropic's official Claude Desktop for Windows, patched by
claude-desktop-extra to add:

  * Custom models - models from other providers (DeepSeek, OpenRouter, a
    LiteLLM gateway, Anthropic's API on your API credit...) in the Code tab's
    model picker, next to the Claude models. Settings > Extra > Models.
  * Profiles - several separate Claude instances side by side, each with its
    own sign-in, settings and Claude Code configuration.

This is an unofficial build. It is not made or supported by Anthropic.


Install
-------

1. Unzip the download anywhere.
2. Double-click Install.cmd.
   It copies the app to %LOCALAPPDATA%\Programs\Claude Desktop Extra and adds
   "Claude (Extra)" to the Start Menu. No administrator rights are needed.

Windows may warn that the app is unrecognized ("Windows protected your PC"):
patching the app invalidates Anthropic's code signature. Click "More info",
then "Run anyway".

If the official Claude app is installed too, quit it before starting this one:
the default profile shares its data folder (%APPDATA%\Claude), so you stay
signed in, but only one of the two can run at a time.


Profiles
--------

  Install.cmd -Profile work          add "Claude (work)" to the Start Menu
  Install.cmd -Profile work -Desktop the same, plus a desktop shortcut
  Install.cmd -RemoveProfile work    remove that shortcut (its data stays)

Or start one directly:  claude.exe --profile=work

A profile named "work" keeps its data in %APPDATA%\Claude-work and its Claude
Code configuration in %USERPROFILE%\.claude-work. The window title shows the
profile name. Names use letters, digits, '-' and '_'.

Signing in to a profile: start the sign-in from that profile's window and
finish it within 5 minutes; the browser's callback is sent back to it.


Custom models
-------------

Settings > Extra > Models > Add a provider. Pick a preset or enter the base
URL, paste the API key, fetch or add models, turn the switch on and click
"Reload the Code tab". Full guide:
https://github.com/patrickjaja/claude-desktop-extra/blob/master/docs/custom-models.md

The settings live in claude-desktop-extra.json in the profile's folder
(%APPDATA%\Claude for the default profile).


Good to know
------------

  * No automatic updates. Download the next build and run Install.cmd again
    (your data and sign-in are kept).
  * "Start at login" in Claude's settings starts the default profile.
  * Logs: %APPDATA%\Claude\logs (claude-patches.log, custom-models.log), or
    %APPDATA%\Claude-<name>\logs for a profile.
  * Uninstall: Install.cmd -Uninstall (your data is kept).
