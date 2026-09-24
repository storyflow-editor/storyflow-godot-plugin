@tool
class_name StoryFlowVisemeMap
extends Resource

const VisemeTable = preload("res://addons/storyflow/lipsync/storyflow_viseme_table.gd")
const VisemePose = preload("res://addons/storyflow/lipsync/storyflow_viseme_pose.gd")
const VisemeMorph = preload("res://addons/storyflow/lipsync/storyflow_viseme_morph.gd")

enum NameStyle {EXACT, MESH_BLENDS_PREFIX}

@export var name_style: NameStyle = NameStyle.EXACT
@export var poses: Array[VisemePose] = []:
	set(value):
		poses = value
		_validated = false
@export var reset_to_builtin: bool = false:
	set(value):
		if value:
			reset_to_default()
		reset_to_builtin = false

var _validated := false


func to_table() -> Dictionary:
	if poses.is_empty():
		return VisemeTable.default_table()
	var table: Dictionary = {}
	for entry in poses:
		if entry == null or entry.pose.is_empty():
			continue
		var morphs_by_name: Dictionary = {}
		for morph in entry.morphs:
			if morph == null or morph.name.is_empty():
				continue
			morphs_by_name[morph.name] = morph.weight
		table[entry.pose] = morphs_by_name
	if not table.has("rest"):
		table["rest"] = {}
	_validate_once(table)
	return table


func reset_to_default() -> void:
	var entries: Array[VisemePose] = []
	var table: Dictionary = VisemeTable.default_table()
	for pose_name in VisemeTable.POSE_NAMES:
		var entry: VisemePose = VisemePose.new()
		entry.pose = pose_name
		var shapes: Dictionary = table[pose_name]
		for morph_name in shapes:
			var morph: VisemeMorph = VisemeMorph.new()
			morph.name = morph_name
			morph.weight = shapes[morph_name]
			entry.morphs.append(morph)
		entries.append(entry)
	poses = entries
	_validated = false
	emit_changed()


func _validate_once(table: Dictionary) -> void:
	if _validated:
		return
	_validated = true
	var unknown: Array[String] = []
	for pose_name in table:
		if not VisemeTable.POSE_NAMES.has(pose_name):
			unknown.append(pose_name)
	if not unknown.is_empty():
		push_warning("StoryFlow Editor viseme map has poses speech never reaches: %s" % ", ".join(unknown))
	var missing: Array[String] = []
	for pose_name in VisemeTable.AXIS:
		if not table.has(pose_name):
			missing.append(pose_name)
	if not missing.is_empty():
		push_warning("StoryFlow Editor viseme map is missing vowel axis poses: %s" % ", ".join(missing))
