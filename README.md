# StoryFlow for Godot

Runtime plugin for [StoryFlow Editor](https://storyflow-editor.com) - a visual node editor for creating interactive stories and dialogue systems.

## Features

- 160+ node types - dialogue, branching, variables, arrays, characters, audio, images
- Native GDScript - no C# or external dependencies required
- Built-in dialogue UI with auto-fallback when no custom UI assigned
- Live text interpolation - `{varname}`, `{Character.Name}`
- RunScript / RunFlow - nested scripts with parameters, outputs, and exit flows
- ForEach loops across all array types
- Audio advance-on-end with optional skip
- Character variables with built-in Name/Image field support
- Save/Load with slot-based persistence
- WebSocket Live Sync with auto-reconnect

## Requirements

- Godot 4.3+
- StoryFlow Editor (for creating and exporting projects)

## Installation

1. Copy the `addons/storyflow/` folder into your Godot project's `addons/` directory
2. Enable the plugin in **Project > Project Settings > Plugins**
3. The `StoryFlowRuntime` autoload is registered automatically

## Quick Start

1. **Sync from the editor** - open the **StoryFlow** dock, click **Connect**, then **Sync**
2. **Add a StoryFlowComponent** node to your scene
3. **Call `start_dialogue()`** to begin execution:

```gdscript
@onready var storyflow: StoryFlowComponent = $StoryFlowComponent

func _ready() -> void:
    storyflow.dialogue_updated.connect(_on_dialogue_updated)
    storyflow.dialogue_ended.connect(_on_dialogue_ended)
    storyflow.start_dialogue()

func _on_dialogue_updated(state: StoryFlowDialogueState) -> void:
    print(state.text)

func _on_dialogue_ended() -> void:
    print("Dialogue ended")
```

A built-in dialogue UI is included and used by default.

## Signals

| Signal | Description |
|---|---|
| `dialogue_started()` | Dialogue execution began |
| `dialogue_updated(state: StoryFlowDialogueState)` | New dialogue node reached - update your UI |
| `dialogue_ended()` | Dialogue execution finished |
| `variable_changed(info: StoryFlowVariableChangeInfo)` | A variable was modified at runtime |
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

## Save & Load

```gdscript
var manager = get_node("/root/StoryFlowRuntime")
manager.save_to_slot("slot1")
manager.load_from_slot("slot1")
```

## Live Sync

The plugin connects to the StoryFlow Editor over WebSocket for live project syncing. Use the **StoryFlow** dock:

- **Connect** - establishes WebSocket connection (default: `localhost:9000`)
- **Sync** - pulls the latest project data and imports it
- Syncing also happens automatically when you save in the StoryFlow Editor

## Documentation

Full documentation at [storyflow-editor.com/integrations/godot](https://storyflow-editor.com/integrations/godot).

## Contributing

Contributions are welcome! Please read the guidelines below before submitting.

### Branch Structure

- **`main`** - latest stable release. This is what users install.
- **`dev`** - active development. All changes go here first.

### How to Contribute

1. Fork this repository
2. Create a feature branch from `dev` (`git checkout -b my-feature dev`)
3. Make your changes and commit
4. Open a Pull Request targeting the `dev` branch
5. We'll review and merge when ready

Please open an [issue](https://github.com/StoryFlowEditor/storyflow-godot/issues) first for large changes so we can discuss the approach.

## Changelog

See the full version history at [storyflow-editor.com/integrations/godot/changelog](https://storyflow-editor.com/integrations/godot/changelog/).

## License

[MIT](LICENSE)
