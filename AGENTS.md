# Repository Guidelines

## Project Structure & Module Organization
- `Sources/Community` holds the library code, organized into actors (`Actor/`), CLI commands (`CLI/`), and PTY support (`PTY/`).
- `Sources/mm` contains the executable entry point for the `mm` CLI.
- `Tests/communityTests` contains Swift Testing-based tests for the `Community` module.
- `DESIGN.md` documents high-level design decisions and intent.

## Build, Test, and Development Commands
- `swift build`: Builds the library and the `mm` executable.
- `swift run mm --help`: Runs the CLI and shows available subcommands.
- `swift test`: Executes the test suite under `Tests/`.

## Coding Style & Naming Conventions
- Follow standard Swift formatting (4-space indentation, one type per file).
- Types use `UpperCamelCase`; functions and properties use `lowerCamelCase`.
- Keep CLI subcommands in `Sources/Community/CLI` and name them `*Command.swift` (e.g., `JoinCommand.swift`).

## Testing Guidelines
- Tests use the Swift Testing framework (`import Testing`).
- Place tests in `Tests/communityTests` and name test functions with descriptive verbs (e.g., `@Test func joinsMember()`)
- Run `swift test` before opening a PR.

## Commit & Pull Request Guidelines
- This repository does not include Git history in the working copy, so no commit message convention is enforced here.
- PRs should include a concise summary, testing notes (commands run), and screenshots only if CLI output changes.

## Security & Configuration Tips
- This package depends on local path packages (`../swift-actor-runtime`, `../swift-discovery`). Ensure those paths exist before building.
