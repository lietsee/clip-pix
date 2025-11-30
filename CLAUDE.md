# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

ClipPix is a Windows desktop application built with Flutter that automatically captures images from the clipboard, saves them with metadata (JSON), and displays them in a dynamic Pinterest-style grid with interactive resizing, zoom, and preview capabilities.

**Tech Stack**: Flutter 3.22+, Dart 3.5+, Hive (persistence), Provider + StateNotifier (state management), win32 (clipboard integration), flutter_staggered_grid_view

## Essential Commands

```bash
# Dependencies
flutter pub get                    # Install/update dependencies

# Development
flutter run -d windows             # Run on Windows desktop
flutter run -d windows --profile   # Run in profile mode with DevTools access

# Testing
flutter test                       # Run all unit/widget tests
flutter test --coverage            # Run with coverage report
flutter drive --target=integration_test/resize_flow_test.dart  # Integration tests

# Build
flutter build windows              # Production build
dart format .                      # Format all Dart files (required by CI)
flutter analyze                    # Static analysis
```

## High-Level Architecture

### Module Organization
- **`lib/ui/`** - Surface layer: `MainScreen`, `GridViewModule`, `ImageCard`, `ImagePreviewWindow`, `PinterestGrid` widgets
- **`lib/system/`** - System services: `ClipboardMonitor` (win32 hooks), `FileWatcher`, `ImageSaver`, `ClipboardCopyService`, `UrlDownloadService`
- **`lib/system/state/`** - State management: StateNotifiers (`ImageLibraryNotifier`, `ImageHistoryNotifier`, `WatcherStatusNotifier`, `SelectedFolderNotifier`), `GridLayoutStore`, `GridLayoutLayoutEngine`, `GridResizeController`
- **`lib/data/`** - Data layer: Hive repositories (`ImageRepository`, `GridCardPreferencesRepository`, `GridLayoutSettingsRepository`, `GridOrderRepository`) and model classes
- **`docs/`** - Design specifications aligned with code modules (e.g., `docs/system/clipboard_monitor.md` ↔ `lib/system/clipboard_monitor.dart`)

### Key Data Flow Patterns

**Clipboard → Save → Display**:
1. `ClipboardMonitor` (win32 polling/hooks) captures image/URL from clipboard
2. `ImageSaver` writes image + JSON metadata to selected folder
3. `FileWatcher` detects new file → notifies `ImageLibraryNotifier`
4. `GridViewModule` rebuilds with updated `ImageLibraryState`

**UI Interaction → Copy**:
1. User copies image from `ImageCard` or `ImagePreviewWindow`
2. `ClipboardCopyService` writes to clipboard with guard token
3. `ClipboardMonitor` ignores self-triggered events via guard token

**Grid Layout & Resize**:
1. `GridLayoutStore` holds card geometry (width/height/scale/columnSpan) and delegates layout calculation to `GridLayoutLayoutEngine`
2. `GridLayoutLayoutEngine` generates `LayoutSnapshot` (rect positions, IDs, column spans)
3. `GridLayoutSurface` manages Front/Back buffer for snapshots, coordinating with `GeometryMutationQueue` to batch updates
4. User actions (column changes, bulk alignment, drag resize) → `GridResizeController` → `GridLayoutStore.updateGeometry()` → batched `notifyListeners()` once per commit
5. `PinterestGrid` (Pinterest-style Sliver) renders cards based on snapshot geometry

### State Management Structure

Provider tree (see `lib/main.dart` and `lib/system/state/app_state_provider.dart`):
- `SelectedFolderNotifier` - Selected folder, view mode (root/subfolder), tab state, scroll position (persisted to Hive)
- `WatcherStatusNotifier` - FileWatcher/ClipboardMonitor active flags and error state
- `ImageHistoryNotifier` - Recent saved images (Queue, max 20 entries)
- `ImageLibraryNotifier` - Current folder's image list, loading state, manages add/update/remove operations
- `GridLayoutStore` - Grid card geometry, layout engine integration, front/back buffer coordination
- `GridResizeController` - Resize command handling, undo/redo stack (3 levels)
- `GridLayoutMutationController` - Batches geometry mutations for performance

### Grid Layout & Rendering

**Current Implementation (as of f787070)**:
- `GridLayoutLayoutEngine` produces `LayoutSnapshot` with card rects and IDs
- `GridLayoutSurface` uses Front/Back buffer pattern for smooth layout updates
- `GeometryMutationQueue` batches column/resize updates with 60ms throttling to minimize `notifyListeners()` calls
- `PinterestSliverGrid` renders cards using masonry layout algorithm with proper termination condition

**Masonry Layout Loop** (see `docs/ui/grid_view.md` Section 13):
- Layout loop terminates when **all columns** exceed `targetEndScrollOffset` (not when any single card exceeds it)
- This ensures cards are placed in shorter columns even when taller columns already exceed the viewport
- Implementation: `columnHeights.reduce(math.min) > targetEndScrollOffset`

**Semantics** (resolved - see `docs/archive/known_issue_grid_semantics.md`):
- Semantics disabled via `ExcludeSemantics` wrapper as accessibility is not required for this desktop app

## Testing Strategy

### Test File Structure
Mirror implementation structure under `test/` directory:
- `test/system/` - Service layer tests (e.g., `file_watcher_test.dart`, `grid_layout_layout_engine_test.dart`)
- `test/system/state/` - State management tests (e.g., `grid_layout_store_test.dart`, `image_library_notifier_test.dart`)
- `test/ui/` - Widget tests (e.g., `image_card_test.dart`, `grid_view_module_test.dart`)
- `integration_test/` - Integration tests for full workflows (e.g., `resize_flow_test.dart`)

### Coverage Requirements
- Target 80%+ line coverage for core modules (ClipboardMonitor, ImageSaver, FileWatcher, GridLayoutStore)
- Add golden tests for `ImageCard` states (loading/ready/error)
- Update goldens with `flutter test --update-goldens` only when layout changes are intentional

### Test Isolation
- Use mocktail for service mocking
- Create temporary directories for file I/O tests
- Mock Hive boxes with in-memory storage for state tests

## Persistence & Configuration

**Hive Boxes** (see `lib/main.dart:_openCoreBoxes`):
- `app_state` - SelectedFolderState (folder path, history, viewMode, currentTab, scrollOffset)
- `image_history` - ImageEntry queue (recent saves)
- `grid_card_prefs` - Per-card size/scale preferences (GridCardPreference)
- `grid_layout` - GridLayoutSettings (column count, background color, bulk width)
- `grid_order` - Custom card ordering for drag-and-drop

**Hive Adapters** (registered in `lib/main.dart:_registerHiveAdapters`):
- Type IDs 0-5: ImageSourceType, ImageItem, ImageEntry, GridCardPreference, GridLayoutSettings, GridBackgroundTone

## Important Architectural Decisions

### Why GridLayoutStore + LayoutEngine?
Previous architecture had per-card `ValueNotifier` instances causing excessive `notifyListeners()` during bulk operations (column changes, alignment). New design centralizes geometry in `GridLayoutStore`, uses `GridLayoutLayoutEngine` for pure layout calculation, and batches updates via Front/Back buffer to avoid semantics tree corruption.

### Why Guard Token for Clipboard Copy?
`ClipboardMonitor` polls system clipboard continuously. When app copies an image, it must ignore its own event. `ClipboardCopyService` injects guard token and `ClipboardMonitor` checks it before triggering save.

### Why Separate Preview Window Process?
`ImagePreviewWindow` can be launched as standalone process (`--preview` flag with JSON payload) to enable always-on-top behavior independent of main window state.

## Code Style & Conventions

- **Formatting**: 2-space indentation, run `dart format .` before committing (CI enforces)
- **Naming**: PascalCase for classes/widgets (`ImageCard`), lowerCamelCase for methods/fields, snake_case for files (`grid_view_module.dart`)
- **Documentation**: Align code changes with matching spec files in `docs/` (e.g., update `docs/system/clipboard_monitor.md` when modifying `lib/system/clipboard_monitor.dart`)
- **Services**: Extract side-effectful code into services under `lib/system/` with explicit interfaces for testability

## Commit Guidelines

Follow Conventional Commits format:
- `feat: add clipboard monitor hook`
- `fix: throttle clipboard queue`
- `docs: update grid semantics plan`
- `test: add golden tests for ImageCard`

Each PR should include:
- Problem summary with links to relevant spec files in `docs/`
- Implementation notes
- Screenshots/recordings for UI changes
- Updated documentation when behavior diverges from specs

## Key Files to Reference

- **System Specs**: `docs/overview.md`, `docs/system/state_management.md`, `docs/system/clipboard_monitor.md`, `docs/system/image_saver.md`, `docs/system/file_watcher.md`
- **UI Specs**: `docs/ui/main_screen.md`, `docs/ui/grid_view.md`, `docs/ui/image_card.md`, `docs/ui/image_preview_window.md`
- **Architecture**: `docs/architecture/grid_rendering_pipeline.md`, `docs/architecture/data_flow.md`, `docs/architecture/state_management_flow.md`
- **Archive**: `docs/archive/pinterest_grid_migration.md`, `docs/archive/known_issue_grid_semantics.md`, `docs/archive/grid_semantics_rebuild_plan.md`

## Recent Bug Fixes

### Masonry Layout Loop Fix (commit f787070, 2025-11-30)
**Problem**: Cards at viewport bottom were not displayed until scrolled to center.

**Root Cause**: Layout loop terminated when ANY card exceeded `targetEndScrollOffset`, but in masonry layout cards are placed in the shortest column. This caused cards in shorter columns to be skipped.

**Fix**: Changed termination condition from `childEnd > targetEndScrollOffset` to `minColumnHeight > targetEndScrollOffset` to ensure all columns are filled.

See: `docs/ui/grid_view.md` Section 13, `docs/architecture/grid_rendering_pipeline.md`
