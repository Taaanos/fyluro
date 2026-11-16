# Contributing to RollKeep

Thank you for contributing to RollKeep.

## Before you change code

1. Read [README.md](README.md) for the build and test commands.
2. Read [ROL-6-spec-and-invariants.md](docs/ROL-6-spec-and-invariants.md). RollKeep never violates invariants `I-1` to `I-10`.
3. Read [AGENTS.md](AGENTS.md) for the work loop and writing rules.
4. Open an issue to discuss behavior changes before you write code.

## Pull request checklist

1. Keep each pull request small and focused on one change.
2. Add or update unit tests or E2E tests for your change.
3. Run `swift test` and confirm all unit tests pass.
4. Run `scripts/run-e2e-tests.sh` if you change ingest, CLI, or launcher behavior.
5. Write documentation updates in ASD-STE100 style as described in [AGENTS.md](AGENTS.md).

## Security issues

Follow [SECURITY.md](SECURITY.md) to report security bugs privately.

## License

Contributions are licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
