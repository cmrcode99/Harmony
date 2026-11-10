# Security

Harmony stores a recovery-password hash and, if configured, an encrypted phone code on the user's Mac. It can force-quit apps and send input to iPhone Mirroring when the user authorizes the phone helper. Changes to those boundaries deserve careful review.

## Report a vulnerability privately

Use this repository's **Security → Advisories → Report a vulnerability** option if it is available. If private reporting is unavailable, open an issue asking for a private contact channel without describing the exploit or including sensitive data.

A useful private report includes the affected commit or version, macOS version, reproducible steps, impact, and whether a clean installation is affected. Use test credentials and redact personal paths. Do not attach your configuration, encrypted phone vault, recovery password, phone code, signing keys, or private screen captures.

There is no published security response SLA yet. Until a supported release policy is established, fixes target the current development branch.

## Security boundaries

Harmony is a personal focus aid, not an administrator-enforced security boundary. A user who controls their Mac can alter local software and data. Allowed apps can still access websites and execute commands. The phone helper relies on local screen recognition and stops on uncertainty; it cannot prove that the phone accepted a code.

Keep your recovery password accessible outside a locked session. The app cannot recover the original password from its hash. The phone vault depends on that password, so changing only the hash can make the vault unusable.

Current local builds are not Apple-notarized. Only install a package whose source and origin you trust. See [release preparation](docs/releases.md) for distribution checks.
