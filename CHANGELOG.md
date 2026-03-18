# Changelog

All notable changes to the StoryFlow Godot plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-03-18

### Added

- Full runtime execution engine with 160+ node types
- StoryFlowComponent node for running dialogues
- StoryFlowRuntime autoload for shared state management
- Variable system: boolean, integer, float, string, enum, image, audio, character types
- Array operations with ForEach loop support across all 7 array types
- Live text interpolation with `{varname}` and `{Character.Name}` syntax
- RunScript (call/return with parameters and outputs) and RunFlow (jump with exit flows)
- Branch nodes with boolean expression evaluation chains
- Character system with GetCharacterVar/SetCharacterVar including built-in Name/Image fields
- Audio playback with loop, reset, advance-on-end, and allow-skip support
- Background image support with persistence and reset
- Built-in dialogue UI with auto-fallback when no custom UI assigned
- Save/Load system with slot-based persistence
- Once-only option tracking
- WebSocket Live Sync with StoryFlow Editor
- Toolbar button with StoryFlow logo (Connect/Sync toggle)
- StoryFlow dock panel with Live Sync and Import sections
- JSON importer preserving original build directory structure
- Plugin version read from plugin.cfg and displayed in UI
