extends RefCounted

static func normalize(value: Variant) -> Dictionary:
	var result := {"version": 1, "enabled": false, "historyLimit": 100}
	if not value is Dictionary or typeof(value.get("version")) not in [TYPE_INT, TYPE_FLOAT] or value.get("version") != 1:
		return result
	result.enabled = typeof(value.get("enabled")) == TYPE_BOOL and value.enabled
	var limit = value.get("historyLimit")
	if typeof(limit) in [TYPE_INT, TYPE_FLOAT] and is_finite(limit) and limit == floor(limit) and limit >= 1 and limit <= 1000:
		result.historyLimit = int(limit)
	return result
