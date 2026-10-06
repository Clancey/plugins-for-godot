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

#include "hierarchical_effect.h"

#include "node_loaders.h"

using namespace gdrk;

void HoverEffect::update(NodeLoaders *p_nodes, GodotRealityKit::Entity entity, godot::RID p_new_rid) {
	if (p_new_rid.is_valid()) {
		const HoverEffectStyle &style = p_nodes->get_hover_effect_style(p_new_rid);
		swift::Optional<GodotRealityKit::HoverEffectGroupID> group_id =
				swift::Optional<GodotRealityKit::HoverEffectGroupID>::some(style.group_id);
		entity.setIsInputTarget(true);
		entity.setHoverEffect(group_id, style.color, style.strength, style.spotlight);
	} else {
		entity.setIsInputTarget(false);
		entity.setHoverEffect(
				swift::Optional<GodotRealityKit::HoverEffectGroupID>::none(), nullptr, 1.0f, false);
	}
}

void PortalEffect::update(NodeLoaders *p_nodes, GodotRealityKit::Entity entity, godot::RID p_new_rid) {
	GodotRealityKit::Entity new_parent = p_new_rid.is_valid()
			? p_nodes->get_portal_world_entity(p_new_rid)
			: p_nodes->get_root_entity();
	entity.setParent(swift::Optional<GodotRealityKit::Entity>::some(new_parent));
}

void PortalCrossingEffect::update(NodeLoaders *p_nodes, GodotRealityKit::Entity entity, godot::RID p_new_rid) {
	entity.setHasPortalCrossing(p_new_rid.is_valid() ? true : false);
}

void IBLEffect::update(NodeLoaders *p_nodes, GodotRealityKit::Entity entity, godot::RID p_new_rid) {
	if (p_new_rid.is_valid()) {
		GodotRealityKit::Entity ibl_entity = p_nodes->get_ibl_entity(p_new_rid);
		entity.setImageBasedLightReceiver(
				swift::Optional<GodotRealityKit::Entity>::some(ibl_entity));
	} else {
		entity.setImageBasedLightReceiver(
				swift::Optional<GodotRealityKit::Entity>::none());
	}
}

void ClippingEffect::update(NodeLoaders *p_nodes, GodotRealityKit::Entity entity, godot::RID p_new_rid) {
	// Unlike PortalEffect, ClippingEffect doesn't own reparenting: a node can simultaneously be
	// inside a portal (or nothing) and inside a clip region. Only touch setParent when this node
	// is actually clipped; otherwise leave whatever PortalEffect/root placement already set,
	// since for_each_effect() runs every effect in sequence and an unconditional fallback here
	// would clobber a valid reparent another effect just performed this same pass.
	if (p_new_rid.is_valid()) {
		GodotRealityKit::Entity new_parent = p_nodes->get_clip_reparent_anchor(p_new_rid);
		entity.setParent(swift::Optional<GodotRealityKit::Entity>::some(new_parent));
	}
}

template <typename Effect>
Effect &HierarchicalEffect<Effect>::get_effect(godot::RID p_rid) {
	static Effect default_effect;
	EffectAndRoot *effect_and_root = effect_owner.get_or_null(p_rid);
	ERR_FAIL_COND_V(!effect_and_root, default_effect);
	return effect_and_root->effect;
}

template <typename Effect>
godot::Node *HierarchicalEffect<Effect>::get_effect_root(godot::RID p_rid) {
	EffectAndRoot *effect_and_root = effect_owner.get_or_null(p_rid);
	ERR_FAIL_NULL_V(effect_and_root, nullptr);
	return get_node_instance(effect_and_root->root_id);
}

template <typename Effect>
bool HierarchicalEffect<Effect>::owns(godot::RID p_rid) {
	return effect_owner.owns(p_rid);
}

template <typename Effect>
godot::RID HierarchicalEffect<Effect>::create(uint64_t p_root_id, const Effect &p_effect) {
	const godot::RID rid = effect_owner.make_rid({ .effect = p_effect, .root_id = p_root_id });

	root_id_to_rid.insert(p_root_id, rid);

	godot::Object *root_obj = godot::ObjectDB::get_instance(p_root_id);
	godot::Node *root = godot::Object::cast_to<godot::Node>(root_obj);
	ERR_FAIL_NULL_V(root, godot::RID());

	queued_propagations.push_back({ .root_id = p_root_id, .rid = rid });

	return rid;
}

template <typename Effect>
void HierarchicalEffect<Effect>::free(uint64_t p_root_id) {
	const godot::RID rid = root_id_to_rid.get(p_root_id);
	root_id_to_rid.erase(p_root_id);
	effect_owner.free(rid);

	// Queue an invalid RID so flush_propagations() falls back to the parent's effect instead of
	// propagating the freed RID.
	queued_propagations.push_back({ .root_id = p_root_id, .rid = godot::RID() });
}

template <typename Effect>
godot::RID HierarchicalEffect<Effect>::get(uint64_t p_root_id) const {
	const auto found_rid = root_id_to_rid.find(p_root_id);
	return found_rid ? found_rid->value : godot::RID();
}

template <typename Effect>
bool HierarchicalEffect<Effect>::has(uint64_t p_root_id) const {
	return root_id_to_rid.has(p_root_id);
}

template <typename Effect>
godot::RID HierarchicalEffect<Effect>::get_rid(godot::Node *p_node) {
	return owner->visit(p_node, godot::RID(), [&](const auto &p_loader, auto p_node) {
		const uint64_t node_id = p_node->get_instance_id();
		const auto found_idx = p_loader.node_id_to_idx.find(node_id);
		auto &effect_rids = p_loader.node_effect_rids_set.template get<Effect>();
		return found_idx ? effect_rids[found_idx->value] : godot::RID();
	});
}

template <typename Effect>
void HierarchicalEffect<Effect>::flush_propagations() {
	for (const auto [root_id, rid] : queued_propagations) {
		godot::Object *root_obj = godot::ObjectDB::get_instance(root_id);
		godot::Node *root = godot::Object::cast_to<godot::Node>(root_obj);
		if (!root) {
			continue;
		}

		godot::Node *root_parent = root->get_parent();
		const godot::RID parent_rid = root_parent ? get_rid(root_parent) : godot::RID();
		const godot::RID effective_rid = rid.is_valid() ? rid : parent_rid;
		propagate_update<true>(root, effective_rid);
	}
	queued_propagations.clear();
}

template <typename Effect>
template <bool root>
void HierarchicalEffect<Effect>::propagate_update(godot::Node *p_node, godot::RID p_rid) {
	const uint64_t node_id = p_node->get_instance_id();
	if constexpr (!root) {
		const godot::RID cur_rid = get_rid(p_node);
		EffectAndRoot *effect_root_id = effect_owner.get_or_null(cur_rid);
		if (effect_root_id && effect_root_id->root_id == node_id) {
			return;
		}
	}

	owner->visit(p_node, [&](auto &p_loader, auto p_node) {
		if (const auto found_idx = p_loader.node_id_to_idx.find(node_id)) {
			p_loader.template _update_effect<Effect>(found_idx->value, p_rid);
		}

		const uint32_t child_count = p_node->get_child_count();
		for (uint32_t child_idx = 0; child_idx < child_count; child_idx++) {
			godot::Node *child = p_node->get_child(child_idx);
			if (child) {
				propagate_update<false>(child, p_rid);
			}
		}
	});
}

template class gdrk::HierarchicalEffect<HoverEffect>;
template class gdrk::HierarchicalEffect<PortalEffect>;
template class gdrk::HierarchicalEffect<PortalCrossingEffect>;
template class gdrk::HierarchicalEffect<IBLEffect>;
template class gdrk::HierarchicalEffect<ClippingEffect>;
