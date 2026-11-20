# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Report a vulnerability

Do not open a public GitHub issue for a security vulnerability.

1. Open the repository **Security** tab on GitHub.
2. Select **Report a vulnerability** to open a private report.
3. Include the Fyluro version, macOS version, steps to reproduce, and affected files or paths.

## Security guarantees and threat model

Fyluro is a local-only macOS app and CLI.
It makes no network requests and collects no telemetry.

Its safety guarantees are defined by invariants `I-1` to `I-10` in [ROL-6-spec-and-invariants.md](docs/ROL-6-spec-and-invariants.md) and mapped to automated tests in [security-threat-model.md](docs/security-threat-model.md).
