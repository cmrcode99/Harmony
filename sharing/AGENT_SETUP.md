# Install Harmony

Run `Install Harmony.command`. It installs `~/Applications/Harmony.app`,
`~/.local/bin/harmony`, and a per-user recovery LaunchAgent, then opens setup.
The recipient chooses allowed apps and saves their own generated password.
Setup does not start focus mode. Existing active sessions must end before updating.

Help with Accessibility permission and verify `~/.local/bin/harmony help`.
Start focus mode when the recipient is ready; unapproved apps are force-quit.
Use `Setup iPhone.command` for the optional phone helper. The user enters their
existing Screen Time code and grants Screen Recording access.

Settings live in `~/Library/Application Support/Harmony Focus/`.
If editing `configuration.json` while the app is off, update `approvedPaths`
and `approvedBundleIDs` together and preserve `unlockDigest`. Keep this file,
passwords, and `phone-vault.json` private. Do not copy another person's settings.
