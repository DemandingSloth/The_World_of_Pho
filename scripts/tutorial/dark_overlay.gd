extends ColorRect

## DarkOverlay — Custom ColorRect that blocks input everywhere EXCEPT inside
## the tutorial highlight cutout rect, allowing the player to interact with
## the underlying game UI through the cutout "hole."
##
## Requirements: 13.1, 13.2, 13.4


## Override _has_point to create a transparent input hole at the cutout rect.
## Returns false for points inside the cutout, so the event passes through
## to nodes beneath (the game UI). Returns true everywhere else so the dark
## overlay consumes and discards those touches.
func _has_point(point: Vector2) -> bool:
	var overlay := get_parent()
	if overlay:
		if overlay.has_method("is_interaction_allowed") and overlay.is_interaction_allowed():
			return false  # Let input pass through to game UI everywhere
		if overlay.has_method("get_cutout_rect"):
			var cutout: Rect2 = overlay.get_cutout_rect()
			if cutout.size != Vector2.ZERO and cutout.has_point(point):
				return false  # Let input pass through to game UI
	return true  # Block input (consume and discard)
