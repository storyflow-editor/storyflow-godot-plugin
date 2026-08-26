extends RefCounted
## Shared fixtures for the P4 character-id test files.
##
## NOT A TEST. The DECOY PAIR is the arc's load-bearing fixture design: two characters with
## the SAME variable names but DIFFERENT values, so an id resolved to the wrong record shows
## up as a wrong VALUE instead of a coincidentally right one. Record keys carry BACKSLASHES
## on purpose - the exporter's normalized form, byte-identical to what
## StoryFlowCharacter.normalize_path produces - so a test that would pass through an
## accidental re-normalization still hits the store keys directly.
## tests/test_character_index.gd uses it today; the id-resolution tests of the next task are
## the intended second consumer (the same way data_asset_test_graph.gd is shared).

## Character FILE ids, in the exporter's da_<32 hex> shape.
const ALICE_ID := "da_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const BOB_ID := "da_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

## characters.json record keys: lowercase, backslashes - the wire's normalized form.
const ALICE_KEY := "cast\\alice.sfc"
const BOB_KEY := "cast\\bob.sfc"


## The characters.json document for the decoy pair: same variable names, different values
## (Trust 3 vs 9), so a wrong-record resolution is visible as a wrong value.
static func characters_payload() -> Dictionary:
	return {
		"characters": {
			ALICE_KEY: {
				"name": "char.alice.name",
				"image": "",
				"variables": {
					"Trust": {"name": "Trust", "type": "integer", "value": 3},
					"Title": {"name": "Title", "type": "string", "value": "Captain"},
				},
			},
			BOB_KEY: {
				"name": "char.bob.name",
				"image": "",
				"variables": {
					"Trust": {"name": "Trust", "type": "integer", "value": 9},
					"Title": {"name": "Title", "type": "string", "value": "Doctor"},
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
## "Main" script (nodes from [param script_nodes]), characters.json, and - when
## [param index_text] is not null - character-index.json written VERBATIM, so ladder tests
## can ship garbage bytes as easily as the valid document.
static func write_build(build_dir: String, index_text = null, script_nodes: Dictionary = {"0": {"type": "start"}}) -> void:
	DirAccess.make_dir_recursive_absolute(build_dir)
	write_text(build_dir.path_join("project.storyflow"), JSON.stringify({
		"version": "1.0",
		"metadata": {"title": "CharacterIndexTest"},
		"startupScript": "Main",
		"scripts": {"Main": {"nodes": script_nodes, "connections": []}},
	}, "\t"))
	write_text(build_dir.path_join("characters.json"), JSON.stringify(characters_payload(), "\t"))
	if index_text != null:
		write_text(build_dir.path_join("character-index.json"), str(index_text))


## The valid character-index.json document as text, for write_build.
static func index_text_valid() -> String:
	return JSON.stringify(index_payload(), "\t")


static func write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("  SETUP FAILURE: cannot write %s" % path)
		return
	file.store_string(text)
	file.close()
