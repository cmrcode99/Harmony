# Preparing a release

Keep a release reproducible, reviewable, and honest about the devices tested. A passing automated check is one part of release verification.

## Before packaging

1. Run `make check` on the exact commit to release and confirm its GitHub Actions checks pass.
2. Review the version in `Info.plist` and summarize user-visible changes in `CHANGELOG.md`.
3. Test a fresh installation, an update, and default uninstall on a separate user account or Mac. Verify that uninstall preserves configuration.
4. Test the app with its macOS permissions granted and denied. Check early exit, expiry, sleep/wake, crash/login recovery, and the optional phone helper if it is included in the release claim.
5. Check that the package contains only media and artwork you have permission to distribute. The source checkout does not include third-party video files.

Record the macOS version, Mac architecture, commit, and scenarios tested in the release notes. Label early releases as beta until these flows have been verified. Do not describe a cross-compiled build as tested on that hardware.

## Build locally

```sh
make share
```

This creates a local ZIP and SHA-256 checksum in `dist/`; it does not upload anything. `HARMONY_ARCH=arm64` or `HARMONY_ARCH=x86_64` selects an architecture. The default is the current Mac. Use the package matching the recipient's Mac and verify the checksum from the directory containing the archive.

The default eye icon is generated from `tools/make-icon.swift`; the SVG mark is in `assets/harmony-mark.svg`. To use your own redistributable icon, set `HARMONY_ICON=/absolute/path/to/custom.icns`.

`HARMONY_SIGN_IDENTITY` selects an existing code-signing identity. Local ad-hoc signing is the default; it is not notarization. Keep signing credentials outside the repository. Distribution signing and Apple notarization need a separately configured release process; do not claim them until the resulting artifact is verified.

## Publish

Include the MIT `LICENSE` file, then review the final package, checksum, source commit, and release notes before creating a GitHub release. Do not upload local configuration, phone vaults, credentials, or unlicensed media. Include installation requirements, known limitations, the verification record, and a rollback path.

For an initial beta without redistributable media, publish source and instructions for supplying a local MP4 instead of uploading a package containing personal media. Package creation and publication remain separate operations.
