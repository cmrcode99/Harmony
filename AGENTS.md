# Working on Harmony

## Helping a user install or configure Harmony

Read [sharing/AGENT_SETUP.md](sharing/AGENT_SETUP.md) first. It is the common guide for source checkouts and prebuilt packages. Handle routine computer steps yourself, explain the user's manual actions one at a time, and finish Mac setup before offering optional phone setup. Do not ask for credentials in chat or start a focus session unexpectedly.

## Changes and checks

- See CONTRIBUTING.md for the code map. Keep lifecycle, menu, overlay, and player changes in their respective files; preserve timer, password, and recovery behavior.
- Run `make check` after code changes. Use `./build.sh --stage-only /tmp/Harmony.app` with a new destination to inspect a build without replacing or starting the installed app.
- Run the live UI smoke test only with focus sessions off. It uses isolated preferences and disabled enforcement. Device permissions and actual phone input still require deliberate manual testing.
- `make share` creates a local package and checksum in `dist/`; it does not publish them. Run the release checks described in docs/releases.md before distributing a package.

## Private data

- Settings live in `~/Library/Application Support/Harmony Focus/configuration.json`. `approvedPaths` and `approvedBundleIDs` must describe the same allowed apps. Edit only with Harmony off and preserve `unlockDigest`.
- Never commit local settings, phone vaults, passwords, signing credentials, or third-party video assets. Never print a recovery password or phone code into chat, logs, or issues.
- Do not change a password hash as an installation shortcut: the encrypted phone vault depends on the original password. See docs/local-data.md.
