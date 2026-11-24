class_name BaseScreen
extends Control
## Abstract base class for all game screens.
## Every screen script extends this to participate in the screen-per-scene navigation system.
## Provides lifecycle hooks, metadata methods, and navigator access.


## Called by ScreenNavigator when this screen is loaded into the ScreenContainer.
## Override to initialize UI from autoload singleton data and connect signals.
func enter(params: Dictionary = {}) -> void:
	pass


## Called by ScreenNavigator just before removing this screen from the tree.
## Override to disconnect signal connections and release local references.
func exit() -> void:
	pass


## Return the screen name string used by the navigator for identity.
## Override in each screen script to return the matching SCREEN_PATHS key.
func get_screen_name() -> String:
	return ""


## Whether the TopBar should be visible while this screen is active.
## Override and return false for screens that use the full viewport (e.g. battle).
func show_top_bar() -> bool:
	return true


## Optional custom background texture path for this screen.
## Return a resource path (e.g. "res://Assets/Backgrounds/Summer1.png") to override
## the default background, or an empty string to use the default.
func get_background_override() -> String:
	return ""


## Whether the Android edge-swipe "back" gesture is active on this screen.
## Override and return false for screens whose gameplay drags start near the
## screen edges (otherwise a drag is mistaken for a back swipe).
func allows_edge_swipe_back() -> bool:
	return true


## Helper to access the ScreenNavigator node from any screen.
## ScreenNavigator is a sibling node in Main.tscn, accessible via the scene tree.
func _get_navigator() -> ScreenNavigator:
	return get_tree().current_scene.get_node("ScreenNavigator")
