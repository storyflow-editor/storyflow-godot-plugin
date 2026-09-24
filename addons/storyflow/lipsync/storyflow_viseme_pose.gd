@tool
class_name StoryFlowVisemePose
extends Resource

const VisemeMorph = preload("res://addons/storyflow/lipsync/storyflow_viseme_morph.gd")

@export var pose: String = ""
@export var morphs: Array[VisemeMorph] = []
