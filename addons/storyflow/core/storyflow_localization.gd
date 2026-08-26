class_name StoryFlowLocalization
extends RefCounted

# Preloaded by path so parsing never depends on the global class name cache,
# which can be stale or mid-rewrite when the game launches (godotengine/godot#75388).
const StoryFlowScript = preload("res://addons/storyflow/core/storyflow_script.gd")

## The translations sidecar (localization spec §9) as a running game holds it: the imported
## per-language tables, the language registry a picker draws, and the language the PLAYER is
## currently reading in.
##
## ONE OBJECT, OWNED BY THE MANAGER, MUTATED IN PLACE FOREVER - never rebound - for exactly the
## reason the .sfd seed/overlay and the character id bridge are: a running dialogue's execution
## context holds it by reference from dialogue start, so rebinding on a project change or a reset
## would strand that dialogue on the pre-change object and split the game into two languages.
## [method install_from_project] therefore clears and refills rather than assigning fresh
## containers.
##
## THE TABLES ARE FULL AND PRE-RESOLVED. Every §7 fallback was applied at export: an OUTDATED row
## carries the OLD translation (user ruling 2), an UNTRANSLATED or CLEARED one carries the source
## text, an ORPHAN has no row at all. Nothing in this file computes a status, compares a hash or
## holds any rule beyond the ladder in [method look_up] - a plugin that recomputes status
## diverges from the other three runtimes.
##
## THE ID SET IS THE SHIPPED SET: the ids that KEYED an artifact this export wrote. `.sfui` widget
## and dropdown strings have NO rows here and never will - `.sfui` documents do not reach a plugin
## at all and their text localizes in the HTML lane. Their absence is the contract, not a missing
## feature; never infer a bug from it.

## THE FILE-PRESENCE MARKER (§9): true when the imported build carried a localization.json beside
## its artifacts.
##
## A BOOL AND NOT AN "ARE THERE ANY TABLES" TEST, ON PURPOSE. An absent sidecar and a sidecar
## carrying no rows are the same empty Dictionary once they are in GDScript, and only one of them
## is a pre-localization export: an author who registered a language and translated nothing still
## ships FULL tables of source text, and that IS a localized project. False here means source-only
## and ZERO behavior change - every lookup falls straight through to the artifact tables it always
## used.
var has_localization: bool = false

## The language the documents are AUTHORED in, and therefore the language the artifacts' own
## `strings` blocks are keyed by - the second tier of [method look_up]. "en" without a sidecar,
## which is exactly what every pre-localization export's strings block carries.
var source_language: String = "en"

## The project's TARGET languages as `[{ "code", "name" }]`, in the author's registry ORDER (the
## order a picker draws). Never includes the source language, which has no table of its own.
var languages: Array = []

## `language code` → that language's FULL, PRE-RESOLVED table (`string id` → text), straight from
## the sidecar. Empty for a project with no localization.json.
var tables: Dictionary = {}

## The language every StoryFlow string is currently read in - the PLAYER'S choice, not project
## content. "en" before a project is loaded, which is what every pre-localization export's strings
## are keyed by; [method install_from_project] then points it at the project's source language
## unless the player already chose a language the new project also carries.
##
## Written ONLY through StoryFlowManager.set_language and this file's install - one resolve point,
## so an unregistered code can never reach it.
var active_language: String = "en"


# =============================================================================
# Installation
# =============================================================================

## Install one imported project's localization block, replacing whatever was here.
##
## REPLACED, NEVER APPENDED TO, and all four move TOGETHER: a re-import of a build that dropped
## its sidecar must leave a source-only game rather than a stale claim to be localized, and a
## second import inside one session must not stack a second copy of every row on top of the first.
##
## THE PLAYER'S CHOICE SURVIVES a re-set of a project that still carries it (the HTML runtime's
## first-wins posture: re-installing content mid-game must not undo a choice). A project that does
## not carry the current code snaps to that project's source language, so a game can never be left
## reading a language nothing ships. For a project with no sidecar the only code that resolves is
## its source language, so this is "en" -> "en" and changes nothing.
func install_from_project(project) -> void:
	has_localization = bool(project.has_localization) if project != null else false
	source_language = str(project.source_language) if project != null else "en"
	if source_language.is_empty():
		source_language = "en"

	languages.clear()
	tables.clear()
	if project != null:
		for entry in project.languages:
			languages.append({"code": str(entry.get("code", "")), "name": str(entry.get("name", ""))})
		# The per-language tables are SHARED with the project rather than copied: nothing anywhere
		# writes into them (the whole design is read-only, pre-resolved tables), and the outer
		# clear() above drops only these references, never the project's own data.
		for code in project.language_strings:
			tables[str(code)] = project.language_strings[code]

	var carried := resolve_code(active_language)
	active_language = carried if not carried.is_empty() else source_language


# =============================================================================
# Language registry
# =============================================================================

## The code this project actually carries that matches [param code], or "" when it carries none.
##
## Case-INSENSITIVE with the REGISTERED casing winning, matching the HTML runtime's
## resolveLanguage and the store's own rule that a code IS a file name: "ES" and "es" are one
## language, and the canonical form is the one the tables are keyed by. The SOURCE language
## matches too - running in the authored language is a legitimate choice, it simply has no table
## of its own. A project with no sidecar therefore matches its source language and nothing else.
##
## THE ONE RESOLVE POINT, used by set_language AND by the install above, so the two can never
## disagree about which codes exist.
func resolve_code(code: String) -> String:
	if code.is_empty():
		return ""
	if not source_language.is_empty() and source_language.nocasecmp_to(code) == 0:
		return source_language
	for entry in languages:
		var registered := str(entry.get("code", ""))
		if not registered.is_empty() and registered.nocasecmp_to(code) == 0:
			return registered
	return ""


## Every language the player can be switched to: the SOURCE language first, then the author's
## registry order - the list a game's own language picker draws, as `[{ "code", "name" }]`.
##
## The source row's name is its code: the registry stores a display label for TARGET languages
## only, because the source language's text lives in the documents themselves. EMPTY for a project
## with no localization sidecar, which is how a game asks "is this project localized at all"
## without reading a key count.
func get_roster() -> Array:
	var roster: Array = []
	if not has_localization:
		return roster
	# Emitted only when there IS a source language, so a hand-edited sidecar with a blank one
	# cannot produce a row a picker would draw and set_language would then refuse.
	if not source_language.is_empty():
		roster.append({"code": source_language, "name": source_language})
	for entry in languages:
		var code := str(entry.get("code", ""))
		if code.is_empty():
			continue
		var label := str(entry.get("name", ""))
		roster.append({"code": code, "name": code if label.is_empty() else label})
	return roster


# =============================================================================
# The overlay tier
# =============================================================================

## THE OVERLAY TIER (§9), and the first step of every string lookup in this plugin: the sidecar's
## row for [param key] in [param language], or [code]null[/code] when there is none.
##
## Null covers all four ways a row can be absent - no sidecar, an unknown code, the SOURCE
## language (which has no table by construction), and an id this table does not carry - and every
## one of them means the same thing to a caller: fall through to the artifact's own source table.
##
## THE EMPTY-TEXT GUARD LIVES HERE AND NOWHERE ELSE. An empty row reads as absent, because the
## export already turned a cleared translation back into source text (§5's ruled extension) and
## this is the second net for a hand-edited sidecar.
func find_overlay(key: String, language: String) -> Variant:
	if key.is_empty() or language.is_empty():
		return null
	var table = tables.get(language)
	if not (table is Dictionary):
		return null
	if not table.has(key):
		return null
	var text := str(table[key])
	return null if text.is_empty() else text


# =============================================================================
# The one resolution ladder
# =============================================================================

## THE LANGUAGE any lookup runs in, for a given localization state.
##
## The state OWNS it whenever the loaded project carries a sidecar, because a language is the
## player's and game-wide, not a per-component setting. Without a sidecar there is nothing to
## switch to and the caller's own pre-localization language code keeps its old meaning, so a
## project exported before localization existed behaves EXACTLY as it did - the presence of the
## file is the only branch, never a key count.
##
## No "is this the manager's project" check exists here (the Unity port needs one): this object IS
## the manager's, handed to every lane by reference, so there is no second candidate to confuse it
## with.
static func language_for(localization, fallback_language: String) -> String:
	if localization != null and localization.has_localization:
		return localization.active_language
	return fallback_language


## THE ONE STRING RESOLUTION LADDER (localization spec §9), shared by all three doors this plugin
## has - the evaluator's node lane, the text interpolator's dialogue lane and StoryFlowComponent's
## outside-dialogue lane - for the same reason StoryFlowCharacter.resolve_character_ref is shared:
## a second lookup that could drift never exists.
##
## Returns [code]null[/code] when nothing anywhere carries the id; callers apply their own miss
## policy (every door in this plugin answers the raw value). The tiers:
##
##  1. THE LOCALIZATION OVERLAY: the sidecar's row for this id in the language being read. Absent
##     for a pre-localization export, for the source language and for an id the sidecar does not
##     carry - all of which fall through. The tables are FULL and PRE-RESOLVED, so nothing here
##     computes a status or compares a hash.
##  2. THE KEYING ARTIFACT'S OWN TABLE, the current script first then the project globals
##     characters.json merges into. The LANGUAGE-PREFIXED probe comes FIRST and is the
##     pre-localization behavior kept exactly as it was: an artifact's strings block may itself
##     carry more than one language block and the importer flattens each to `code.key`. The
##     SOURCE-language probe beside it is the step the sidecar makes necessary - every export this
##     editor writes keys its artifact strings by the source language alone, so once the language
##     being read is a target language the first probe cannot hit, and this is the fall-through
##     the contract names ("-> the keying artifact's own strings.en"). The two probes are the SAME
##     key whenever the codes agree, which is every pre-localization project, so the second is
##     SKIPPED in that case rather than repeated - inherited from the Unity port, and the one
##     deliberate divergence from Unreal, which computes and probes both keys unconditionally.
##     The source probe also fires for a project with NO sidecar whose caller asked in some other
##     code: source_language is "en" there, so an id the requested code does not carry answers
##     SOURCE TEXT instead of the raw key. That is the contract's never-undefined shape reaching
##     one lane it did not use to, and it is pinned by the package's source-only case.
##  3. the caller's miss policy (never a lookup failure a caller has to test for).
##
## THE LOOKUP RUNS ON THE AUTHORED TEMPLATE. Every caller that interpolates `{Variable}` tokens
## interpolates the RESULT of this function, never the other way round - a translated line is
## authored with the same tokens as the source line, so interpolating first would hand this lookup
## a string no table was ever keyed by. That failure is INVISIBLE: the text still renders, in the
## source language, and only for lines that happen to carry a token. GDScript has no type that can
## catch a caller getting this order wrong, so the order is stated at every door.
static func look_up(localization, script: StoryFlowScript, global_strings: Dictionary, key: String, fallback_language: String) -> Variant:
	if key.is_empty():
		return null

	var language := language_for(localization, fallback_language)

	# TIER 1 - the overlay. The empty-text guard lives inside find_overlay.
	if localization != null:
		var overlaid = localization.find_overlay(key, language)
		if overlaid != null:
			return overlaid

	# TIER 2 - the artifact's own table, the legacy language-prefixed probe first.
	var direct = _look_up_exact(script, global_strings, language + "." + key)
	if direct != null:
		return direct

	var source: String = localization.source_language if localization != null else ""
	if not source.is_empty() and source != language:
		var from_source = _look_up_exact(script, global_strings, source + "." + key)
		if from_source != null:
			return from_source

	return null


## One exact table key, the current script before the project globals. Membership is tested rather
## than compared against the key, so a row whose text happens to equal its own id still counts as
## a hit instead of falling silently through to the next table.
static func _look_up_exact(script: StoryFlowScript, global_strings: Dictionary, exact_key: String) -> Variant:
	if script != null and script.strings.has(exact_key):
		return str(script.strings[exact_key])
	if global_strings.has(exact_key):
		return str(global_strings[exact_key])
	return null
