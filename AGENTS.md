# Working on Harmony

## Setup and local use

- Read README.md. Use `./setup.sh --check --video /absolute/path/to/video.mp4` for a read-only preflight, then `./setup.sh --video /absolute/path/to/video.mp4` to install. Existing playlist media also works with `./setup.sh`. `--no-open` skips the configuration window.
- Setup does not start focus restrictions. Help the user choose allowed apps and save their generated recovery password privately. Use `~/.local/bin/harmony help` without changing shell configuration.
- Starting focus mode force-quits unapproved apps. Only start when the user wants that behavior. End an active session through the app before updating or uninstalling it.
- `harmony uninstall` and `./uninstall.sh` preserve local settings. `--remove-data` is an explicit request to delete configuration and the encrypted vault.

## Changes and checks

- See CONTRIBUTING.md for the code map. Keep lifecycle, menu, overlay, and player changes in their respective files; preserve timer, password, and recovery behavior.
- Run `make check` after code changes. Use `./build.sh --stage-only /tmp/Harmony.app` with a new destination to inspect a build without replacing or starting the installed app.
- Run the live UI smoke test only with focus sessions off. It uses isolated preferences and disabled enforcement. Device permissions and actual phone input still require deliberate manual testing.
- `make share` creates a local package and checksum in `dist/`; it does not publish them. Run the release checks described in docs/releases.md before distributing a package.

## Private data

- Settings live in `~/Library/Application Support/Harmony Focus/configuration.json`. `approvedPaths` and `approvedBundleIDs` must describe the same allowed apps. Edit only with Harmony off and preserve `unlockDigest`.
- Never commit local settings, phone vaults, passwords, signing credentials, or third-party video assets. Never print a recovery password or phone code into chat, logs, or issues.
- Do not change a password hash as an installation shortcut: the encrypted phone vault depends on the original password. See docs/local-data.md.
