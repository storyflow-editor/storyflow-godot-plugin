# StoryFlow Godot Plugin — Implementation Plan

## Overview

A Godot 4.x plugin (GDScript + GDExtension-ready) that mirrors the functionality of the StoryFlow Unreal Engine plugin. It imports StoryFlow Editor projects (JSON export), executes the node graph at runtime, and provides a developer-friendly API via signals, exported properties, and a base UI scene.

**Target:** Godot 4.3+
**Language:** GDScript (primary), with C# bindings as a stretch goal
**License:** Free and open-source (matching the Unreal plugin)

---

## Architecture Mapping: Unreal → Godot

| Unreal Concept | Godot Equivalent |
|---|---|
| `UStoryFlowComponent` (ActorComponent) | `StoryFlowComponent` (Node, added as child) |
| `UStoryFlowSubsystem` (GameInstanceSubsystem) | `StoryFlowManager` (Autoload singleton) |
| `UStoryFlowProjectAsset` (UDataAsset) | `StoryFlowProject` (Resource) |
| `UStoryFlowScriptAsset` (UDataAsset) | `StoryFlowScript` (Resource) |
| `UStoryFlowCharacterAsset` (UDataAsset) | `StoryFlowCharacter` (Resource) |
| `UStoryFlowSaveGame` (USaveGame) | `StoryFlowSaveData` (Resource / JSON file) |
| `UStoryFlowDialogueWidget` (UUserWidget) | `StoryFlowDialogueUI` (Control scene) |
| `UStoryFlowImporter` (editor class) | `StoryFlowImportPlugin` (EditorImportPlugin) |
| `UStoryFlowEditorSubsystem` | `StoryFlowEditorPlugin` (EditorPlugin) |
| Blueprint delegates | Godot signals |
| UPROPERTY(EditAnywhere) | `@export` variables |
| TSoftObjectPtr<UObject> | `ResourceLoader.load()` / preloaded paths |
| UAudioComponent | `AudioStreamPlayer` / `AudioStreamPlayer2D` |
| UTexture2D | `Texture2D` / `CompressedTexture2D` |

---

## Directory Structure

```
addons/storyflow/
├── plugin.cfg                          # Plugin metadata
├── storyflow_plugin.gd                 # EditorPlugin entry point
│
├── core/                               # Runtime core (works in exported games)
│   ├── storyflow_types.gd              # Enums, constants, data classes
│   ├── storyflow_variant.gd            # Type-safe variant (bool/int/float/string/array)
│   ├── storyflow_project.gd            # StoryFlowProject resource
│   ├── storyflow_script.gd             # StoryFlowScript resource
│   ├── storyflow_character.gd          # StoryFlowCharacter resource
│   ├── storyflow_handles.gd            # Handle parsing utilities
│   ├── storyflow_evaluator.gd          # Expression evaluator (lazy data node evaluation)
│   ├── storyflow_execution_context.gd  # Per-component execution state
│   ├── storyflow_component.gd          # Main runtime node (add to scenes)
│   ├── storyflow_manager.gd            # Autoload singleton (globals, save/load)
│   └── storyflow_save_data.gd          # Save/load serialization
│
├── ui/                                 # Optional built-in dialogue UI
│   ├── storyflow_dialogue_ui.gd        # Base dialogue Control script
│   ├── storyflow_dialogue_ui.tscn      # Default dialogue scene
│   └── storyflow_option_button.tscn    # Reusable option button scene
│
├── editor/                             # Editor-only tools
│   ├── storyflow_import_plugin.gd      # EditorImportPlugin for .storyflow files
│   ├── storyflow_importer.gd           # JSON parsing and resource creation
│   ├── storyflow_editor_dock.gd        # Editor dock panel (import UI, live sync)
│   └── storyflow_websocket_sync.gd     # WebSocket live sync client
│
├── icons/                              # Editor icons
│   └── storyflow_icon.svg
│
└── examples/                           # Example scenes (optional)
    ├── basic_dialogue/
    │   ├── basic_dialogue.tscn
    │   └── basic_dialogue.gd
    └── custom_ui/
        ├── custom_ui.tscn
        └── custom_ui.gd
```

---

## Module Specifications

### 1. `storyflow_types.gd` — Enums & Data Structures

All shared enumerations and inner classes used across the plugin.

```
enum NodeType {
    START, END, BRANCH, DIALOGUE, RUN_SCRIPT, RUN_FLOW, ENTRY_FLOW,
    # Boolean
    GET_BOOL, SET_BOOL, NOT_BOOL, AND_BOOL, OR_BOOL, EQUAL_BOOL,
    # Integer
    GET_INT, SET_INT, PLUS_INT, MINUS_INT, MULTIPLY_INT, DIVIDE_INT,
    RANDOM_INT, GREATER_THAN_INT, LESS_THAN_INT, EQUAL_INT,
    GREATER_THAN_OR_EQUAL_INT, LESS_THAN_OR_EQUAL_INT,
    # Float
    GET_FLOAT, SET_FLOAT, PLUS_FLOAT, MINUS_FLOAT, MULTIPLY_FLOAT,
    DIVIDE_FLOAT, RANDOM_FLOAT, GREATER_THAN_FLOAT, LESS_THAN_FLOAT,
    EQUAL_FLOAT, GREATER_THAN_OR_EQUAL_FLOAT, LESS_THAN_OR_EQUAL_FLOAT,
    # String
    GET_STRING, SET_STRING, CONCATENATE_STRING, EQUAL_STRING,
    CONTAINS_STRING, TO_UPPER_CASE, TO_LOWER_CASE,
    # Enum
    GET_ENUM, SET_ENUM, SWITCH_ON_ENUM,
    # Conversions
    INT_TO_BOOLEAN, FLOAT_TO_BOOLEAN, STRING_TO_BOOLEAN,
    BOOLEAN_TO_INT, FLOAT_TO_INT, STRING_TO_INT,
    BOOLEAN_TO_FLOAT, INT_TO_FLOAT, STRING_TO_FLOAT,
    BOOLEAN_TO_STRING, INT_TO_STRING, FLOAT_TO_STRING,
    # Arrays (Bool, Int, Float, String, Image, Character, Audio)
    GET_BOOL_ARRAY, SET_BOOL_ARRAY, ... (×7 typed arrays)
    ADD_TO_ARRAY, REMOVE_FROM_ARRAY, CLEAR_ARRAY, GET_ARRAY_LENGTH,
    CONTAINS_IN_ARRAY, FIND_IN_ARRAY, GET_RANDOM_FROM_ARRAY,
    # Loops
    FOR_EACH_BOOL, FOR_EACH_INT, FOR_EACH_FLOAT, FOR_EACH_STRING,
    FOR_EACH_IMAGE, FOR_EACH_CHARACTER, FOR_EACH_AUDIO,
    # Media
    GET_IMAGE, SET_IMAGE, SET_BACKGROUND_IMAGE,
    GET_AUDIO, SET_AUDIO, PLAY_AUDIO,
    GET_CHARACTER, SET_CHARACTER,
    GET_CHARACTER_VAR, SET_CHARACTER_VAR,
    # Random
    RANDOM_BRANCH,
}

enum VariableType {
    NONE, BOOLEAN, INTEGER, FLOAT, STRING, ENUM,
    IMAGE, AUDIO, CHARACTER,
}

enum AssetType { IMAGE, AUDIO, VIDEO }
enum LoopType { FOR_EACH }
```

**Data classes** (inner classes or separate RefCounted scripts):

- `StoryFlowNode` — id, type, position, data dictionary
- `StoryFlowConnection` — id, source_node, source_handle, target_node, target_handle
- `StoryFlowVariable` — id, name, type, value (StoryFlowVariant), is_array, enum_values, is_input, is_output
- `StoryFlowAsset` — id, type, path, loaded_resource
- `StoryFlowDialogueOption` — id, text, is_visible
- `StoryFlowTextBlock` — id, text
- `StoryFlowDialogueState` — node_id, title, text, image (Texture2D), audio (AudioStream), character (StoryFlowCharacterData), text_blocks[], options[], is_valid, can_advance
- `StoryFlowCharacterData` — name, image (Texture2D), variables (Dictionary)
- `StoryFlowCallFrame` — script_path, return_node_id, saved_variables, saved_flow_stack
- `StoryFlowFlowFrame` — flow_id
- `StoryFlowLoopContext` — node_id, type, current_index

---

### 2. `storyflow_variant.gd` — Type-Safe Variant

Wraps Godot's `Variant` with explicit StoryFlow typing:

```gdscript
class_name StoryFlowVariant extends RefCounted

var _type: int  # VariableType enum
var _value: Variant  # bool, int, float, String, or Array

static func from_bool(v: bool) -> StoryFlowVariant
static func from_int(v: int) -> StoryFlowVariant
static func from_float(v: float) -> StoryFlowVariant
static func from_string(v: String) -> StoryFlowVariant
static func from_array(v: Array) -> StoryFlowVariant

func get_bool() -> bool
func get_int() -> int
func get_float() -> float
func get_string() -> String
func get_array() -> Array
func to_display_string() -> String
```

---

### 3. `storyflow_project.gd` — Project Resource

```gdscript
class_name StoryFlowProject extends Resource

@export var version: String
@export var api_version: String
@export var title: String
@export var description: String
@export var startup_script: String

var scripts: Dictionary          # path → StoryFlowScript
var global_variables: Dictionary # id → StoryFlowVariable
var characters: Dictionary       # normalized_path → StoryFlowCharacter
var global_strings: Dictionary   # "en.key" → "value"
var resolved_assets: Dictionary  # asset_key → Resource (Texture2D, AudioStream, etc.)
```

---

### 4. `storyflow_script.gd` — Script Resource

```gdscript
class_name StoryFlowScript extends Resource

var script_path: String
var nodes: Dictionary             # node_id → StoryFlowNode
var connections: Array            # StoryFlowConnection[]
var variables: Dictionary         # id → StoryFlowVariable
var strings: Dictionary           # "en.key" → "value"
var assets: Dictionary            # id → StoryFlowAsset
var flows: Dictionary             # flow_id → flow definition

# Indices (built after import)
var source_handle_index: Dictionary  # source_handle → connection
var source_node_index: Dictionary    # source_node_id → [connections]
var target_node_index: Dictionary    # target_node_id → [connections]

func build_indices() -> void
func get_start_node() -> StoryFlowNode  # Always node id "0"
```

---

### 5. `storyflow_character.gd` — Character Resource

```gdscript
class_name StoryFlowCharacter extends Resource

@export var character_name: String    # String table key
@export var image_key: String         # Asset key for default portrait
@export var character_path: String    # Normalized path

var variables: Dictionary             # var_name → StoryFlowVariable
var resolved_assets: Dictionary       # asset_key → Texture2D
```

---

### 6. `storyflow_handles.gd` — Handle Utilities

Static utility functions for handle format parsing:

```gdscript
# Handle format: "source-{nodeId}-{suffix}" / "target-{nodeId}-{suffix}"

static func parse_source_handle(handle: String) -> Dictionary:
    # Returns { "node_id": String, "suffix": String }

static func parse_target_handle(handle: String) -> Dictionary

static func make_source_handle(node_id: String, suffix: String = "") -> String
static func make_target_handle(node_id: String, suffix: String = "") -> String

static func is_data_handle(suffix: String) -> bool
    # Checks for "boolean-", "integer-", "float-", "string-", "enum-"

static func get_data_type_from_suffix(suffix: String) -> int  # VariableType
```

---

### 7. `storyflow_evaluator.gd` — Expression Evaluator

Lazy evaluator that reads data from the node graph without advancing execution:

```gdscript
class_name StoryFlowEvaluator extends RefCounted

var _context: StoryFlowExecutionContext
var _evaluation_depth: int = 0
const MAX_EVALUATION_DEPTH = 100

func evaluate_boolean_input(node_id: String, handle_suffix: String) -> bool
func evaluate_boolean_from_node(node_id: String) -> bool

func evaluate_integer_input(node_id: String, handle_suffix: String) -> int
func evaluate_integer_from_node(node_id: String) -> int

func evaluate_float_input(node_id: String, handle_suffix: String) -> float
func evaluate_float_from_node(node_id: String) -> float

func evaluate_string_input(node_id: String, handle_suffix: String) -> String
func evaluate_string_from_node(node_id: String) -> String

func evaluate_enum_input(node_id: String, handle_suffix: String) -> String
func evaluate_enum_from_node(node_id: String) -> String

func evaluate_array_input(node_id: String, handle_suffix: String) -> Array

func evaluate_option_visibility(option: Dictionary) -> bool

func process_boolean_chain(node_id: String) -> void
    # Pre-caches boolean evaluation results before branch
```

Each `evaluate_*_from_node` uses a match statement on node type:
- Logic nodes (And, Or, Not, Equal) → recursive evaluation of inputs
- Arithmetic nodes (Plus, Minus, etc.) → evaluate operands, compute
- Conversion nodes → evaluate input, convert type
- Get* nodes → look up variable value
- Array nodes → evaluate array operations
- Comparison nodes → evaluate operands, compare

Caching: per-node `CachedOutput` in `NodeRuntimeState` to avoid re-evaluation within a single dialogue step.

---

### 8. `storyflow_execution_context.gd` — Per-Component State

```gdscript
class_name StoryFlowExecutionContext extends RefCounted

# Current execution state
var current_script: StoryFlowScript
var current_node_id: String
var is_waiting_for_input: bool = false
var is_executing: bool = false
var is_paused: bool = false
var entering_dialogue_via_edge: bool = false

# Stacks
var call_stack: Array[StoryFlowCallFrame]       # RunScript nesting (max 20)
var flow_call_stack: Array[StoryFlowFlowFrame]  # RunFlow nesting (max 50)
var loop_stack: Array[StoryFlowLoopContext]      # forEach nesting

# Variables
var local_variables: Dictionary          # id → StoryFlowVariable
var local_variable_name_index: Dictionary  # name → id
var global_variable_name_index: Dictionary # name → id

# Current display state
var current_dialogue_state: StoryFlowDialogueState
var persistent_background_image: String

# Recursion protection
var evaluation_depth: int = 0
var processing_depth: int = 0
var node_runtime_states: Dictionary  # node_id → NodeRuntimeState

# Max depths
const MAX_EVALUATION_DEPTH = 100
const MAX_PROCESSING_DEPTH = 1000
const MAX_SCRIPT_DEPTH = 20
const MAX_FLOW_DEPTH = 50
```

**NodeRuntimeState** (inner class):
```gdscript
var cached_output: Variant
var loop_index: int = 0
var loop_array: Array = []
var loop_initialized: bool = false
var output_values: Dictionary
var has_output_values: bool = false
```

---

### 9. `storyflow_component.gd` — Main Runtime Node

The primary developer-facing node. Added as a child of any Node (e.g., CharacterBody3D, NPC).

```gdscript
@tool
class_name StoryFlowComponent extends Node

# === Configuration ===
@export var script_path: String            # Dropdown populated in editor
@export var language_code: String = "en"
@export var dialogue_ui_scene: PackedScene # Auto-instantiates dialogue UI

# === Audio Settings ===
@export_group("Audio")
@export var stop_audio_on_dialogue_end: bool = true
@export var dialogue_audio_bus: StringName = &"Master"
@export var dialogue_volume_db: float = 0.0

# === Signals (equivalent to Unreal delegates) ===
signal dialogue_started()
signal dialogue_updated(state: StoryFlowDialogueState)
signal dialogue_ended()
signal variable_changed(variable: StoryFlowVariable, is_global: bool)
signal script_started(script_path: String)
signal script_ended(script_path: String)
signal error_occurred(message: String)
signal background_image_changed(image_path: String)
signal audio_play_requested(audio_path: String, loop: bool)

# === Control Functions ===
func start_dialogue() -> void
func start_dialogue_with_script(path: String) -> void
func select_option(option_id: String) -> void
func advance_dialogue() -> void
func stop_dialogue() -> void
func pause_dialogue() -> void
func resume_dialogue() -> void

# === State Access ===
func get_current_dialogue() -> StoryFlowDialogueState
func is_dialogue_active() -> bool
func is_waiting_for_input() -> bool
func is_paused() -> bool
func get_manager() -> StoryFlowManager

# === Variable Access (by display name) ===
func get_bool_variable(name: String) -> bool
func set_bool_variable(name: String, value: bool) -> void
func get_int_variable(name: String) -> int
func set_int_variable(name: String, value: int) -> void
func get_float_variable(name: String) -> float
func set_float_variable(name: String, value: float) -> void
func get_string_variable(name: String) -> String
func set_string_variable(name: String, value: String) -> void
func get_enum_variable(name: String) -> String
func set_enum_variable(name: String, value: String) -> void
func get_character_variable(character_path: String, var_name: String) -> Variant
func set_character_variable(character_path: String, var_name: String, value: Variant) -> void
func reset_variables() -> void
func get_localized_string(key: String) -> String

# === Internal ===
var _context: StoryFlowExecutionContext
var _evaluator: StoryFlowEvaluator
var _audio_player: AudioStreamPlayer  # Created dynamically
var _dialogue_ui_instance: Control     # Auto-created from dialogue_ui_scene
```

**Node Processing:**

Internal dispatch table (Dictionary mapping NodeType → Callable):

```gdscript
var _node_handlers: Dictionary = {
    NodeType.START: _handle_start,
    NodeType.END: _handle_end,
    NodeType.BRANCH: _handle_branch,
    NodeType.DIALOGUE: _handle_dialogue,
    NodeType.RUN_SCRIPT: _handle_run_script,
    NodeType.RUN_FLOW: _handle_run_flow,
    NodeType.ENTRY_FLOW: _handle_entry_flow,
    NodeType.SET_BOOL: _handle_set_bool,
    # ... all 85+ node types
}

func _process_node(node_id: String) -> void:
    # Recursion guard, lookup node, dispatch to handler
```

**Critical Behaviors (ported from Unreal):**

1. **Set\* nodes with no outgoing edge:**
   - Check forEach loop → continue iteration
   - Check if came from Dialogue → return to dialogue to re-render

2. **BuildDialogueState order:**
   - Resolve character FIRST
   - Update `current_dialogue_state.character`
   - THEN interpolate text (supports `{varname}`, `{Character.Name}`)

3. **Audio playback:**
   - Fresh entry: play new audio or stop based on `audio_reset`
   - Return from Set*: do NOT restart audio
   - Looping via `AudioStreamPlayer.finished` signal

4. **Live variable interpolation:**
   - On `variable_changed` → rebuild dialogue state → re-emit `dialogue_updated`

---

### 10. `storyflow_manager.gd` — Autoload Singleton

Registered as an autoload in `plugin.cfg` setup instructions (user adds it manually or plugin auto-registers).

```gdscript
class_name StoryFlowManager extends Node

# === Project ===
var project: StoryFlowProject
const DEFAULT_PROJECT_PATH = "res://storyflow/sf_project.tres"

func get_project() -> StoryFlowProject
func set_project(p: StoryFlowProject) -> void
func has_project() -> bool

func get_script(path: String) -> StoryFlowScript
func get_all_script_paths() -> PackedStringArray

# === Global Variables ===
var _global_variables: Dictionary  # id → StoryFlowVariable

func get_global_variables() -> Dictionary
func reset_global_variables() -> void

# === Runtime Characters ===
var _runtime_characters: Dictionary  # normalized_path → character data

func get_runtime_characters() -> Dictionary
func reset_runtime_characters() -> void

# === Once-Only Options ===
var _used_once_only_options: Dictionary  # "NodeId-OptionId" → true

func get_used_once_only_options() -> Dictionary

# === Active Dialogue Tracking ===
var _active_dialogue_count: int = 0

func is_dialogue_active() -> bool
func register_dialogue_start() -> void
func register_dialogue_end() -> void

# === Save / Load ===
func save_to_slot(slot_name: String) -> bool
func load_from_slot(slot_name: String) -> bool
func does_save_exist(slot_name: String) -> bool
func delete_save(slot_name: String) -> void

# === Reset ===
func reset_all_state() -> void
```

**Save file location:** `user://storyflow_saves/{slot_name}.json`

**Save format (JSON):**
```json
{
    "save_version": 1,
    "global_variables": { ... },
    "runtime_characters": { ... },
    "used_once_only_options": [ ... ]
}
```

---

### 11. `storyflow_dialogue_ui.gd` / `.tscn` — Base Dialogue UI

A default Control scene that developers can extend or replace entirely.

```gdscript
class_name StoryFlowDialogueUI extends Control

# Bound component
var _component: StoryFlowComponent

# Node references (override in custom scenes)
@export var title_label: Label
@export var text_label: RichTextLabel
@export var character_name_label: Label
@export var character_portrait: TextureRect
@export var options_container: VBoxContainer
@export var advance_button: Button
@export var option_button_scene: PackedScene

func initialize_with_component(component: StoryFlowComponent) -> void
func _on_dialogue_started() -> void
func _on_dialogue_updated(state: StoryFlowDialogueState) -> void
func _on_dialogue_ended() -> void

# Override points for custom UI
func _build_options(options: Array) -> void
func _display_state(state: StoryFlowDialogueState) -> void
```

Default `.tscn` provides:
- Panel background
- Character portrait (TextureRect)
- Character name (Label)
- Dialogue text (RichTextLabel for BBCode support)
- Options container (VBoxContainer with dynamic buttons)
- Advance button (for narrative-only nodes)
- Fade in/out animations (AnimationPlayer)

---

### 12. `storyflow_import_plugin.gd` — Editor Import

An `EditorImportPlugin` that handles `.storyflow` project files.

```gdscript
class_name StoryFlowImportPlugin extends EditorImportPlugin

func _get_importer_name() -> String: return "storyflow.project"
func _get_visible_name() -> String: return "StoryFlow Project"
func _get_recognized_extensions() -> PackedStringArray: return ["storyflow"]
func _get_save_extension() -> String: return "tres"
func _get_resource_type() -> String: return "Resource"

func _import(source_file, save_path, options, ...) -> Error:
    # 1. Parse .storyflow JSON
    # 2. Walk the build/ directory for scripts, characters, media
    # 3. Create StoryFlowProject + StoryFlowScript + StoryFlowCharacter resources
    # 4. Import images as .import -> CompressedTexture2D
    # 5. Import audio as AudioStreamWAV / AudioStreamMP3
    # 6. Save all resources to res://storyflow/
    # 7. Return OK
```

---

### 13. `storyflow_importer.gd` — JSON Parsing

Core parsing logic, separated from the EditorImportPlugin for reusability:

```gdscript
class_name StoryFlowImporter extends RefCounted

func import_project(build_dir: String, output_dir: String) -> StoryFlowProject
func import_script(json_path: String, output_dir: String) -> StoryFlowScript

# Parsing
func _parse_nodes(json: Dictionary) -> Dictionary
func _parse_connections(json: Array) -> Array
func _parse_variables(json: Array) -> Dictionary
func _parse_strings(json: Dictionary) -> Dictionary
func _parse_assets(json: Array) -> Dictionary
func _parse_characters(json: Dictionary) -> Dictionary
func _parse_text_blocks(json: Array) -> Array
func _parse_choices(json: Array) -> Array
func _parse_variant(json: Variant, type: int) -> StoryFlowVariant

# Asset import
func _import_image(source_path: String, dest_dir: String) -> Texture2D
func _import_audio(source_path: String, dest_dir: String) -> AudioStream

# Character path normalization (CRITICAL)
static func normalize_character_path(path: String) -> String:
    return path.to_lower().replace("/", "\\")
```

---

### 14. `storyflow_editor_dock.gd` — Editor Dock Panel

A custom dock added to the Godot editor for convenient import and live sync:

```
┌─────────────────────────────┐
│  StoryFlow                  │
├─────────────────────────────┤
│  Project: [path]  [Browse]  │
│  Output:  [res://storyflow] │
│  [Import Project]           │
├─────────────────────────────┤
│  Live Sync                  │
│  Host: localhost  Port: 9000│
│  [Connect] [Disconnect]     │
│  Status: ● Disconnected     │
└─────────────────────────────┘
```

---

### 15. `storyflow_websocket_sync.gd` — Live Sync

WebSocket client for real-time sync with StoryFlow Editor:

```gdscript
class_name StoryFlowWebSocketSync extends RefCounted

signal connected()
signal disconnected()
signal sync_complete(project: StoryFlowProject)

var _socket: WebSocketPeer
var _host: String = "localhost"
var _port: int = 9000
var _reconnect_attempts: int = 0
const MAX_RECONNECT_ATTEMPTS = 5

func connect_to_editor(host: String = "localhost", port: int = 9000) -> void
func disconnect_from_editor() -> void
func is_connected() -> bool
func request_sync() -> void
func poll() -> void  # Call from _process
```

---

## Node Type Handling — Complete Map

### Control Flow Nodes

| Node Type | Handler Behavior |
|---|---|
| `START` | Continue via default output edge |
| `END` | Pop call stack (return to caller) or stop dialogue |
| `BRANCH` | Evaluate boolean input → follow `true` or `false` edge |
| `DIALOGUE` | Build dialogue state, emit `dialogue_updated`, wait for input |
| `RUN_SCRIPT` | Push call frame, load new script, start at node "0" |
| `RUN_FLOW` | Find matching EntryFlow, jump (no return) |
| `ENTRY_FLOW` | Continue to next node |

### Variable Nodes

| Node Type | Handler Behavior |
|---|---|
| `GET_*` | No-op (data node, evaluated lazily by evaluator) |
| `SET_*` | Set variable value, handle no-outgoing-edge special case |
| `SWITCH_ON_ENUM` | Route to matching enum value edge |

### Logic / Arithmetic / String Nodes

All are **no-op at execution time** — they are evaluated lazily by `StoryFlowEvaluator` when their output is needed by a Branch, Dialogue interpolation, or another evaluation chain.

### Array Nodes

| Node Type | Handler Behavior |
|---|---|
| `SET_*_ARRAY` | Set/clear entire array variable |
| `ADD_TO_ARRAY` | Add element to array |
| `REMOVE_FROM_ARRAY` | Remove element from array |
| `GET_*_ARRAY`, `FIND_*`, `CONTAINS_*`, `LENGTH_*` | No-op (lazy evaluated) |
| `GET_RANDOM_FROM_ARRAY` | No-op (lazy evaluated, uses RandomNumberGenerator) |

### Loop Nodes

| Node Type | Handler Behavior |
|---|---|
| `FOR_EACH_*` | Initialize loop context, process body |
| (continue) | Increment index, re-process or follow "completed" edge |

### Media Nodes

| Node Type | Handler Behavior |
|---|---|
| `SET_IMAGE` | Store image for next dialogue build |
| `SET_BACKGROUND_IMAGE` | Emit `background_image_changed` signal |
| `SET_AUDIO` | Store audio for next dialogue build |
| `PLAY_AUDIO` | Emit `audio_play_requested` signal |
| `GET_IMAGE/AUDIO` | No-op (lazy evaluated) |
| `SET_CHARACTER` | Store character for next dialogue build |
| `GET_CHARACTER` | No-op (lazy evaluated) |
| `SET_CHARACTER_VAR` | Set character variable, trigger re-render if in dialogue |
| `GET_CHARACTER_VAR` | No-op (lazy evaluated) |

### Random Nodes

| Node Type | Handler Behavior |
|---|---|
| `RANDOM_BRANCH` | Weighted random selection among output edges |

---

## Signal Flow (Developer Usage)

```
Game Code                  StoryFlowComponent              StoryFlowManager
    │                            │                              │
    │  start_dialogue()          │                              │
    │ ──────────────────────►    │                              │
    │                            │  register_dialogue_start()   │
    │                            │ ────────────────────────────►│
    │                            │                              │
    │    dialogue_started ◄───── │                              │
    │                            │                              │
    │   dialogue_updated ◄────── │  (builds dialogue state)     │
    │   (state with text,        │                              │
    │    options, character)      │                              │
    │                            │                              │
    │  select_option("opt1")     │                              │
    │ ──────────────────────►    │                              │
    │                            │  (processes graph nodes)     │
    │                            │                              │
    │   dialogue_updated ◄────── │  (next dialogue node)        │
    │                            │                              │
    │   dialogue_ended ◄──────── │                              │
    │                            │  register_dialogue_end()     │
    │                            │ ────────────────────────────►│
```

---

## Import Workflow

```
StoryFlow Editor
    │
    │  File → Export → JSON
    ▼
build/
├── project.storyflow
├── scripts/
│   ├── main.json
│   └── npcs/elder.json
├── characters.json
└── media/
    ├── images/
    │   └── portrait.png
    └── audio/
        └── greeting.wav

        │
        │  Import via Editor Dock or EditorImportPlugin
        ▼

res://storyflow/
├── sf_project.tres          (StoryFlowProject)
├── scripts/
│   ├── main.tres            (StoryFlowScript)
│   └── npcs/
│       └── elder.tres       (StoryFlowScript)
├── characters/
│   └── elder.tres           (StoryFlowCharacter)
└── media/
    ├── portrait.png.import  (Texture2D)
    └── greeting.wav.import  (AudioStreamWAV)
```

---

## Save/Load System

**What gets saved:**
- Global variables (current values)
- Runtime characters (mutable variable state)
- Used once-only options

**What does NOT get saved:**
- Local variables
- Current dialogue position
- Mid-dialogue state (call stack, loop state)

**Design:** Checkpoint-based saves (between dialogues, not mid-conversation).

**Guard:** `StoryFlowManager.is_dialogue_active()` prevents loading during active dialogue.

**File format:** JSON at `user://storyflow_saves/{slot}.json`

```json
{
    "save_version": 1,
    "global_variables": {
        "var_abc123": { "name": "HasMetElder", "type": "boolean", "value": true }
    },
    "runtime_characters": {
        "npcs\\elder": {
            "variables": {
                "Mood": { "type": "string", "value": "happy" }
            }
        }
    },
    "used_once_only_options": ["5-opt_001", "12-opt_003"]
}
```

---

## Recursion Protection

| Limit | Value | What it guards |
|---|---|---|
| Evaluation depth | 100 | Evaluator recursion (logic/arithmetic chains) |
| Processing depth | 1000 | Node processing recursion (graph traversal) |
| Script call depth | 20 | RunScript nesting |
| Flow call depth | 50 | RunFlow nesting |

All emit `error_occurred` signal and terminate dialogue on breach.

---

## Godot-Specific Considerations

### 1. No UObject System
Godot uses `Resource` for data and `Node` for behavior. All data assets become `Resource` subclasses saved as `.tres` files.

### 2. No GameInstanceSubsystem
Use Godot's **Autoload** system. `StoryFlowManager` is added as an autoload singleton, accessible globally via `StoryFlowManager` (or whatever name the user configures).

### 3. Signal System vs Delegates
Godot signals map directly to Unreal delegates. Signals support typed parameters in Godot 4.x.

### 4. Audio
- `AudioStreamPlayer` for non-positional audio (dialogue)
- `AudioStreamPlayer2D` / `3D` if spatial audio is needed (optional)
- `AudioStreamWAV` for WAV, `AudioStreamMP3` for MP3 (Godot supports MP3 natively unlike Unreal)
- Looping via `AudioStreamPlayer.finished` signal
- Bus routing via `bus` property

### 5. Image Loading
- Import time: Godot handles `.png`/`.jpg` import natively → `CompressedTexture2D`
- Runtime: Images referenced by resource path, loaded via `load()` or `ResourceLoader.load()`

### 6. UI System
- Godot uses `Control` nodes (not UMG widgets)
- `RichTextLabel` supports BBCode for styled dialogue text
- `PackedScene` replaces UWidget class references
- Theme system for consistent styling

### 7. Editor Integration
- `EditorPlugin` for registering import plugins, custom docks, and inspector enhancements
- `EditorImportPlugin` for automatic `.storyflow` file handling
- Custom `@export` property hints for script path dropdown

### 8. File I/O
- `FileAccess` for reading JSON files
- `JSON.parse_string()` for parsing
- `ResourceSaver.save()` for `.tres` output
- `DirAccess` for directory traversal

### 9. Threading
- Node graph execution should happen on the main thread (matches Unreal behavior)
- Import operations can use `Thread` if needed for large projects
- WebSocket polling happens in `_process()`

---

## Implementation Phases

### Phase 1: Core Runtime (MVP)
1. `storyflow_types.gd` — All enums and data classes
2. `storyflow_variant.gd` — Type-safe variant
3. `storyflow_project.gd`, `storyflow_script.gd`, `storyflow_character.gd` — Data resources
4. `storyflow_handles.gd` — Handle parsing
5. `storyflow_importer.gd` — JSON parsing (no editor integration yet, manual import via code)
6. `storyflow_execution_context.gd` — Execution state
7. `storyflow_evaluator.gd` — Expression evaluation (boolean, integer, float, string, enum)
8. `storyflow_component.gd` — Core node processing for:
   - Start, End, Branch, Dialogue
   - Get/Set Bool, Int, Float, String, Enum
   - Boolean logic (And, Or, Not, Equal)
   - Basic arithmetic and string operations
9. `storyflow_manager.gd` — Global state and save/load
10. Basic test scene

**Milestone:** Can import a simple project and run a branching dialogue with variables.

### Phase 2: Full Node Support
1. All arithmetic, comparison, and conversion nodes
2. Array nodes and forEach loops
3. RunScript / RunFlow / EntryFlow (multi-script support)
4. Random branch
5. Media nodes (SetImage, SetBackgroundImage, SetAudio, PlayAudio)
6. Character system (GetCharacter, SetCharacter, Get/SetCharacterVar)
7. SwitchOnEnum
8. Input options (string, int, float, bool, enum inputs on dialogue nodes)

**Milestone:** Feature parity with Unreal plugin's runtime.

### Phase 3: Editor Integration
1. `plugin.cfg` and `storyflow_plugin.gd` — Plugin registration
2. `storyflow_import_plugin.gd` — EditorImportPlugin for `.storyflow` files
3. `storyflow_editor_dock.gd` — Import UI dock panel
4. Custom `@export` property editor for script path dropdown
5. Media asset copying and Godot reimport triggering

**Milestone:** One-click import from StoryFlow Editor export.

### Phase 4: Dialogue UI
1. `storyflow_dialogue_ui.gd` + `.tscn` — Default dialogue scene
2. `storyflow_option_button.tscn` — Reusable option button
3. Character portrait display
4. Typewriter text effect (optional)
5. Theme support for easy reskinning

**Milestone:** Plug-and-play dialogue UI out of the box.

### Phase 5: Live Sync & Polish
1. `storyflow_websocket_sync.gd` — WebSocket client
2. `storyflow_editor_dock.gd` — Live sync UI controls
3. Auto-reimport on sync
4. Error reporting and troubleshooting guide
5. Example scenes
6. Documentation

**Milestone:** Full feature parity with Unreal plugin including Live Sync.

### Phase 6: Stretch Goals
1. C# bindings / wrapper
2. GDExtension (C++) port for performance-critical paths
3. Godot Asset Library submission
4. Localization tooling (string table export/import)
5. Visual debugger (shows current node in editor during play)

---

## API Quick Reference (Developer-Facing)

```gdscript
# === Setup ===
# 1. Enable plugin in Project Settings
# 2. Add StoryFlowManager as Autoload
# 3. Import project via editor dock
# 4. Add StoryFlowComponent as child of any node

# === Basic Usage ===
@onready var story: StoryFlowComponent = $StoryFlowComponent

func _ready():
    story.dialogue_started.connect(_on_dialogue_started)
    story.dialogue_updated.connect(_on_dialogue_updated)
    story.dialogue_ended.connect(_on_dialogue_ended)
    story.error_occurred.connect(_on_error)

func talk():
    story.start_dialogue()

func _on_dialogue_updated(state: StoryFlowDialogueState):
    # Update your UI with state.title, state.text, state.options, etc.
    dialogue_label.text = state.text
    for option in state.options:
        var btn = Button.new()
        btn.text = option.text
        btn.pressed.connect(story.select_option.bind(option.id))
        options_container.add_child(btn)

func _on_dialogue_ended():
    hide_dialogue_ui()

# === Variables ===
story.set_bool_variable("HasMetElder", true)
var mood = story.get_string_variable("Mood")

# === Save/Load ===
StoryFlowManager.save_to_slot("autosave")
StoryFlowManager.load_from_slot("autosave")
```

---

## Testing Strategy

1. **Unit tests** for:
   - `StoryFlowVariant` type conversions
   - `StoryFlowHandles` parsing
   - `StoryFlowImporter` JSON parsing
   - `StoryFlowEvaluator` logic/arithmetic evaluation

2. **Integration tests** for:
   - Full dialogue flow (start → dialogue → option → end)
   - Variable get/set and interpolation
   - RunScript/RunFlow nesting
   - forEach loop execution
   - Save/load round-trip

3. **Test projects:** Import the same test `.storyflow` projects used by the Unreal plugin to ensure identical behavior.

Use GDScript's built-in `assert()` or GUT (Godot Unit Testing) framework.

---

## File Format Compatibility

The Godot plugin consumes the **exact same JSON export** as the Unreal plugin. No changes needed to the StoryFlow Editor's export format. The JSON schema is:

- **Project file** (`.storyflow`): version, apiVersion, metadata, scripts, globalVariables, globalStrings, characters
- **Script files** (`.sfe` / `.json`): nodes, connections, variables, strings, assets, flows
- **Characters** (`characters.json`): character definitions with name, image, variables
- **Media files**: PNG/JPG images, WAV/MP3 audio in `build/media/`

---

## Website Documentation Pages Needed

Following the same pattern as the Unreal plugin docs:

1. `/integrations/godot` — Overview, download, version compatibility
2. `/integrations/godot/docs/installation` — Setup guide
3. `/integrations/godot/docs/quick-start` — End-to-end tutorial
4. `/integrations/godot/docs/storyflow-component` — Component reference
5. `/integrations/godot/docs/displaying-dialogue` — UI building guide
6. `/integrations/godot/docs/handling-choices` — Options and input handling
7. `/integrations/godot/docs/characters` — Character system
8. `/integrations/godot/docs/audio` — Audio playback
9. `/integrations/godot/docs/variables` — Variable types and access
10. `/integrations/godot/docs/save-and-load` — Persistence
11. `/integrations/godot/docs/live-sync` — WebSocket sync
12. `/integrations/godot/docs/images-and-media` — Asset management
13. `/integrations/godot/docs/multiple-scripts` — RunScript/RunFlow
14. `/integrations/godot/docs/api-reference` — Complete API reference
15. `/integrations/godot/docs/troubleshooting` — Error guide
