class_name StoryFlowDialogueUI
extends Control

# =============================================================================
# Node References (assign in editor or override in subclass)
# =============================================================================

@onready var title_label: Label = %TitleLabel
@onready var text_label: RichTextLabel = %TextLabel
@onready var character_name_label: Label = %CharacterNameLabel
@onready var character_portrait: TextureRect = %CharacterPortrait
@onready var options_container: VBoxContainer = %OptionsContainer
@onready var advance_button: Button = %AdvanceButton
@onready var background_image: TextureRect = %BackgroundImage

## Optional custom button scene for options. Falls back to plain Button if null.
@export var option_button_scene: PackedScene

var _component: StoryFlowComponent = null

# =============================================================================
# Initialization
# =============================================================================

func initialize_with_component(component: StoryFlowComponent) -> void:
	_component = component
	_component.dialogue_started.connect(_on_dialogue_started)
	_component.dialogue_updated.connect(_on_dialogue_updated)
	_component.dialogue_ended.connect(_on_dialogue_ended)
	_component.background_image_changed.connect(_on_background_image_changed)


func _ready() -> void:
	visible = false
	if advance_button:
		advance_button.pressed.connect(_on_advance_pressed)


# =============================================================================
# Event Handlers
# =============================================================================

func _on_dialogue_started() -> void:
	visible = true


func _on_dialogue_updated(state: StoryFlowDialogueState) -> void:
	_display_state(state)


func _on_dialogue_ended() -> void:
	visible = false
	_clear_options()
	if background_image:
		background_image.texture = null
		background_image.visible = false


func _on_background_image_changed(image_path: String) -> void:
	if not background_image:
		return
	if image_path.is_empty():
		background_image.texture = null
		background_image.visible = false
		return

	# Try to resolve the image from the dialogue state or load directly
	var tex: Texture2D = null
	if _component:
		var state := _component.get_current_dialogue()
		if state and state.image:
			tex = state.image
	if not tex and not image_path.is_empty():
		# Try loading from resolved assets or as a resource path
		if ResourceLoader.exists(image_path):
			var res = ResourceLoader.load(image_path)
			if res is Texture2D:
				tex = res
	background_image.texture = tex
	background_image.visible = tex != null


# =============================================================================
# Display Logic
# =============================================================================

func _display_state(state: StoryFlowDialogueState) -> void:
	# Title (hidden by default - override in subclass if needed)
	if title_label:
		title_label.visible = false

	# Dialogue text
	if text_label:
		text_label.text = state.text

	# Character
	if character_name_label:
		var char_name: String = state.character.name if state.character else ""
		character_name_label.text = char_name
		character_name_label.visible = char_name != ""

	if character_portrait:
		var portrait: Texture2D = state.character.image if state.character else null
		character_portrait.texture = portrait
		character_portrait.visible = portrait != null

	# Background image from dialogue node (persists, resets, or changes per node)
	if background_image:
		background_image.texture = state.image
		background_image.visible = state.image != null

	# Clear previous options/text blocks, then rebuild
	_clear_options()

	# Text blocks (non-interactive text displayed before options)
	_build_text_blocks(state.text_blocks)

	# Options
	_build_options(state.options)

	# Advance button (for narrative-only dialogues)
	if advance_button:
		if state.audio_advance_on_end and not state.audio_allow_skip:
			# Audio will auto-advance, skip not allowed — hide button
			advance_button.visible = false
		elif state.audio_advance_on_end and state.audio_allow_skip:
			# Audio will auto-advance but skip is allowed — show "Skip" button
			advance_button.visible = true
			advance_button.text = "Skip"
		else:
			advance_button.visible = state.can_advance
			advance_button.text = "Continue"


func _build_text_blocks(text_blocks: Array[StoryFlowTextBlock]) -> void:
	if not options_container:
		return
	for tb in text_blocks:
		var lbl := Label.new()
		lbl.text = tb.text
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		options_container.add_child(lbl)


func _build_options(options: Array[StoryFlowDialogueOption]) -> void:
	if not options_container:
		return

	for option in options:
		if option_button_scene:
			var btn: Button = option_button_scene.instantiate()
			btn.text = option.text
			btn.pressed.connect(_on_option_pressed.bind(option.id))
			options_container.add_child(btn)
		else:
			var btn := Button.new()
			btn.text = option.text
			btn.pressed.connect(_on_option_pressed.bind(option.id))
			options_container.add_child(btn)


func _clear_options() -> void:
	if options_container:
		for child in options_container.get_children():
			child.queue_free()


# =============================================================================
# Input Handlers
# =============================================================================

func _on_option_pressed(option_id: String) -> void:
	if _component:
		_component.select_option(option_id)


func _on_advance_pressed() -> void:
	if _component:
		_component.advance_dialogue()


# =============================================================================
# Public Helpers
# =============================================================================

func select_option(option_id: String) -> void:
	if _component:
		_component.select_option(option_id)


func advance_dialogue() -> void:
	if _component:
		_component.advance_dialogue()


func get_current_dialogue() -> StoryFlowDialogueState:
	if _component:
		return _component.get_current_dialogue()
	return null


func is_dialogue_active() -> bool:
	if _component:
		return _component.is_dialogue_active()
	return false


func get_localized_string(key: String) -> String:
	if _component:
		return _component.get_localized_string(key)
	return key
