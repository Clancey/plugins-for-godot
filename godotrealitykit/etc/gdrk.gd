#===----------------------------------------------------------------------===#
# Copyright © 2026 Apple Inc.
#
# Licensed under the MIT license (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# LICENSE
#
#===----------------------------------------------------------------------===#

@tool
extends EditorPlugin

var export_plugin: EditorExportPlugin = GDRKEditorExportPlugin.new()
var material_export: EditorExportPlugin = MaterialEditorExportPlugin.new()

const VolumeCameraGizmoPlugin = preload("res://addons/GodotRealityKit/volume_camera_gizmo/gizmo.gd")
const DLShadowGizmoPlugin = preload("res://addons/GodotRealityKit/directional_light_shadow_gizmo/gizmo.gd")
const ClippingGizmoPlugin = preload("res://addons/GodotRealityKit/clipping_gizmo/gizmo.gd")

var volume_camera_gizmo_plugin = VolumeCameraGizmoPlugin.new()
var dl_shadow_gizmo_plugin = DLShadowGizmoPlugin.new()
var clipping_gizmo_plugin = ClippingGizmoPlugin.new()

func setup_setting_handles_game_controller_events():
	var key: String = "reality_kit/handles_game_controller_events"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, true)
	ProjectSettings.set_initial_value(key, true)
	ProjectSettings.set_as_basic(key, false)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_BOOL
	})

func setup_realitykit_presentation_style():
	var key: String = "reality_kit/presentation_style"
	var default: String = "Volumetric Window"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.set_initial_value(key, default)
	ProjectSettings.set_as_basic(key, true)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Volumetric Window,Portal Window,Immersive"
	})

func setup_realitykit_immersion_style():
	var key: String = "reality_kit/immersion_style"
	var default: String = "Mixed"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.set_initial_value(key, default)
	ProjectSettings.set_as_basic(key, true)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Mixed,Full,Progressive"
	})

func setup_realitykit_worldenvironment():
	var key: String = "reality_kit/world_environment"
	var default: String = "Automatic"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.set_initial_value(key, default)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Automatic,Enable,Disable"
	})

func setup_realitykit_portal_world_scale():
	var key: String = "reality_kit/portal_presentation_world_scale"
	var default: float = 0.0
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.set_initial_value(key, default)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_FLOAT
	})

func setup_realitykit_volume_default_size():
	var key: String = "reality_kit/volume_default_size"
	var default: Vector3 = Vector3.ZERO
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.set_initial_value(key, default)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_VECTOR3,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "suffix:m"
	})

func setup_realitykit_volume_resizable():
	var key: String = "reality_kit/volume_resizable"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, true)
	ProjectSettings.set_initial_value(key, true)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_BOOL
	})

func setup_realitykit_volume_default_placement():
	var key: String = "reality_kit/volume_default_placement"
	var default: String = "Automatic"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.set_initial_value(key, default)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Automatic,Utility Panel"
	})

func setup_realitykit_volume_world_alignment():
	var key: String = "reality_kit/volume_world_alignment"
	var default: String = "Automatic"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.set_initial_value(key, default)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Automatic,Adaptive,Gravity Aligned"
	})

func setup_debug_rendering_on_macos():
	var key: String = "reality_kit/debug_rendering_on_macos"
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, false)
	ProjectSettings.set_initial_value(key, false)

	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_BOOL
	})

func _init():
	add_export_plugin(export_plugin)
	add_export_plugin(material_export)

	setup_setting_handles_game_controller_events()
	setup_realitykit_presentation_style()
	setup_realitykit_immersion_style()
	setup_realitykit_worldenvironment()
	setup_realitykit_portal_world_scale()
	setup_realitykit_volume_default_size()
	setup_realitykit_volume_resizable()
	setup_realitykit_volume_default_placement()
	setup_realitykit_volume_world_alignment()
	setup_debug_rendering_on_macos()

func _enter_tree():
	add_node_3d_gizmo_plugin(volume_camera_gizmo_plugin)
	add_node_3d_gizmo_plugin(dl_shadow_gizmo_plugin)
	add_node_3d_gizmo_plugin(clipping_gizmo_plugin)
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)

func _exit_tree():
	remove_node_3d_gizmo_plugin(volume_camera_gizmo_plugin)
	remove_node_3d_gizmo_plugin(dl_shadow_gizmo_plugin)
	remove_node_3d_gizmo_plugin(clipping_gizmo_plugin)
	EditorInterface.get_selection().selection_changed.disconnect(_on_selection_changed)

func _on_selection_changed() -> void:
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node.get_class() == "RealityKitDirectionalLightShadow3D" or node.get_class() == "RealityClipping3D":
			node.update_gizmos()

func _enable_plugin() -> void:
	ProjectSettings.set_setting("application/run/main_loop_type", "RealitySceneTree")
	ProjectSettings.save()

func _disable_plugin() -> void:
	ProjectSettings.set_setting("application/run/main_loop_type", "SceneTree")
	ProjectSettings.save()
