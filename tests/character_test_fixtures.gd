extends RefCounted
## Shared fixtures for the P4 character-id test files.
##
## NOT A TEST. The DECOY PAIR is the arc's load-bearing fixture design: two characters with
## the SAME variable names but DIFFERENT values, so an id resolved to the wrong record shows
## up as a wrong VALUE instead of a coincidentally right one. Record keys carry BACKSLASHES
## on purpose - the exporter's normalized form, byte-identical to what
## StoryFlowCharacter.normalize_path produces - so a test that would pass through an
## accidental re-normalization still hits the store keys directly.
## Consumers: tests/test_character_index.gd, tests/test_character_resolution.gd and
## tests/test_character_host_surface.gd (shared the same way data_asset_test_graph.gd is).

## Character FILE ids, in the exporter's da_<32 hex> shape.
const ALICE_ID := "da_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const BOB_ID := "da_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

## An id character-index.json NEVER carries - the DANGLING case (no bridge entry).
const DANGLING_ID := "da_dddddddddddddddddddddddddddddddd"

## An id [method index_text_with_ghost] maps to a record characters.json never carried -
## the UNLOADED case (bridge hit, record missing from the loaded set). Only reachable via
## ghost index entries: this engine's save load MERGES and never removes a character.
const GHOST_ID := "da_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
const GHOST_KEY := "cast\\ghost.sfc"

## characters.json record keys: lowercase, backslashes - the wire's normalized form.
const ALICE_KEY := "cast\\alice.sfc"
const BOB_KEY := "cast\\bob.sfc"


## The characters.json document for the decoy pair: same variable names, DIFFERENT values on
## every arm the nodes can read or write - integer (Trust 3 vs 9), string (Title), boolean
## (Brave), string array (Inventory), string->integer map (Prices) - so a wrong-record
## resolution is visible as a wrong value on whichever arm a test drives. "Image" is the
## DOUBLE-ROW fixture: a CUSTOM variable spelled like the builtin, beside a non-empty builtin
## image key, protecting the case-variant behavior of every alias lane.
static func characters_payload() -> Dictionary:
	return {
		"characters": {
			ALICE_KEY: {
				"name": "char.alice.name",
				"image": "alice_portrait",
				"variables": {
					"Trust": {"name": "Trust", "type": "integer", "value": 3},
					"Title": {"name": "Title", "type": "string", "value": "Captain"},
					"Brave": {"name": "Brave", "type": "boolean", "value": true},
					"Inventory": {"name": "Inventory", "type": "string", "isArray": true, "value": ["sword", "rope"]},
					"Prices": {"name": "Prices", "type": "map", "keyType": "string", "valueType": "integer",
						"value": [{"key": "ale", "value": 3}]},
					"Image": {"name": "Image", "type": "string", "value": "alice-custom-image-row"},
				},
			},
			BOB_KEY: {
				"name": "char.bob.name",
				"image": "bob_portrait",
				"variables": {
					"Trust": {"name": "Trust", "type": "integer", "value": 9},
					"Title": {"name": "Title", "type": "string", "value": "Doctor"},
					"Brave": {"name": "Brave", "type": "boolean", "value": false},
					"Inventory": {"name": "Inventory", "type": "string", "isArray": true, "value": ["bones"]},
					"Prices": {"name": "Prices", "type": "map", "keyType": "string", "valueType": "integer",
						"value": [{"key": "ale", "value": 9}]},
					"Image": {"name": "Image", "type": "string", "value": "bob-custom-image-row"},
				},
			},
		},
	}


## The character-index.json document mapping both ids to their record keys.
static func index_payload() -> Dictionary:
	return {
		"schemaVersion": "1",
		"characters": {
			ALICE_ID: ALICE_KEY,
			BOB_ID: BOB_KEY,
		},
	}


## Write a minimal exported build carrying the decoy pair: project.storyflow with one inline
## "Main" script (nodes from [param script_nodes], connections from [param connections] in
## the wire's sourceHandle/targetHandle shape), characters.json, and - when
## [param index_text] is not null - character-index.json written VERBATIM, so ladder tests
## can ship garbage bytes as easily as the valid document.
static func write_build(build_dir: String, index_text = null, script_nodes: Dictionary = {"0": {"type": "start"}}, connections: Array = []) -> void:
	DirAccess.make_dir_recursive_absolute(build_dir)
	write_text(build_dir.path_join("project.storyflow"), JSON.stringify({
		"version": "1.0",
		"metadata": {"title": "CharacterIndexTest"},
		"startupScript": "Main",
		"scripts": {"Main": {"nodes": script_nodes, "connections": connections}},
	}, "\t"))
	write_text(build_dir.path_join("characters.json"), JSON.stringify(characters_payload(), "\t"))
	if index_text != null:
		write_text(build_dir.path_join("character-index.json"), str(index_text))


## The valid character-index.json document as text, for write_build.
static func index_text_valid() -> String:
	return JSON.stringify(index_payload(), "\t")


## The valid document PLUS a ghost entry: GHOST_ID -> a record characters.json never
## carried. The one-line custom payload the unloaded-producer pin imports for real.
static func index_text_with_ghost() -> String:
	var payload := index_payload()
	payload["characters"][GHOST_ID] = GHOST_KEY
	return JSON.stringify(payload, "\t")


## A connection in the WIRE shape (sourceHandle/targetHandle camelCase), for builds that go
## through the real importer. The handle strings themselves are the editor's formats - build
## them with StoryFlowHandles / the data_asset_test_graph.gd conventions.
static func wire_edge(source: String, source_handle: String, target: String, target_handle: String) -> Dictionary:
	return {
		"id": "%s->%s:%s" % [source, target, target_handle],
		"source": source, "target": target,
		"sourceHandle": source_handle, "targetHandle": target_handle,
	}


static func write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("  SETUP FAILURE: cannot write %s" % path)
		return
	file.store_string(text)
	file.close()
