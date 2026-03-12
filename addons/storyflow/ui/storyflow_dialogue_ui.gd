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


# =============================================================================
# Display Logic
# =============================================================================

func _display_state(state: StoryFlowDialogueState) -> void:
	# Title
	if title_label:
		title_label.text = state.title
		title_label.visible = state.title != ""

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

	# Options
	_build_options(state.options)

	# Advance button (for narrative-only dialogues)
	if advance_button:
		advance_button.visible = state.can_advance


func _build_options(options: Array[StoryFlowDialogueOption]) -> void:
	_clear_options()
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
