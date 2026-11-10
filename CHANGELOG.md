# Changelog

## Unreleased

Production cleanup for the first public beta. This section describes development changes; it is not a stable-release announcement.

### Changed

- Split process startup, lifecycle, menus, overlay controls, and video playback into focused Swift files.
- Made setup preflight read-only and shared installation, update, and uninstall handling.
- Added uninstall commands that preserve settings unless removal is explicitly requested.
- Tightened configuration validation and private storage while retaining existing data formats.
- Prevented child executables from inheriting the app's singleton lock.
- Added an MIT license, original icon artwork, and clearer setup, contribution, security, and release guidance.

### Verification

Automated regression checks run in GitHub Actions. Real-device permissions, phone input, update, and recovery flows still need recorded manual testing before a stable release.

## 1.6.1 — Initial public source

- Published the native macOS focus utility as Harmony.
- Added per-user setup, an offline video playlist, timed sessions, and an optional iPhone helper.
- Included a source build, local package tools, and regression checks.
