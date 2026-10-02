class_name StoryFlowProject
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowCharacter = preload("res://addons/storyflow/core/storyflow_character.gd")
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")

const DEFAULT_MAX_SCRIPT_NESTING := 20

var version: String = ""
var api_version: String = ""
var title: String = ""
var description: String = ""
var startup_script: String = ""
## Maximum simultaneous runScript calls, excluding the initial script.
var max_script_nesting: int = DEFAULT_MAX_SCRIPT_NESTING

## script_path → StoryFlowScript
var scripts: Dictionary = {}

## id → { "id", "name", "type", "value", "is_array", "enum_values", "is_input", "is_output" }
var global_variables: Dictionary = {}

## normalized_path → StoryFlowCharacter
var characters: Dictionary = {}

## Character FILE id (da_<32 hex>) → characters key, from character-index.json (characters
## engine contract §3). Values are stored VERBATIM: the wire ships the exporter's
## lowercase-backslash record keys, which are byte-identical to what
## StoryFlowCharacter.normalize_path produces - so normalize_path applied to a value would be
## a no-op by construction, and no normalization pass exists at import or lookup. Empty for a
## pre-P4 export (no index file): everything resolves by path.
var character_id_index: Dictionary = {}

## asset_id → raw .sfd definition, as parsed from data-assets.json (engine contract 2.1):
## { "id", "name", "parent", "variables": Array[declaration], "raw_overrides": { varId → raw JSON } }
##
## Overrides stay RAW here: typing one needs the declaration that owns its id, which may live
## on an ancestor this table has not reached yet, so StoryFlowDataAssetStore.build_seed types
## them in a second pass once every level is present.
var data_assets: Dictionary = {}
## data-assets.json localizationVersion. Legacy exports localize declarations only.
var data_asset_localization_version: int = 1

## "lang.key" → "value"
var global_strings: Dictionary = {}

## THE TRANSLATIONS SIDECAR as imported (localization spec §9), the raw product of
## localization.json. StoryFlowManager installs these four onto its own StoryFlowLocalization -
## the object every runtime lane holds by reference - and nothing reads them from here at runtime.
##
## THE FILE-PRESENCE MARKER: true when a localization.json sat beside the artifacts. An absent
## sidecar and a sidecar carrying no rows are the same empty Dictionary once parsed, and only one
## of them is a pre-localization export, so the branch is this bool and never a key count.
var has_localization: bool = false

## The language the documents are authored in, and therefore the language [member global_strings]
## and every script's own strings block are keyed by. "en" without a sidecar.
var source_language: String = "en"

## TARGET languages as `[{ "code", "name" }]` in the author's registry order. Never the source
## language, which has no table of its own.
var languages: Array = []

## `language code` → that language's FULL, PRE-RESOLVED table (`string id` → text). Empty without
## a sidecar.
var language_strings: Dictionary = {}

## asset_key → Resource (Texture2D, AudioStream, etc.)
var resolved_assets: Dictionary = {}


## Project metadata accepts only finite integer numbers in the supported range.
## Missing or malformed settings from older exports use the original limit.
static func normalize_max_script_nesting(value: Variant) -> int:
	if not (value is int or value is float):
		return DEFAULT_MAX_SCRIPT_NESTING
	if not is_finite(value) or value < 1 or value > 100 or value != floor(value):
		return DEFAULT_MAX_SCRIPT_NESTING
	return int(value)


func get_storyflow_script(path: String) -> StoryFlowScript:
	return scripts.get(path, null)


func get_all_script_paths() -> PackedStringArray:
	return PackedStringArray(scripts.keys())


## A RAW, EXACT-KEY probe into this project's own globals: it builds `language.key` and no
## language tier runs. It is NOT the localized door - StoryFlowLocalization.look_up is, and it
## owns the whole ladder (spec §9). A caller that builds its own prefixed key here bypasses the
## translation overlay and the source-table fall-through, which is the silent defect the shared
## ladder exists to make impossible. Kept as public API for hosts that genuinely want one table
## row; nothing inside this plugin resolves strings through it.
func get_localized_string(key: String, language: String = "en") -> String:
	var full_key := language + "." + key
	return global_strings.get(full_key, key)


func find_character(character_path: String) -> StoryFlowCharacter:
	var normalized := StoryFlowCharacter.normalize_path(character_path)
	return characters.get(normalized, null)
