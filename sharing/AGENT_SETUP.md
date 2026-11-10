# Set up Harmony with your agent

Give your agent the Harmony folder or this repository link, then say:

> Help me set up Harmony. Read its AGENT_SETUP.md, handle the computer steps, and explain only what I need to do myself. Get the Mac app working first; ask about the optional phone helper afterward. Keep passwords and passcodes out of chat.

## For the agent

Guide the user one step at a time. Do routine installation and verification work yourself; don't turn every command into a question. Explain manual actions in plain language and wait when the user needs to use a private prompt or grant a permission.

### 1. Install the Mac app

Choose the route matching the folder you received:

| Folder contains | What to do |
| --- | --- |
| `Harmony.app` and `Install Harmony.command` | Run the installer. No compiler or Python is needed. |
| `setup.sh` and Swift source files | Run `./setup.sh --check`, resolve reported prerequisites, then run `./setup.sh`. The user can add videos in the setup window or later; a video file is not required to install. |

If Harmony is already running, finish its session before updating. Installation keeps existing settings and does not start focus mode. Use `~/.local/bin/harmony` directly; editing the user's shell configuration is unnecessary.

### 2. Help the user finish the setup window

Ask which apps they want available during focus time, including their agent and terminal. The user drags applications into **Allowed apps** (or uses Add apps), then adds videos to **Your videos** if they want. Show them the Remove and reorder controls. They then save their generated **Harmony recovery password** privately. Never request that password in chat.

Explain: “Harmony closes apps outside your allowed list during focus sessions. Save work before starting.”

Help the user enable Harmony under **System Settings → Privacy & Security → Accessibility**. The user grants the permission. If macOS blocks the downloaded app, explain its approval prompt; do not disable system security.

Verify `~/.local/bin/harmony help`. When the user is ready to try focus mode, use `~/.local/bin/harmony`; exit an untimed session with `~/.local/bin/harmony exit`. Timed early exit uses the eye menu and recovery password. Do not start a timed test as part of installation.

For later changes, use **Allowed apps…** or **Allowed videos…** below **Move window** in the eye menu. Each opens Finder with the relevant settings area. `harmony setup apps` and `harmony setup videos` do the same while Harmony is off. Untimed focus pauses while settings are open. Timed sessions must finish first. There is no need to edit JSON for normal app or video changes.

### 3. Offer the phone helper, with “skip for now” as a complete outcome

Ask: “Would you also like help reducing phone distractions? This is optional, and the Mac app works without it.” The phone helper is experimental and needs a supported iPhone Mirroring setup.

If yes, explain the two different credentials:

| Credential | What it does |
| --- | --- |
| Harmony recovery password | Unlocks Harmony sessions and the encrypted phone helper. |
| Screen Time passcode | Controls Apple's restrictions on the iPhone. It is also different from the iPhone unlock passcode. |

Walk the user through choosing Screen Time limits, Downtime, and apps they want to keep available **on their own iPhone**. Keep [Apple's passcode recovery instructions](https://support.apple.com/en-us/102677) available. Then help them connect [iPhone Mirroring](https://support.apple.com/en-us/120421) and verify it works before involving Harmony. Follow the labels on their device; they vary by software version.

With Harmony off, run:

```sh
~/.local/bin/harmony setup phone
```

The user enters their Harmony recovery password and existing four-digit Screen Time passcode into the local windows. Harmony stores an encrypted copy on this Mac; it does not create or change Apple's Screen Time settings. Never ask the user to paste either secret into chat or a command.

Help the user grant Screen Recording permission for this optional feature. When they want to test it, have them open iPhone Mirroring at an empty Screen Time passcode prompt, start Harmony, and use `~/.local/bin/harmony phone`. The user enters their Harmony password locally. Stop if the target is not recognized; do not guess codes or repeat phone input.

### 4. Leave a short handoff

Tell the user how to start, exit, and reopen setup. Mention only any unfinished manual step. If they skipped phone setup, the Mac setup is complete.

For later changes, edit allowed-app configuration only with Harmony off, keep `approvedPaths` and `approvedBundleIDs` synchronized, and preserve `unlockDigest`. Settings live in `~/Library/Application Support/Harmony Focus/`. `harmony uninstall` keeps settings; `--remove-data` explicitly deletes them. Do not copy someone else's settings, credentials, or phone vault.
