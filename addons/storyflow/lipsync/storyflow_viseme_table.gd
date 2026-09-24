class_name StoryFlowVisemeTable
extends RefCounted

const AXIS := ["OO", "OH", "AA", "EE"]
const POSE_NAMES := ["rest", "AA", "EE", "IH", "OH", "OO", "MM", "FF", "TH", "L"]


static func default_table() -> Dictionary:
	return {
		"rest": {},
		"AA": {"jawOpen": 0.85, "mouthLowerDownLeft": 0.32, "mouthLowerDownRight": 0.32},
		"EE": {"jawOpen": 0.28, "mouthStretchLeft": 0.78, "mouthStretchRight": 0.78, "mouthSmileLeft": 0.32, "mouthSmileRight": 0.32},
		"IH": {"jawOpen": 0.36, "mouthStretchLeft": 0.44, "mouthStretchRight": 0.44},
		"OH": {"jawOpen": 0.62, "mouthFunnel": 0.72, "mouthPucker": 0.32},
		"OO": {"jawOpen": 0.20, "mouthPucker": 0.72, "mouthFunnel": 0.38},
		"MM": {"mouthClose": 0.68, "mouthPressLeft": 0.52, "mouthPressRight": 0.52},
		"FF": {"jawOpen": 0.20, "mouthRollLower": 0.72, "mouthUpperUpLeft": 0.38, "mouthUpperUpRight": 0.38},
		"TH": {"jawOpen": 0.44, "tongueOut": 0.66, "tongueUp": 0.28},
		"L": {"jawOpen": 0.52, "tongueUp": 0.82, "tongueRaise": 0.58},
	}


static func owned_morphs(table: Dictionary) -> Array[String]:
	var names: Dictionary = {}
	for pose in table.values():
		if pose is Dictionary:
			for morph in pose.keys():
				names[str(morph)] = true
	var owned: Array[String] = []
	for name in names.keys():
		owned.append(name)
	owned.sort()
	return owned
