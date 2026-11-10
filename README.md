# Harmony

A native macOS focus app with a floating, offline video player, timed sessions, a menu-bar control, and an optional iPhone passcode helper. Requires macOS 13 or later. Builds locally for Apple Silicon or Intel with Apple's Xcode 26+ Command Line Tools (macOS SDK 26+) and Python 3; no package manager, account, or API key is needed.

## Setup

Building needs macOS SDK 26 or newer for the native menu integration. The built app targets macOS 13+. A prebuilt ZIP can be installed without development tools. [Apple lists supported build systems here](https://developer.apple.com/xcode/system-requirements/).

From a clone of this repository:

```sh
xcode-select --install   # once, if Apple's Command Line Tools are missing
./setup.sh --video /path/to/your-video.mp4
```

Use an MP4 that your Mac can play. If you already have local videos listed in `media/playlist.json`, just run `./setup.sh`. Missing playlist files are skipped; at least one video is required. Videos and the optional `assets/Harmony.icns` icon are local assets, excluded from Git. Bring media you have permission to use.

Setup compiles and installs `~/Applications/Harmony.app` and `~/.local/bin/harmony`, then opens configuration. Choose the apps you want available and save your generated recovery password. Each installation has its own settings and password; nothing personal is built into the source. Setup exits without starting a focus session.

Enable Harmony in **System Settings → Privacy & Security → Accessibility** for window control. Screen Recording is needed only for the optional phone helper. Builds are locally signed, not Apple-notarized; macOS may ask you to allow the app in Privacy & Security.

Useful setup options:

```sh
./setup.sh --check       # check tools and media without building or installing
./setup.sh --no-open     # install without opening configuration
~/.local/bin/harmony help
```

Add `export PATH="$HOME/.local/bin:$PATH"` to your shell configuration if you want to run `harmony` by name. An agent can use the full path immediately. See [AGENTS.md](AGENTS.md) for the short agent setup guide.

## Using Harmony

**While focus mode runs, apps outside your chosen list are force-quit. Save work before starting.** Finder and System Settings remain available. Approved apps are opened and their windows minimized once; cmux stays unminimized. Harmony does not filter websites or commands inside allowed apps.

| Command | Action |
| --- | --- |
| `harmony` | Start untimed focus mode. |
| `harmony 1` | Start a one-hour lock (whole hours: 1–5). |
| `harmony 0 45` | Start a 45-minute lock. |
| `harmony extend 2 30` | Set remaining time to 2 hours 30 minutes from now; never shorten. |
| `harmony hide` / `harmony unhide` | Hide or reveal the video without changing the session. |
| `harmony exit` | Exit untimed mode. Timed sessions use the eye menu and recovery password. |
| `harmony setup` | Open configuration while the app is off. |
| `harmony phone` | Enter the saved iPhone Screen Time code after password verification. |

Durations range from one minute to five hours. Start commands leave an existing session alone. Sleep counts toward the deadline; unfinished timed sessions recover after login or a crash. A recovery LaunchAgent runs only for unfinished sessions. This is a personal focus aid, not an administrator-enforced lock.

Click the video to pause/resume. Hover for sound, seeking, and Skip. The eye menu controls visibility, size, movement, sound, and exit. Hiding or pausing the video does not pause the focus timer. Edit `media/playlist.json` to choose local videos and their `startSeconds` trim offsets. `--video` uses zero trim for your supplied video.

## Optional iPhone helper

Configure Screen Time and iPhone Mirroring on your own devices first. While Harmony is off, run `sharing/Setup iPhone.command`, enter your Harmony recovery password, and enter your existing four-digit Screen Time code. The code is stored encrypted locally; Harmony does not change it on the phone. Enable Screen Recording for Harmony, open Mirroring at an empty Screen Time passcode prompt, and use `harmony phone`.

The helper checks the screen before each digit and stops on uncertainty. See [Apple's iPhone Mirroring setup](https://support.apple.com/120421) for device requirements. Reconfigure the helper after changing your phone code or Harmony password.

## Development and sharing

```sh
make check                                     # tests and whole-app typecheck
./build.sh --stage-only /tmp/Harmony.app        # signed build; no install or launch
make share                                     # local ZIP and checksum in dist/
python3 tools/check-release.py .               # check for private files and home paths
```

`build.sh` installs without starting focus mode. `HARMONY_ARCH=arm64` or `x86_64` selects a build architecture; it defaults to the current Mac. `HARMONY_SIGN_IDENTITY` optionally selects an existing signing identity; otherwise signing is ad hoc. No signing keychain is created. The ZIP is built from the same source and per-user setup as the local app. Its installer is for the architecture used to build it.

The repository includes a macOS GitHub Actions workflow. With the app off, `python3 tests/run-ui-smoke.py` also checks real AppKit/WebKit startup using separate preferences and disabled enforcement. Add `--minute-timer` for timer startup or `--playlist-smoke` when all four local playlist videos are available. Native phone delivery and macOS permission dialogs still need testing on your device.

Local settings live in `~/Library/Application Support/Harmony Focus/`; preferences use `local.harmony.focus`; recovery uses `~/Library/LaunchAgents/local.harmony.focus.supervisor.plist`. Keep those settings and signing credentials out of Git. The app never uploads them.
