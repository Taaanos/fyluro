# ADR 0004: Enable App Sandbox with Ad-Hoc Signing

Date: 2026-11-17
Status: Accepted

## Context

Fyluro previously ran unsandboxed, so it could read any unprotected user file on the system.
We want the macOS app (`Fyluro.app`) to access only folders that the user explicitly selects.
The maintainer distributes `Fyluro.app` via GitHub Releases and a Homebrew tap with ad-hoc signing (`codesign --sign -`) and no Apple Developer ID certificate.

## Decision

- Sign `fyluro-launcher` (`Fyluro.app`) with App Sandbox (`com.apple.security.app-sandbox`), user-selected read/write access (`com.apple.security.files.user-selected.read-write`), and app-scoped bookmarks (`com.apple.security.files.bookmarks.app-scope`).
- Sign the bundled `Contents/MacOS/fyluro` CLI binary separately without sandbox entitlements so Terminal runs continue to work.
- Persist the user's destination folder as a security-scoped bookmark in `UserDefaults`.
- Stay idle on launch instead of scanning `/Volumes` for source cards or `_ingest_receipts` folders.
- Reject single-file drops in `LauncherFolderDropResolver` because a dropped file does not grant sandbox access to its parent folder.
- Do not migrate `~/Library/Application Support/Fyluro/CameraCatalog.json` or unsandboxed `UserDefaults` into the sandbox container.

## Why

- App Sandbox limits the app's file access to user-selected folders, which strengthens `I-1` and `I-9` at the OS boundary.
- Separate signing keeps the bundled CLI usable from Terminal without sandbox errors.
- Skipping `/Volumes` auto-scan avoids permission errors on launch under App Sandbox.

## Consequences

- Ad-hoc signing pins security-scoped bookmarks to the build's `cdhash`.
- Persisted destination bookmarks work across restarts of the same build, but macOS invalidates them when the user updates `Fyluro.app`.
- After an app update, the app discards the unresolvable bookmark and waits for the user to pick the destination folder once.
- `Fyluro.app` and the `fyluro` CLI no longer share `CameraCatalog.json` because the app uses its sandbox container.

## Revisit trigger

- The maintainer obtains an Apple Developer ID certificate and enables Developer ID signing so bookmarks survive app updates.
- Users report high friction from re-selecting the destination folder after updates.
