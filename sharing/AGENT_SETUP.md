# Help someone set up Harmony

This package is for the Mac architecture shown in its archive name. It includes the app, terminal command, and install/uninstall helpers. No developer tools or Python are required to install it.

1. Run `Install Harmony.command`. It installs `~/Applications/Harmony.app`, `~/.local/bin/harmony`, and the per-user recovery service, then opens setup. Existing active or unfinished timed sessions must end before updating.
2. Help the recipient choose allowed apps and save their generated recovery password privately. Setup itself does not start focus mode.
3. Help with **System Settings → Privacy & Security → Accessibility**. Verify `~/.local/bin/harmony help`. The installer leaves shell configuration alone; the full command path works immediately.
4. Start Harmony when the recipient is ready. It force-quits apps outside the allowed list, so save work first. Untimed mode exits with `harmony exit`; timed early exit uses the eye menu and recovery password.
5. For the optional phone helper, run `Setup iPhone.command` with Harmony off. The recipient supplies their existing Screen Time code and grants Screen Recording access. Test with their device at an empty Screen Time passcode prompt.

If macOS blocks the locally signed app, let the recipient review and allow the trusted copy in Privacy & Security. Do not disable system security as an installation shortcut.

Run `Uninstall Harmony.command` or `~/.local/bin/harmony uninstall` to remove the app, command, and service while keeping settings. `--remove-data` explicitly removes local configuration, preferences, and the encrypted phone vault too. Finish a session before uninstalling.

Settings live in `~/Library/Application Support/Harmony Focus/`. If changing `configuration.json` with Harmony off, keep `approvedPaths` and `approvedBundleIDs` synchronized and preserve `unlockDigest`. The phone vault depends on the existing recovery password. Never copy someone else's settings or put passwords, phone codes, or vaults in chat or source control.
