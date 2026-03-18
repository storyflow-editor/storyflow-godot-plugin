# StoryFlow Plugin for Godot

Runtime plugin for [StoryFlow Editor](https://storyflow-editor.com) — a visual node editor for creating interactive stories and dialogue systems.

## Requirements

- Godot 4.3+
- StoryFlow Editor (for creating and exporting projects)

## Installation

1. Copy the `addons/storyflow/` folder into your Godot project's `addons/` directory
2. Enable the plugin in **Project > Project Settings > Plugins**
3. The `StoryFlowRuntime` autoload is registered automatically

## Quick Start

1. **Sync from the editor**: Open the **StoryFlow** dock (right panel), enter host/port, and click **Connect**. Click **Sync** to pull your project.
2. **Add a StoryFlowComponent** node to your scene
3. Set the **Script Path** property (e.g. `scripts/main_menu`)
4. Call `start_dialogue()` to begin execution

```gdscript
@onready var storyflow: StoryFlowComponent = $StoryFlowComponent

func _ready() -> void:
    storyflow.dialogue_started.connect(_on_dialogue_started)
    storyflow.dialogue_updated.connect(_on_dialogue_updated)
    storyflow.dialogue_ended.connect(_on_dialogue_ended)
    storyflow.start_dialogue()

func _on_dialogue_started() -> void:
    print("Dialogue started")

func _on_dialogue_updated(state: StoryFlowDialogueState) -> void:
    print(state.text)

func _on_dialogue_ended() -> void:
    print("Dialogue ended")
```

A built-in dialogue UI is included and used by default. To use your own, set the **Dialogue UI Scene** property on the component, or connect to the signals directly.

## Signals

| Signal | Description |
|---|---|
| `dialogue_started()` | Dialogue execution began |
| `dialogue_updated(state: StoryFlowDialogueState)` | New dialogue node reached — update your UI |
| `dialogue_ended()` | Dialogue execution finished |
| `variable_changed(info: StoryFlowVariableChangeInfo)` | A variable was modified at runtime |
| `script_started(path: String)` | Entered a new script via runScript |
| `script_ended(path: String)` | Returned from a runScript call |
| `background_image_changed(path: String)` | Background image set/cleared |
| `error_occurred(message: String)` | Runtime error |

## Player Choices

```gdscript
func _on_dialogue_updated(state: StoryFlowDialogueState) -> void:
    for option in state.options:
        print("%s: %s" % [option.id, option.text])

# When the player picks an option:
storyflow.select_option(option_id)

# For dialogue with no choices (narrative text):
if state.can_advance:
    storyflow.advance_dialogue()
```

## Save / Load

```gdscript
# Save
var manager = get_node("/root/StoryFlowRuntime")
manager.save_to_slot("slot1")

# Load
manager.load_from_slot("slot1")

# Other
manager.does_save_exist("slot1")  # -> bool
manager.delete_save("slot1")
manager.list_save_slots()         # -> PackedStringArray
```

## Live Sync

The plugin connects to the StoryFlow Editor over WebSocket for live project syncing. Use the **StoryFlow** dock in the editor or the toolbar button:

- **Connect** — establishes WebSocket connection (default: `localhost:9000`)
- **Sync** — pulls the latest project data and imports it
- Syncing also happens automatically when you save in the StoryFlow Editor

## Manual Import

If you prefer not to use live sync, you can import from a build directory:

1. In the StoryFlow Editor, export your project (creates a `build/` folder)
2. In the **StoryFlow** dock, set **Build Dir** to the `build/` folder path
3. Click **Import Project**

## Features

- 160+ node types — dialogue, branching, variables, arrays, characters, audio, images
- Built-in dialogue UI with auto-fallback when no custom UI assigned
- Live text interpolation — `{varname}`, `{Character.Name}`
- RunScript / RunFlow — nested scripts with parameters, outputs, and exit flows
- ForEach loops across all array types
- Audio advance-on-end with optional skip
- Character variables with built-in Name/Image field support
- Save/Load with slot-based persistence
- WebSocket Live Sync with auto-reconnect
- Toolbar button for quick Connect/Sync

## Documentation

Full documentation at [storyflow-editor.com/integrations/godot](https://storyflow-editor.com/integrations/godot).

## License

[MIT](LICENSE)
