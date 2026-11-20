# ADR 0002: Camera Labels Are an Experimental App Setting

Date: 2026-10-05
Status: Accepted

## Context

A camera label becomes a library folder name. If a user changes a label later, new files go to a new folder. Fyluro never renames old folders (I-2). The library can then split. The owner considers the feature experimental.

## Decision

- The app has the setting "Use camera labels (experimental)". It is off by default.
- When the setting is off, the app ignores the catalog and uses the raw model code.
- The app reads the setting at run start and stores it in the ingest request (I-10).
- The receipt records the value (`camera_catalog_used`).
- The setting is app-only. The CLI is a separate interface. It has no setting and always reads the catalog.

## Why

- A setting that only hides the editor would leave old names active. That is a surprise.
- A run-start snapshot keeps one run consistent (I-10).
- The receipt shows why folder names differ between runs.

## Consequences

- The app and the CLI can give different folder names for the same card when the setting is off and a catalog file exists. This is accepted.
- The scan preview in the app is stale after the user changes the setting. The next scan corrects it. This matches the rule that a label save does not start a rescan.

## Revisit trigger

- The feature leaves the experimental stage. Then remove the setting or turn it on by default.
- Users report confusion about app and CLI folder names.
