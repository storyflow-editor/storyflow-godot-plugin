class_name StoryFlowDialogueState
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacterData = preload("res://addons/storyflow/core/storyflow_character_data.gd")
const StoryFlowDialogueOption = preload("res://addons/storyflow/core/storyflow_dialogue_option.gd")
const StoryFlowTextBlock = preload("res://addons/storyflow/core/storyflow_text_block.gd")

## Whether this state represents a valid dialogue node.
var is_valid: bool = false

## The ID of the dialogue node producing this state.
var node_id: String = ""

## Dialogue title (already interpolated).
var title: String = ""

## Main dialogue text (already interpolated).
var text: String = ""

## Character data for this dialogue line.
var character: StoryFlowCharacterData = null

## Resolved dialogue image, or null.
var image: Texture2D = null

## Asset key for the image (internal use for persistence tracking).
var image_key: String = ""

## Resolved dialogue audio, or null.
var audio: AudioStream = null

## Asset key for the audio (internal use for playback logic).
var audio_key: String = ""

## Visible dialogue options the player can choose from.
var options: Array[StoryFlowDialogueOption] = []

## Non-interactive text blocks.
var text_blocks: Array[StoryFlowTextBlock] = []

## Presentation tags authored on this dialogue node, in authored order.
## Empty when the node has no tags.
var tags: Array[String] = []

## Whether the dialogue can be advanced without selecting an option.
var can_advance: bool = false

## Whether dialogue will auto-advance after audio finishes playing.
var audio_advance_on_end: bool = false

## Whether player can skip audio and advance early (only when audio_advance_on_end is true).
var audio_allow_skip: bool = false


func find_option(option_id: String) -> StoryFlowDialogueOption:
	for opt in options:
		if opt.id == option_id:
			return opt
	return null
