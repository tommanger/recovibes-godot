@tool
extends EditorPlugin
# The widget is a global class (RecoVibesWidget) - it shows up in "Add Node"
# under Control as soon as the addon is in the project. Enabling the plugin
# only adds a reminder where to find your Data Id.


func _enter_tree() -> void:
	print("RecoVibes: add a RecoVibesWidget node and paste your Data Id from the dashboard (your app → Install tab).")
