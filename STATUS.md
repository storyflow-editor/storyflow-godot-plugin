# StoryFlow Godot Plugin — Status

## What's Done

- Full architecture ported from Unreal plugin (all 160+ node types, evaluator, component, importer, manager, save/load)
- All critical behaviors implemented: character-before-interpolation, set-node return-to-dialogue, forEach loops, RunScript/RunFlow call stacks, audio fresh-entry logic, once-only options, recursion protection
- Cross-verified against Unreal C++ source — bugs found during review were fixed
- 30 files, ~7,000 lines of GDScript
- Editor plugin with import dock, EditorImportPlugin for .storyflow files, WebSocket live sync with timer-based polling
- Default dialogue UI scene with auto-wired node references (`@onready` + `%UniqueName`)
- **Typed public API**: All public-facing data uses typed classes instead of raw Dictionaries:
  - `StoryFlowDialogueState` — full dialogue state with typed properties
  - `StoryFlowDialogueOption` — option id + interpolated text
  - `StoryFlowCharacterData` — resolved name, portrait Texture2D, variables
  - `StoryFlowTextBlock` — block id + interpolated text
  - `StoryFlowVariableChangeInfo` — typed signal payload for `variable_changed`
- **Typed internal state**: Execution stack frames and runtime state use typed classes:
  - `StoryFlowCallFrame` — RunScript call stack entry (script ref, return node, saved state)
  - `StoryFlowLoopFrame` — forEach loop stack entry (node id, type, index)
  - `StoryFlowNodeRuntimeState` — per-node cached output, loop state, output values
- **Extracted concerns**: Component delegates to focused helper classes:
  - `StoryFlowTextInterpolator` — variable interpolation (`{VarName}`, `{Character.Name}`) + string table lookup
  - `StoryFlowAudioController` — dialogue audio playback (play, stop, loop, asset resolution)
- **Deferred variable re-renders**: During processing chains (option → set → set → dialogue), variable-change re-renders are batched and flushed once at the end instead of per-variable
- **Asset resolution**: Images and audio resolved to actual `Texture2D` / `AudioStream` Resources in `_build_dialogue_state()`, looking up from character, script, and project `resolved_assets` dictionaries
- **Typed manager access**: `get_manager()` returns `StoryFlowManager` (not `Node`) for static type safety
- **JSON-based persistence**: Project/Script/Character use `RefCounted` (not `Resource`); import metadata saved as JSON so the manager re-imports from source at startup — no broken `.tres` serialization
- **Automatic autoload**: Plugin registers/unregisters `StoryFlowManager` autoload on enable/disable
- **camelCase passthrough**: Node data dict keys pass through from JSON as-is (matching Unreal plugin pattern), no importer normalization
- **Enum type annotations**: All node type and variable type locals use `StoryFlowTypes.NodeType` / `StoryFlowTypes.VariableType` instead of raw `int`
- **Shared utilities**: `StoryFlowVariant.deep_copy_variables()` static method (no duplication between manager and component)
- **Safe teardown**: `_exit_tree()` silently resets state without emitting signals or accessing potentially-freed autoloads
- **Save slot enumeration**: `list_save_slots()` on both `StoryFlowSaveData` and `StoryFlowManager`

## What's NOT Done / Needs Attention

### 1. Zero Runtime Testing
None of this has been loaded in Godot. There will be syntax errors, type mismatches, and runtime bugs. GDScript is unforgiving about things like calling methods on null and Dictionary key access patterns.

**Action:** Import a real StoryFlow project and work through errors until a basic dialogue runs.

### 2. Input Option Handling
Dialogue input options (text fields, number inputs on dialogue nodes) are not implemented in the evaluator. The editor runtime supports `InputChanged(optionId, value)` and reading from `InputOptionValues` during evaluation chains. Neither the Godot nor Unreal plugin evaluator implements this yet. The execution context has the `input_option_values` dictionary ready but the evaluator never reads from it.

**Action:** Implement input option value reading in the evaluator and input change handling in the component.

### 3. Asset Resolution (Images / Audio) — Partially Done
The component now resolves images and audio to actual `Texture2D` / `AudioStream` from `resolved_assets` dictionaries. However, the **importer** still needs to actually load files from disk into those dictionaries — currently it copies files but doesn't call `ResourceLoader.load()` to populate `resolved_assets` with real Resource objects.

**Action:** Update the importer to load image/audio files into `resolved_assets` as Texture2D/AudioStream when importing a project.

### 4. WebSocket Live Sync — Partially Done
The WebSocket client connects and polls via a Timer in the editor dock. However, the actual sync protocol (receiving full project data inline, triggering reimport) is minimal and untested.

**Action:** Test against the StoryFlow Editor's WebSocket server and flesh out the message handling.

### 5. No Example Project
There's no test `.storyflow` project to validate the full import-to-runtime pipeline.

**Action:** Export a simple test project from StoryFlow Editor and use it to validate the entire flow.

### 6. Edge Cases Untested
Array operations, nested RunScript/RunFlow, forEach loops, character variable interpolation, enum switching, random branches, weighted options — all written based on the Unreal source but never exercised.

**Action:** Create test scenarios that exercise each node type category.

## Recommended First Steps

1. Open Godot 4.3+, create a new project, copy `addons/storyflow/` into it
2. Enable the plugin in Project Settings (this automatically registers the StoryFlowManager autoload)
3. Export a simple test project from StoryFlow Editor (a few dialogue nodes with branching)
4. Use the StoryFlow editor dock to import it
5. Create a scene with a StoryFlowComponent, set the script_path, call `start_dialogue()`
6. Fix runtime errors as they appear
