# Repository Guidelines

## Project Structure & Module Organization
ClipPix documents are split under `docs/system`, `docs/ui`, and `docs/data`; always align code with the matching detail spec (e.g., `lib/system/clipboard_monitor.dart` follows `docs/system/clipboard_monitor.md`). Surface modules live in `lib/ui/` (MainScreen, GridView, ImageCard, ImagePreviewWindow) and services in `lib/system/` (ClipboardMonitor, ClipboardCopyService, FileWatcher, ImageSaver). Persisted models and adapters belong under `lib/data/`, backed by Hive boxes as described in `docs/system/state_management.md`. Keep assets under `assets/` and isolate test fixtures in `test_resources/` so they do not leak into release builds.

## Build, Test, and Development Commands
Run `flutter pub get` before any build to sync package versions. `flutter run -d windows` starts the desktop app to validate clipboard ingestion, GridView behaviour, and ImageCard zoom. Ship builds with `flutter build windows`, and gate every change on `flutter test`; add `--coverage` when updating CI dashboards. For integration checks use `flutter drive --target=integration_test/resize_flow_test.dart` as outlined in `docs/overview.md`.

## Coding Style & Naming Conventions
Use Dart’s default two-space indentation and keep files formatted with `dart format .` (CI will reject mixed styles). Widgets and classes use PascalCase (`ImageSaverPage`), methods and fields use lowerCamelCase, and files use snake_case (`grid_view_module.dart`). Extract side-effectful code into services under `lib/system/` and guard them with explicit interfaces for easier mocking.

## Testing Guidelines
Create mirrored test files under `test/` (e.g., `test/system/file_watcher_test.dart`) and group cases with `group()` descriptions that echo the spec headers in `docs/system/file_watcher.md`. Cover ClipboardMonitor hook/poll fallbacks and ImageSaver `SaveResult` notifications with isolates mocked out. Target少なくとも80% line coverage for core modules and add golden tests for ImageCard states (`loading`, `ready`, `error`). Use `flutter test --update-goldens` only when intentional layout shifts occur.

## Commit & Pull Request Guidelines
Follow Conventional Commits so history remains searchable (`feat: add clipboard monitor hook`, `fix: throttle clipboard queue`). Each PR needs a problem summary, implementation notes tied back to the relevant spec files, and screenshotsまたはscreen recordings when UI behavior changes. Link tracking issues and call out any TODOs that remain so maintainers can plan follow-up work.

## Documentation & Specification Updates
Whenever behavior diverges from the blueprints, update the matching file in `docs/` within the same PR and cross-reference the change in your description. Keep configuration defaults (paths, retry counts, zoom limits, guard tokens) synchronized between implementation and docs. Remove stale references (e.g., EXIF) if they reappear, and ensure new features ship with state management/clipboard specs updated alongside code.
