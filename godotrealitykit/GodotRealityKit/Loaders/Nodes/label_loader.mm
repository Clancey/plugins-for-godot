//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc.
//
// Licensed under the MIT license (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// LICENSE
//
//===----------------------------------------------------------------------===//

#include "label_loader.h"
#include "mesh_common.h"
#include "signposts.h"

#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/text_server_manager.hpp>

using namespace gdrk;

auto get_label_text_prop_hasher() {
	using L = godot::Label3D;
	return make_object_property_hasher(make_object_property(&L::get_autowrap_mode),
			make_object_property(&L::get_font),
			make_object_property(&L::get_font_size),
			make_object_property(&L::get_justification_flags),
			make_object_property(&L::get_language),
			make_object_property(&L::get_line_spacing),
			make_object_property(&L::get_offset),
			make_object_property(&L::get_outline_size),
			make_object_property(&L::get_pixel_size),
			make_object_property(&L::get_structured_text_bidi_override),
			make_object_property(&L::get_structured_text_bidi_override_options),
			make_object_property(&L::get_text),
			make_object_property(&L::get_text_direction),
			make_object_property(&L::is_uppercase),
			make_object_property(&L::get_vertical_alignment),
			make_object_property(&L::get_width));
}

auto get_label_material_prop_hasher() {
	using L = godot::Label3D;
	return make_object_property_hasher(make_object_property(&L::get_alpha_antialiasing_edge),
			make_object_property(&L::get_alpha_antialiasing),
			make_object_property(&L::get_alpha_cut_mode),
			make_object_property(&L::get_alpha_hash_scale),
			make_object_property(&L::get_alpha_scissor_threshold),
			make_object_property(&L::get_billboard_mode),
			make_object_property<L>(&L::get_cast_shadows_setting),
			make_object_property(&L::get_draw_flag, L::FLAG_DOUBLE_SIDED),
			make_object_property(&L::get_draw_flag, L::FLAG_FIXED_SIZE),
			make_object_property(&L::get_modulate),
			make_object_property(&L::get_draw_flag,
					L::FLAG_DISABLE_DEPTH_TEST),
			make_object_property(&L::get_draw_flag, L::FLAG_FIXED_SIZE),
			make_object_property(&L::get_modulate),
			make_object_property(&L::get_draw_flag, L::FLAG_DISABLE_DEPTH_TEST),
			make_object_property(&L::get_outline_modulate),
			make_object_property(&L::get_outline_render_priority),
			make_object_property(&L::get_render_priority),
			make_object_property(&L::get_draw_flag, L::FLAG_SHADED),
			make_object_property(&L::get_texture_filter));
}

ProgramDescription get_label_material_description(godot::Label3D *p_node, bool p_outline) {
	using L = godot::Label3D;
	using BM = godot::BaseMaterial3D;
	BM::Transparency transparency = BM::TRANSPARENCY_ALPHA;
	if (p_node->get_alpha_cut_mode() == L::ALPHA_CUT_DISCARD) {
		transparency = BM::TRANSPARENCY_ALPHA_SCISSOR;
	} else if (p_node->get_alpha_cut_mode() == L::ALPHA_CUT_OPAQUE_PREPASS) {
		transparency = BM::TRANSPARENCY_ALPHA_DEPTH_PRE_PASS;
	} else if (p_node->get_alpha_cut_mode() == L::ALPHA_CUT_HASH) {
		transparency = BM::TRANSPARENCY_ALPHA_HASH;
	}

	uint32_t flags = (1 << BM::FLAG_SRGB_VERTEX_COLOR) | (1 << BM::FLAG_ALBEDO_FROM_VERTEX_COLOR);
	if (p_node->get_draw_flag(L::FLAG_DISABLE_DEPTH_TEST)) {
		flags |= (1 << BM::FLAG_DISABLE_DEPTH_TEST);
	}
	if (p_node->get_draw_flag(L::FLAG_FIXED_SIZE)) {
		flags |= (1 << BM::FLAG_FIXED_SIZE);
	}
	if (p_node->get_billboard_mode() != BM::BILLBOARD_DISABLED) {
		flags |= (1 << BM::FLAG_BILLBOARD_KEEP_SCALE);
	}

	// We currently hope that if this base font RID has MSDF textures,
	// then the rest of the font variations also use MSDF textures.
	// Font::get_rid() is empty through the extension API, so use the first of the RIDs Label3D shapes with.
	const godot::Ref<godot::Font> font = p_node->get_font();
	if (font.is_valid()) {
		const godot::TypedArray<godot::RID> font_rids = font->get_rids();
		godot::Ref<godot::TextServer> text_server =
				godot::TextServerManager::get_singleton()->get_primary_interface();
		if (!font_rids.is_empty() && text_server->font_is_multichannel_signed_distance_field(font_rids[0])) {
			flags |= (1 << BM::FLAG_ALBEDO_TEXTURE_MSDF);
		}
	}

	return BaseMaterial3DDescription{
		.render_priority = p_outline ? p_node->get_outline_render_priority() : p_node->get_render_priority(),
		.shading_mode = p_node->get_draw_flag(L::FLAG_SHADED) ? BM::SHADING_MODE_PER_PIXEL : BM::SHADING_MODE_UNSHADED,
		.transparency = transparency,
		.cull_mode = p_node->get_draw_flag(L::FLAG_DOUBLE_SIDED) ? BM::CULL_DISABLED : BM::CULL_BACK,
		.texture_filter = p_node->get_texture_filter(),
		.billboard_mode = p_node->get_billboard_mode(),
		.flags = flags,
		.use_depth_postpass = true,
	};
}

void LabelLoader::update_deps(
		ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);
	TextureLoader *textures = std::get<TextureLoader *>(p_resource_loaders);

	Base::update_deps(p_resource_loaders);

	const godot::RenderingServer *rs = rendering_server();
	static auto text_prop_hasher = get_label_text_prop_hasher();
	static auto material_prop_hasher = get_label_material_prop_hasher();

	ChangedDependencyListSet changed_mesh_deps = ChangedDependencyListSet(get_capacity());
	ChangedDependencyListSet changed_material_deps = ChangedDependencyListSet(get_capacity());
	for_each_removed([&](uint32_t idx) {
		changed_mesh_deps.mark_changed(idx);
		changed_material_deps.mark_changed(idx);
	});
	for_each_valid([&](uint32_t idx) {
		godot::Label3D *node = nodes[idx];

		uint32_t mesh_hash_state = text_prop_hasher.hash(node);
		uint32_t material_hash_state = material_prop_hasher.hash(node);
		accum_mesh_hash(node, mesh_hash_state, material_hash_state);

		bool text_dirty = false;
		const uint32_t text_hash = godot::hash_fmix32(mesh_hash_state);
		if (dep_states[idx].text_hash != text_hash) {
			for (uint32_t mesh_idx : add_mesh_deps(changed_mesh_deps, meshes, idx, node)) {
				// Label3D regenerates its mesh on every text change; the per-text
				// mesh has a font-atlas surface for the body and a second for the outline.
				// Compacting them produces stale geometry on subsequent text
				// changes, so opt out — Label3D meshes are short-lived anyway.
				meshes->set_no_compact(mesh_idx);
				meshes->mark_dirty(mesh_idx);
			}

			dep_states[idx].text_hash = text_hash;
			text_dirty = true;
		}

		// We mix the text properties hash into the material propeties hash, since if the text needs to be reloaded
		// the the material also needs to be reloaded to reference a potentially new font atlas texture (with a separate RID).
		// We also mark the font atlas texture(s) for each material as dirty here too.
		const uint32_t material_hash = godot::hash_fmix32(material_hash_state);
		if (dep_states[idx].material_hash != material_hash || text_dirty) {
			bool is_outline = false;
			ProgramDescription material_description = get_label_material_description(node, false);
			ProgramDescription outline_material_description = get_label_material_description(node, true);
			for (uint32_t material_idx : add_material_deps(changed_material_deps, materials, idx, node)) {
				ProgramDescription desc = is_outline ? outline_material_description : material_description;
				if (!is_outline) {
					is_outline = true;
				}

				materials->set_description(material_idx, std::move(desc));
				materials->mark_dirty(material_idx);

				if (text_dirty) {
					const godot::RID material_rid = materials->get_rid(material_idx);
					ERR_CONTINUE(!material_rid.is_valid());

					const godot::RID albedo_texture_rid = rs->material_get_param(material_rid, "texture_albedo");
					if (albedo_texture_rid.is_valid()) {
						const uint32_t albedo_texture_idx = textures->find_or_add(albedo_texture_rid);
						textures->mark_dirty(albedo_texture_idx);
					}
				}
			}

			dep_states[idx].material_hash = material_hash;
		}
	});

	mesh_deps.replace_changed(changed_mesh_deps, meshes);
	material_deps.replace_changed(changed_material_deps, materials);
}

void LabelLoader::update_dirty_flags(const ResourceLoaderSet &p_resource_loaders) {
	const MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	const MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);

	dirty_idxs.merge(mesh_deps.changed());
	if (meshes->has_dirty()) {
		for (Dependency dep : mesh_deps.get()) {
			if (meshes->is_dirty(dep.src)) {
				dirty_idxs.insert(dep.dst);
			}
		}
	}

	dirty_idxs.merge(material_deps.changed());
	if (materials->has_dirty()) {
		for (Dependency dep : material_deps.get()) {
			if (materials->is_dirty(dep.src)) {
				dirty_idxs.insert(dep.dst);
			}
		}
	}
}

void LabelLoader::update_deps_usage(ResourceLoaderSet &p_resource_loaders) const {
	MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);

	for (Dependency dep : mesh_deps.get()) {
		if (is_valid(dep.dst)) {
			meshes->mark_used_in_frame(dep.src);
		}
	}
	for (Dependency dep : material_deps.get()) {
		if (is_valid(dep.dst)) {
			materials->mark_used_in_frame(dep.src);
		}
	}
}

void LabelLoader::update(const ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	MeshLoader *meshes = std::get<MeshLoader *>(p_resource_loaders);
	MaterialLoader *materials = std::get<MaterialLoader *>(p_resource_loaders);
	MultiMeshLoader *multimeshes = std::get<MultiMeshLoader *>(p_resource_loaders);

	Base::update(p_resource_loaders);

	for_each_dirty([&](uint32_t idx) {
		godot::Label3D *node = nodes[idx];
		ERR_FAIL_NULL(node);

		node_entities[idx].entity.clearChildren();
		for (GodotRealityKit::Entity child : node_to_entities(node, meshes, materials, multimeshes)) {
			node_entities[idx].entity.addChild(child);
		}
	});
}
