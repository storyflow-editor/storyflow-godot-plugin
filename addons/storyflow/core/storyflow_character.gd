class_name StoryFlowCharacter
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowVariant = preload("res://addons/storyflow/core/storyflow_variant.gd")

## String table key for display name
var character_name: String = ""

## Asset key for default portrait image
var image_key: String = ""

## Normalized character path (for lookup)
var character_path: String = ""

## Character-specific variables: var_name → { "name", "type", "value" (StoryFlowVariant) }
var variables: Dictionary = {}

## Resolved assets: asset_key → Resource (Texture2D)
var resolved_assets: Dictionary = {}


## CRITICAL: normalize character paths consistently for storage and lookup
static func normalize_path(path: String) -> String:
	return path.to_lower().replace("/", "\\")


# =============================================================================
# P4 Character Id Resolution (characters engine contract §3/§4)
# =============================================================================
#
# This file is the home for the whole character-identity vocabulary: normalize_path above
# owns the path regime, the resolver below owns the id regime, and the builtin-token
# predicates own the reserved variable ids — one place, matching the house pattern of
# static helpers on the domain class (StoryFlowHandles, StoryFlowDataAssetStore).
#
# THE CASE CONTRAST (the Unreal F3 lesson): character FILE ids are CASE-SENSITIVE — the
# da_ shape test and the bridge lookup below match exactly — while the builtin variable
# ALIASES are case-insensitive on the lanes whose builtin arms were already
# case-insensitive pre-P4. Ids identify, aliases address; only the second forgives case.

## The reserved builtin variable ids (contract-reserved per V2 §8; the editor's locked
## cf_ rows). FIRST TIER of the A2(a) two-tier design: [method is_name_token] /
## [method is_image_token] fold these into the existing case-insensitive Name/Image arms
## (evaluator builtins, the node write arms, public get_character_variable, the DA-surface
## character branch, the interpolation name arms). SECOND TIER: lanes with NO builtin arm
## and a case-sensitive dict (public set_character_variable) divert ONLY these exact
## spellings, so the native spellings stay byte-untouched there.
const CF_NAME_ID := "cf_name"
const CF_IMAGE_ID := "cf_image"


## First-tier predicate: does [param variable_name] address the builtin Name field?
## Case-insensitive on both spellings — see the case-contrast note above.
static func is_name_token(variable_name: String) -> bool:
	var lower := variable_name.to_lower()
	return lower == "name" or lower == CF_NAME_ID


## First-tier predicate: does [param variable_name] address the builtin Image field?
static func is_image_token(variable_name: String) -> bool:
	var lower := variable_name.to_lower()
	return lower == "image" or lower == CF_IMAGE_ID


## THE ONE RESOLUTION POINT for a single character reference value, id or path.
##
## The ladder (characters engine contract §3):
##   id-shaped (case-sensitive begins_with "da_"):
##     bridge hit + record loaded    -> the record key, VERBATIM (already in normalized
##                                      form by the wire's byte-identity guarantee, so a
##                                      caller's own normalize_path is a no-op on it)
##     bridge hit + record missing   -> warn-once "unloaded" -> "" (a whole miss; only
##                                      reachable via ghost index entries — this engine's
##                                      save load MERGES and never removes a character)
##     no bridge entry               -> warn-once "dangling" -> ""
##   non-id: returned VERBATIM. The call site's own normalize_path (direct, or inside
##   get_runtime_character) then runs exactly as pre-P4 — deliberately NOT normalized
##   here, so every path-lane trace and warn keeps its authored spelling byte-identical.
##
## LATCH THREADING: [param warn_owner] is the OBJECT owning the warn-once latch — the
## execution context for NODE lanes (should_warn_character_id, re-armed per run) or the
## manager for HOST lanes (should_warn_character_id_access, re-armed on set_project /
## reset_all_state). The lane a call joins is decided by the object handed over, never by
## captured state — GDScript lambdas capture by value, so a closed-over Dictionary would
## silently fork the latch.
static func resolve_character_key(bridge: Dictionary, characters: Dictionary, id_or_path: String, warn_owner: Object) -> String:
	if not id_or_path.begins_with("da_"):
		return id_or_path
	if not bridge.has(id_or_path):
		if _claim_id_warn(warn_owner, id_or_path, "dangling"):
			push_warning("StoryFlow: Character id '%s' has no entry in this build's character index - the reference does not resolve" % id_or_path)
		return ""
	var record_key: String = bridge[id_or_path]
	if not characters.has(record_key):
		if _claim_id_warn(warn_owner, id_or_path, "unloaded"):
			push_warning("StoryFlow: Character id '%s' maps to record '%s', which is not among the loaded characters - the reference does not resolve" % [id_or_path, record_key])
		return ""
	return record_key


## The two-field pick for a node carrying both wire fields: the id field resolves through
## [method resolve_character_key] when it is id-shaped, and EVERY fall-back — id absent,
## id malformed, id dangling or unloaded (each warned once there) — returns [param path]
## VERBATIM, so the pre-P4 path lane behaves byte-identically, warn spellings included.
## Only id-shaped inputs ever enter the latched lanes.
static func resolve_character_ref(bridge: Dictionary, characters: Dictionary, id: String, path: String, warn_owner: Object) -> String:
	if id.begins_with("da_"):
		var record_key := resolve_character_key(bridge, characters, id, warn_owner)
		if not record_key.is_empty():
			return record_key
	return path


## Claim the warn-once latch on [param warn_owner] for one (id, reason) pair, dispatching
## to whichever latch pair the owner carries: the context's node-lane pair or the
## manager's host-lane pair. A node-lane warn never consumes the host-lane latch (and vice
## versa) — the two owners hold independent state on purpose.
##
## FAIL-OPEN, like _warn_data_asset_once's no-manager arm: an owner carrying no latch pair
## (or no owner at all) claims TRUE on every call, so the caller still warns — unlatched.
## A lane wired to the wrong object floods rather than losing its warnings invisibly, and
## a flood is diagnosable where silence is not.
static func _claim_id_warn(warn_owner: Object, id: String, reason: String) -> bool:
	if warn_owner != null:
		if warn_owner.has_method("should_warn_character_id"):
			return warn_owner.should_warn_character_id(id, reason)
		if warn_owner.has_method("should_warn_character_id_access"):
			return warn_owner.should_warn_character_id_access(id, reason)
	return true


func duplicate_character() -> StoryFlowCharacter:
	var c := new()
	c.character_name = character_name
	c.image_key = image_key
	c.character_path = character_path
	c.resolved_assets = resolved_assets.duplicate()
	# Deep copy variables
	for key in variables:
		var v: Dictionary = variables[key]
		var dup := v.duplicate()
		if dup.has("value") and dup["value"] is StoryFlowVariant:
			dup["value"] = dup["value"].duplicate_variant()
		c.variables[key] = dup
	return c
