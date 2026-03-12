class_name StoryFlowDialogueState
extends RefCounted

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

## Whether the dialogue can be advanced without selecting an option.
var can_advance: bool = false


func find_option(option_id: String) -> StoryFlowDialogueOption:
	for opt in options:
		if opt.id == option_id:
			return opt
	return null
