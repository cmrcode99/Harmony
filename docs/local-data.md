# Local data, updates, and recovery

Each user has a separate Harmony configuration. No account or shared password is needed.

| Location | Contents |
| --- | --- |
| `~/Applications/Harmony.app` | Installed application |
| `~/.local/bin/harmony` | Terminal command |
| `~/.local/lib/harmony/manage-install.sh` | Installed update/uninstall helper |
| `~/Library/Application Support/Harmony Focus/` | Configuration, optional encrypted phone vault, and instance lock |
| `~/Library/Preferences/local.harmony.focus.plist` | Session deadline and interface preferences |
| `~/Library/LaunchAgents/local.harmony.focus.supervisor.plist` | Per-user recovery service |

## Update

End the current session and quit Harmony. Rerun setup from an updated source checkout or run the installer from a newer package. The installer checks for an active or unfinished timed session and keeps local configuration. Failed replacement attempts roll back the app and service files.

Preserved settings do not guarantee preserved macOS permissions. If window minimization stops working after replacing a build, end the session, check Harmony under **System Settings → Privacy & Security → Accessibility** or **Device Control and Data Access**, and quit Harmony before trying again. The optional phone helper may also need Screen Recording approval again.

If installation reports an unfinished session, finish it through the eye menu with the recovery password, or let its deadline pass. Do not delete a deadline or kill a process as an update shortcut.

## Change allowed apps and videos

Open **Allowed apps…** or **Allowed videos…** below **Move window** in the eye menu to open settings and Finder together. You can also use **Apps and videos…** in the application menu or run `harmony setup` while the app is off. Drag apps or video files into their lists, or use the Add/Remove buttons. Changes are saved locally; no rebuild or JSON editing is needed. Untimed focus pauses while settings are open and resumes when they close. Timed sessions must finish before settings can change.

Custom videos and their playlist are in `~/Library/Application Support/Harmony Focus/Media/`. Removing a video removes Harmony’s copy only. To return to the bundled playlist, choose **Use included playlist**. User media is preserved by default during uninstall. Advanced configuration edits must preserve `version` and `unlockDigest` and keep app paths and bundle identifiers synchronized.

The phone-entry password prompt permits **⌘V for one successful phone-code entry per local calendar day**. Invalid passwords, cancellation, and failed phone entry do not consume the allowance. After it is used, type the recovery password until the next day. The allowance survives restarting Harmony; timed-session recovery prompts keep paste disabled.

## Passwords and phone setup

Save the generated recovery password during setup. The configuration stores its hash. Optional daily phone paste stores a recoverable copy in this Mac’s login Keychain under **Harmony daily phone paste**. When the daily paste is available, opening the phone password prompt copies it to this Mac’s clipboard. Harmony marks it concealed, then clears its own copy after 90 seconds or when the phone flow ends. Delete that Keychain item to discontinue automatic copying. The optional `phone-vault.json` contains the encrypted Screen Time code; its key depends on the recovery password.

Do not replace `unlockDigest` by itself. If you deliberately create a new configuration or recovery password, configure the phone helper again with the existing phone code. Keep private backups out of source control and chat logs.

## Uninstall

Run `harmony uninstall`, `./uninstall.sh` from a checkout, or **Uninstall Harmony.command** from a package. The default removes the app, CLI, installed helper, and recovery service while preserving configuration and preferences for a later reinstall.

Add `--remove-data` only when you also want the local configuration, phone vault, and preferences deleted. The uninstall command refuses to run during an active or unfinished timed session. It does not change Screen Time settings on the phone.
