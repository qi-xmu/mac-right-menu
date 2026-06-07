# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mac-right-menu is a macOS Finder extension app that extends Finder's right-click (contextual menu) with custom actions.

## Tech Stack

- **Language**: Swift (Swift 6.3+, macOS 26+)
- **Framework**: `FinderSync` framework for Finder contextual menu integration
- **Build/Env Management**: pixi (conda-forge / osx-arm64)
- **Xcode**: Required for building, code signing, and running Finder extensions

## Key Architecture Concepts

### Finder Extension Structure

A macOS Finder right‑click extension has two parts:

1. **Container App** — A regular macOS app bundle. Its primary job is to:
   - Host and install the extension
   - Provide a settings/preferences UI (enable/disable extension, configure menu items)
   - Handle code signing (the extension inherits the container's signing)

2. **Finder Sync Extension target** — An app extension bundled inside the container app:
   - Implements `FinderSync` protocol from the `FinderSync` framework
   - Runs as a separate XPC service (`finder-sync` process)
   - Receives `menu(for menuKind: FIMenuKind)` callback when Finder builds its contextual menu
   - Returns `FIMenuItem` array to add custom menu items
   - Handles menu action callback (`selected(_:)`)

### Communication Patterns

- **Extension → Container**: Use `NSXPCConnection` or Darwin Notification Center (`CFNotificationCenter`)
- **Extension → External tools/services**: The extension can invoke shell commands via `Process()`, call web APIs, or interop with other apps via AppleEvents/scripting
- **Sandboxing**: Finder Sync Extensions run in a sandbox. All file access requires user intent or security-scoped bookmarks

### Execution Model

- The extension process is managed by Finder — it's launched on demand and can be terminated by Finder
- `beginExtension()` is called on activation
- `menu(for:)` is called whenever Finder is about to show a contextual menu (files/folders selected)
- Menu items are configured per `FIMenuKind`:
  - `.contextMenu` — right‑click on files/folders
  - `.toolbarItemMenu` — toolbar button
  - `.sidebarMenu` — sidebar items
  - `.gearMenu` — gear button in Finder window title bar

## Development Workflow

### Build & Run

```bash
# Open in Xcode (required for building/running)
xed .

# Build via xcodebuild
xcodebuild -scheme "mac-right-menu" -project mac-right-menu.xcodeproj build

# Build for release
xcodebuild -scheme "mac-right-menu" -project mac-right-menu.xcodeproj -configuration Release build

# Install the extension (after building)
pluginkit -a /path/to/build/mac-right-menu.app/Contents/PlugIns/FinderExtension.appex

# Enable/disable extension in System Settings > Privacy & Security > Extensions > Finder Extensions
# Or via command line:
pluginkit -e use -i com.you.bundle.finder-extension
```

### Testing

```bash
# After building and installing:
# 1. Kill and restart Finder to reload extensions:
killall Finder

# 2. Check console logs for extension output:
log stream --predicate 'subsystem == "com.you.bundle"'
```

### Debugging

- Finder extensions run out-of-process, so attach the debugger to the extension XPC process:
  - In Xcode: Product > Attach to Process > `finder-sync` (after right-click triggers the extension)
  - Or use `lldb -n finder-sync`
- Logs via `os_log` with a subsystem matching your bundle ID show up in Console.app

### Project Scaffolding

```bash
# Create Xcode project from scratch (if not using .xcodeproj yet):
xcode-select --install  # ensure Xcode CLT
# Then use Xcode > New Project > macOS > "App" + add "Finder Sync Extension" target

# Add Finder Sync Extension target to existing project:
# Xcode > File > New > Target > macOS > "Finder Sync Extension"
```

## Important Considerations

### Code Signing
- Finder extensions **must** be code‑signed (development or distribution certificate)
- The extension inherits the container app's bundle ID with `.FinderExtension` appended (e.g., `com.you.app.FinderExtension`)
- Hardened Runtime is automatically applied for notarized builds

### Sandbox Restrictions
- By default the extension can only read files the user interacts with
- To access arbitrary paths, use Security‑Scoped Bookmarks or request temporary entitlements (`com.apple.security.temporary-exception.files.*`)
- Consider using `NSFileAccessIntent` for reading file metadata

### Entitlements
Key entitlements for Finder extension:
- `com.apple.security.finder.sync` — required for Finder Sync
- `com.apple.security.app-sandbox` — sandbox (typically enabled)
- `com.apple.security.files.user-selected.read-write` — if modifying selected files

### macOS Versions
- **macOS 14 (Sonoma)**: The `FinderSync` framework still works but is deprecated. No direct replacement announced for Finder contextual menu extensions
- **macOS 15 (Sequoia)+**: Same — `FinderSync` continues to work
- If Apple eventually drops `FinderSync`, alternative approaches include: Shortcuts automations, AppleEvents, or a background daemon using `NSFileCoordinator`

## pixi Commands

```bash
# Activate the pixi environment
pixi shell

# Install dependencies (edit pixi.toml then:)
pixi install

# Add a dependency
pixi add <package>

# List configured tasks
pixi task list

# Run a configured task
pixi run <task-name>
```
