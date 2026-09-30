# Repository guidelines

## Scope and structure

This file applies to the whole repository. The repository contains four Dart projects rather than a single workspace:

- `simple_live_core`: shared live-site APIs, models, parsers, and danmaku clients.
- `simple_live_app`: Flutter client for Android, iOS, macOS, Windows, and Linux.
- `simple_live_tv_app`: Flutter client focused on Android TV.
- `simple_live_console`: command-line client built on `simple_live_core`.

The two clients and the console use `simple_live_core` through a relative path dependency. When changing a public core API, parser, model, or protocol implementation, check every consumer that is affected.

## Upstream sync

This repository is a fork of `xiaoyaocz/dart_simple_live`; the remote `upstream`
is that project and `origin` is the fork. Track **`upstream/dev`**, never
`upstream/master`:

- `upstream/dev` is the development line and receives every release.
- `upstream/master` is the release line. Upstream merges `dev` into it only at
  release time, so it lags by however long the gap between releases is. A branch
  cut from it silently misses everything released since. This fork's original
  baseline, `ba828e6`, sat on the release line and was seven months and three
  releases behind before the first real sync.
- Merge upstream in; do not rebase, so shared history stays intact:
  `git fetch upstream --tags && git merge upstream/dev`.
- After merging, re-check the fork's build workarounds: the `auto_orientation_v2`
  and `dynamic_color` version pins, the `flutter clean` step in the dev
  workflows, and the `android/build.gradle.kts` override. These have historically
  duplicated fixes that upstream went on to make itself, so drop any that
  upstream now covers.

Fork releases are tagged `fork_v*` (app) and `fork_tv_v*` (TV), never `dev_v*` or
`dev_tv_v*`, so they cannot collide with upstream tags of the same name. The dev
workflows check out `${{ github.ref_name }}`, so a pushed tag builds the commit
it points at rather than whatever the branch happens to be.

## Toolchain

- Flutter is pinned to `3.47.1` with FVM in both Flutter projects.
- Run Flutter commands from the relevant app directory with `fvm flutter ...`; use `fvm dart ...` when a Flutter project's Dart SDK is required.
- Run `fvm install` in each Flutter project if the pinned SDK is not available locally.
- If FVM is not installed on the machine, do not fall back to the Flutter on
  `PATH` — it is a different version and will not match `.fvmrc`. Install the
  pinned SDK through whatever version manager is available (for example
  `mise install flutter@3.47.1-stable`) and run commands through it, e.g.
  `mise exec flutter@3.47.1-stable -- flutter ...`. Verify with
  `... flutter --version` that the reported version is `3.47.1`.
- Run Dart commands for `simple_live_core` and `simple_live_console` from their own directories.
- Each project owns its `pubspec.lock`. Keep intentional lockfile changes, but do not regenerate unrelated dependencies.
- Do not commit generated or local state from `.dart_tool/`, `.fvm/`, `build/`, IDE settings, CocoaPods, or platform ephemeral directories.

## Development conventions

- Follow the existing Dart style and the lints in each project's `analysis_options.yaml`.
- Format changed Dart files with `dart format`; avoid repository-wide formatting for a scoped change.
- Keep platform-independent live-site behavior in `simple_live_core`. Keep presentation, routing, persistence, and platform integration in the corresponding Flutter app.
- The Flutter clients use GetX for routing and dependency lookup, Hive for local persistence, and `media_kit` for playback. Extend the existing patterns unless the task explicitly calls for an architectural change.
- Preserve existing public names and stored Hive data compatibility unless a migration is included.
- Never commit credentials, signing files, account cookies, tokens, or private API responses.

## Validation

Fetch dependencies before validation when `pubspec.yaml` or the SDK version changes.

```sh
cd simple_live_core && dart pub get && dart analyze && dart test
cd simple_live_console && dart pub get && dart analyze && dart test
cd simple_live_app && fvm flutter pub get && fvm flutter analyze && fvm flutter test
cd simple_live_tv_app && fvm flutter pub get && fvm flutter analyze && fvm flutter test
```

Start with the project directly changed. If `simple_live_core` changes, also validate the clients or console that use the changed API. For native platform changes, build or test the affected platform when the required host toolchain is available.
