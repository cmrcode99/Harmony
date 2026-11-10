# Working on Harmony

- Read README.md. Run `./setup.sh --check` to discover missing tools or media.
- Use `./setup.sh --video /absolute/path/to/video.mp4` for a fresh checkout, or `./setup.sh` with existing playlist media. Use `--no-open` for a noninteractive install.
- Setup installs locally and opens per-user configuration; it does not start focus restrictions. Help the user choose allowed apps and save their recovery password privately.
- Use `~/.local/bin/harmony help` without changing the user's shell configuration. Start focus mode when the user wants it: unapproved apps are force-quit.
- App settings: `~/Library/Application Support/Harmony Focus/configuration.json`. `approvedPaths` contains application paths; `approvedBundleIDs` contains the corresponding bundle identifiers. Keep both synchronized when changing the allowlist with the app off. Preserve the existing `unlockDigest`.
- Never put local settings, passwords, phone vaults, signing keys, or video assets in commits. Do not print the recovery password or phone code into chat.
- Run `make check` after code changes. Use `./build.sh --stage-only /tmp/Harmony.app` to review a build without replacing or starting an installed app.
- `make share` creates a signed ZIP plus checksum in `dist/`; it does not publish anything. Run `python3 tools/check-release.py .` before publishing source.
- Keep the session/recovery behavior intact when editing setup or renaming identifiers. Stop an active timed session through the app before replacing it.
