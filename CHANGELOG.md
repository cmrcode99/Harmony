# Changelog

## Unreleased — 1.7.3

- Fixed selection in Allowed apps. Select one app, or Command-click/Shift-click several, then choose Remove apps. Changes take effect when saved; application files are not deleted.

## 1.7.2

Production cleanup for the first public beta. This section describes development changes; it is not a stable-release announcement.

### Changed

- Restored the original character icon as the app and repository default.

- Redesigned settings with native Liquid Glass, separate app/video views, and shorter menu labels.
- Focused platform support and automated checks on Apple Silicon Macs.

- Added window-control permission status and an automatic minimization retry after approval.
- Preserved source video files during library cleanup and made damaged playlists repairable in settings.
- Preserved an existing signing identity during source updates to avoid unnecessary permission resets.

- Added direct Allowed apps and Allowed videos menu shortcuts with Finder, plus encrypted-vault migration metadata.

- Added native drag-and-drop settings for allowed apps and user video playlists, with no rebuild required.

- Added a shared agent-led setup guide and `harmony setup phone` for optional phone configuration.

- Split process startup, lifecycle, menus, overlay controls, and video playback into focused Swift files.
- Made setup preflight read-only and shared installation, update, and uninstall handling.
- Added uninstall commands that preserve settings unless removal is explicitly requested.
- Tightened configuration validation and private storage while retaining existing data formats.
- Prevented child executables from inheriting the app's singleton lock.
- Added an MIT license, the original character icon, and clearer setup, contribution, security, and release guidance.

### Verification

Automated regression checks run in GitHub Actions. Real-device permissions, phone input, update, and recovery flows still need recorded manual testing before a stable release.

## 1.6.1 — Initial public source

- Published the native macOS focus utility as Harmony.
- Added per-user setup, an offline video playlist, timed sessions, and an optional iPhone helper.
- Included a source build, local package tools, and regression checks.
