@tool
extends EditorProperty
## Custom inspector property for StoryFlowComponent.script_path.
## Shows a text field with a dropdown button listing all imported scripts.

const META_PATH := "res://storyflow/storyflow_import_meta.json"

var _line_edit: LineEdit
var _menu_button: MenuButton
var _updating: bool = false
var _script_paths: PackedStringArray = []


func _init() -> void:
	var hbox := HBoxContainer.new()
	add_child(hbox)

	_line_edit = LineEdit.new()
	_line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_line_edit.placeholder_text = "Script path..."
	_line_edit.text_submitted.connect(_on_text_submitted)
	_line_edit.focus_exited.connect(_on_focus_exited)
	hbox.add_child(_line_edit)
	add_focusable(_line_edit)

	_menu_button = MenuButton.new()
	_menu_button.text = "▼"
	_menu_button.flat = true
	_menu_button.custom_minimum_size.x = 28
	_menu_button.tooltip_text = "Select from imported scripts"
	hbox.add_child(_menu_button)

	_menu_button.get_popup().index_pressed.connect(_on_popup_item_selected)
	_menu_button.get_popup().about_to_popup.connect(_refresh_script_list)


func _refresh_script_list() -> void:
	_script_paths.clear()
	var popup := _menu_button.get_popup()
	popup.clear()

	# Read script paths from import metadata
	if FileAccess.file_exists(META_PATH):
		var file := FileAccess.open(META_PATH, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				var data: Dictionary = json.data
				if data.has("script_paths") and data["script_paths"] is Array:
					for p in data["script_paths"]:
						_script_paths.append(str(p))

	_script_paths.sort()

	if _script_paths.is_empty():
		popup.add_item("(No scripts imported)")
		popup.set_item_disabled(0, true)
	else:
		for i in range(_script_paths.size()):
			popup.add_item(_script_paths[i])


func _on_popup_item_selected(index: int) -> void:
	if index < 0 or index >= _script_paths.size():
		return
	var path: String = _script_paths[index]
	_updating = true
	_line_edit.text = path
	_updating = false
	emit_changed(get_edited_property(), path)


func _on_text_submitted(_text: String) -> void:
	if _updating:
		return
	emit_changed(get_edited_property(), _line_edit.text)


func _on_focus_exited() -> void:
	if _updating:
		return
	emit_changed(get_edited_property(), _line_edit.text)


func _update_property() -> void:
	var new_value = get_edited_object()[get_edited_property()]
	var text: String = str(new_value) if new_value else ""
	if text == _line_edit.text:
		return
	_updating = true
	_line_edit.text = text
	_updating = false
