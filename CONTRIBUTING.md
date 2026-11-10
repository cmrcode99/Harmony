# Contributing to Harmony

Start with the [README](README.md), then open an issue or a focused pull request. Small, reviewable changes are easier to test on a utility that manages other apps.

## Code map

| File | Responsibility |
| --- | --- |
| `main.swift` | Process arguments, singleton ownership, and app entry point |
| `App.swift` | App lifecycle, focus enforcement, timed sessions, and recovery |
| `AppMenus.swift` | Application and menu-bar controls |
| `AppOverlay.swift`, `OverlayViews.swift` | Floating window, native controls, and input views |
| `AppPlayback.swift`, `player.html` | Native/player state bridge and local video playback |
| `LifecycleCore.swift` | Command validation, deadlines, interprocess replies, and instance lock |
| `Setup.swift` | Per-user configuration and private storage |
| `PhoneBridge.swift`, `PhonePrompt.swift` | Optional phone input and authentication prompts |
| `WindowPreparation.swift`, `WindowRedraw.swift` | Bounded window preparation and display recovery |
| `setup.sh`, `build.sh`, `sharing/` | Build and transactional install/update/uninstall |
| `tests/`, `tools/` | Regression checks, packaging, and release helpers |

Keep new application Swift files at the repository root so the build and test entry points discover them. Keep scripts and fixtures in their existing directories. The editor and line-ending defaults are in `.editorconfig` and `.gitattributes`.

## Validate a change

Run `make check` before opening a pull request. Tests cover CLI routing, deadline and recovery rules, configuration storage, phone recognition fixtures, player behavior, and installation failure paths. They use temporary data or mocked OS endpoints where appropriate.

For a signed build without installation:

```sh
./build.sh --stage-only /tmp/Harmony-review.app
```

Use a destination that does not exist. With focus sessions off and local video available, run `python3 tests/run-ui-smoke.py` for actual AppKit/WebKit startup. `--minute-timer` exercises cold timer startup; `--playlist-smoke` expects all four configured playlist files. These checks do not establish that every macOS permission flow or phone configuration works; record any manual device verification separately.

Render the settings screen with sample data, without starting a focus session:

```sh
make preview-settings
```

The PNG is written to `.build/settings-preview.png`.

## Pull requests

Explain the problem, the resulting behavior, and the checks you ran. Include a regression test for a behavioral fix when it can be tested reliably. Keep unrelated formatting and refactoring out of the change. For UI changes, add a screenshot made from the actual app using non-private media.

Preserve these behaviors unless the change explicitly proposes otherwise:

- Setup, update, and uninstall do not start a focus session.
- Focus startup prepares allowed windows once; allowed cmux stays visible, and activating an allowed app cancels its pending minimization.
- Settings pause untimed focus and resume it on close; timed sessions keep settings locked.
- Timed sessions cannot be shortened or bypassed through ordinary CLI exit.
- Hiding or pausing video leaves the session deadline intact.
- Phone input stops on an unverified screen or cancelled authorization.
- Failed installs preserve a recoverable app and local configuration.

Use [SECURITY.md](SECURITY.md) for vulnerabilities. Never include passwords, phone codes, local vaults, signing material, or private screenshots in a report. Video and icon contributions need clear permission to redistribute them. Keep original code contributions compatible with the project's [MIT license](LICENSE), and identify the license and source of any third-party material.
