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

#include "collision_object_loader.h"
#include "node_loaders.h"
#include "signposts.h"

using namespace gdrk;

namespace {

auto get_hover_effect_3d_prop_hasher() {
	return make_object_property_hasher(
			make_object_property(&RealityHoverEffect3D::get_color_enabled),
			make_object_property(&RealityHoverEffect3D::get_color),
			make_object_property(&RealityHoverEffect3D::get_strength),
			make_object_property(&RealityHoverEffect3D::get_style));
}

HoverEffectStyle get_hover_effect_node_style(const RealityHoverEffect3D *p_node) {
	GDRKColorRef color = p_node->get_color_enabled() ? to_gdrk_color(p_node->get_color()) : nullptr;

	return HoverEffectStyle{
		.color = color,
		.strength = p_node->get_strength(),
		.spotlight = p_node->get_style() == RealityHoverEffect3D::STYLE_SPOTLIGHT
	};
}

} //namespace

bool CollisionObjectLoader::node_has_hover_effect(godot::CollisionObject3D *p_node) const {
	if (p_node->has_meta("hover_effect") && p_node->get_meta("hover_effect")) {
		return true;
	}
	// Check the hover-effect registration map directly. Using get_effect_rid here
	// would return invalid until propagation has stored a rid on this node — which
	// only happens once the node is already pickable, creating a chicken-and-egg
	// where a CollisionObject3D whose only signal of pickability is a
	// RealityHoverEffect3D child never becomes pickable.
	return owner->has_effect_root<HoverEffect>(p_node->get_instance_id());
}

bool CollisionObjectLoader::node_is_pickable(godot::CollisionObject3D *p_node) const {
	if (!p_node->is_ray_pickable()) {
		return false;
	}
	if (node_has_hover_effect(p_node)) {
		return true;
	}
	if (p_node->has_connections("input_event")) {
		return true;
	}
	// Also detect script overrides of the _input_event virtual method.
	// has_connections() only sees signal connections; a GDScript override of
	// _input_event never creates a connection. Object::has_method() checks the
	// script instance, returning true only when a script defines _input_event
	// (the C++ GDVIRTUAL declaration itself is not in ClassDB and does not trigger this).
	return p_node->has_method("_input_event");
}

void CollisionObjectLoader::update_deps(
		ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	ShapeLoader *shapes = std::get<ShapeLoader *>(p_resource_loaders);

	Base::update_deps(p_resource_loaders);

	ChangedDependencyListSet changed_shape_deps = ChangedDependencyListSet(get_capacity());
	for_each_removed([&](uint32_t idx) {
		changed_shape_deps.mark_changed(idx);
	});
	for_each_valid([&](uint32_t idx) {
		godot::CollisionObject3D *node = nodes[idx];

		const bool is_ray_pickable = node_is_pickable(node);

		uint32_t shape_hash = 0;
		if (is_ray_pickable) {
			uint32_t shape_hash_state = HASH_MURMUR3_SEED;
			for (int32_t owner_id : node->get_shape_owners()) {
				const uint32_t shape_count = node->shape_owner_get_shape_count(owner_id);
				for (uint32_t shape_id = 0; shape_id < shape_count; shape_id++) {
					godot::Ref<godot::Shape3D> shape = node->shape_owner_get_shape(owner_id, shape_id);
					shape_hash_state = godot::hash_murmur3_one_64(uint64_t(shape->get_rid().get_id()), shape_hash_state);
				}
			}

			shape_hash = godot::hash_fmix32(shape_hash_state);
		}

		if (dep_states[idx].shape_hash != shape_hash) {
			changed_shape_deps.mark_changed(idx);

			if (is_ray_pickable) {
				for (int32_t owner_id : node->get_shape_owners()) {
					const uint32_t shape_count = node->shape_owner_get_shape_count(owner_id);
					for (uint32_t shape_id = 0; shape_id < shape_count; shape_id++) {
						godot::Ref<godot::Shape3D> shape = node->shape_owner_get_shape(owner_id, shape_id);
						if (shape.is_valid()) {
							const uint32_t shape_idx = shapes->find_or_add(shape->get_rid(), shape.ptr());
							changed_shape_deps.add_changed_dep(shape_idx, idx);
						}
					}
				}
			}

			dep_states[idx].shape_hash = shape_hash;
		}
	});
	shape_deps.replace_changed(changed_shape_deps, shapes);
}

void CollisionObjectLoader::update_dirty_flags(const ResourceLoaderSet &p_resource_loaders) {
}

void CollisionObjectLoader::update_deps_usage(ResourceLoaderSet &p_resource_loaders) const {
}

void CollisionObjectLoader::update(const ResourceLoaderSet &p_resource_loaders) {
	PROFILE_FUNC_SCOPE;

	ShapeLoader *shapes = std::get<ShapeLoader *>(p_resource_loaders);

	Base::update(p_resource_loaders);

	for_each_valid([&](uint32_t p_idx) {
		godot::CollisionObject3D *node = nodes[p_idx];
		ERR_FAIL_NULL(node);

		const bool is_ray_pickable = node_is_pickable(node);
		if (node_is_ray_pickable.has(p_idx) != is_ray_pickable) {
			// Toggling pickability keeps the entity (and its id, node mapping, hover components
			// and any in-flight gesture target) and only switches its input target and collision.
			// Re-creating the entity here broke gesture targeting and gaze on device.
			if (is_ray_pickable) {
				node_is_ray_pickable.insert(p_idx);
				register_entity(p_idx);
				node_entities[p_idx].entity.setIsInputTarget(true);
				mark_dirty(p_idx);
			} else {
				node_is_ray_pickable.remove(p_idx);
				if (is_registered(p_idx)) {
					node_entities[p_idx].entity.setIsInputTarget(false);
					node_entities[p_idx].entity.setCollision(swift::Array<GodotRealityKit::ShapeResource>::init());
				}
			}
		}

		const uint64_t node_id = node->get_instance_id();
		// Only the meta-tag path drives a default-styled hover effect from this loader.
		// The RealityHoverEffect3D-child path is owned by RealityHoverEffectLoader and
		// would clash with a second hover_effect_create on the same root id.
		const bool needs_meta_hover_effect = is_ray_pickable &&
				node->has_meta("hover_effect") && (bool)node->get_meta("hover_effect");
		if (node_has_hover_effect_meta.has(p_idx) != needs_meta_hover_effect) {
			if (needs_meta_hover_effect) {
				owner->hover_effect_create(node_id, HoverEffectStyle());
				node_has_hover_effect_meta.insert(p_idx);
			} else {
				owner->hover_effect_free(node_id);
				node_has_hover_effect_meta.remove(p_idx);
			}
		}
	});

	dirty_idxs.merge(shape_deps.changed());
	if (shapes->has_dirty()) {
		for (Dependency dep : shape_deps.get()) {
			if (shapes->is_dirty(dep.src)) {
				dirty_idxs.insert(dep.dst);
			}
		}
	}

	for_each_dirty([&](uint32_t idx) {
		godot::CollisionObject3D *node = nodes[idx];
		ERR_FAIL_NULL(node);

		if (!node_is_ray_pickable.has(idx)) {
			return;
		}

		swift::Array<GodotRealityKit::ShapeResource> resources = swift::Array<GodotRealityKit::ShapeResource>::init();
		for (int32_t owner_id : node->get_shape_owners()) {
			godot::Transform3D owner_transform = node->shape_owner_get_transform(owner_id);
			GodotRealityKit::Vector3 owner_translation = to_vector3(owner_transform.origin);
			GodotRealityKit::Vector4 owner_rotation = to_vector4(owner_transform.get_basis().get_rotation_quaternion());
			WARN_COMPAT_COND(!owner_transform.get_basis().is_rotation());

			const uint32_t shape_count = node->shape_owner_get_shape_count(owner_id);
			for (uint32_t shape_id = 0; shape_id < shape_count; shape_id++) {
				godot::Ref<godot::Shape3D> shape = node->shape_owner_get_shape(owner_id, shape_id);
				if (shape.is_valid()) {
					GodotRealityKit::ShapeResource resource = shapes->find_resource(shape->get_rid());
					if (resource.isSome()) {
						GodotRealityKit::ShapeResource transformed_resource = !owner_transform.is_equal_approx(godot::Transform3D()) ? resource.offsetBy(owner_translation, owner_rotation) : resource;
						resources.append(transformed_resource);
					}
				}
			}
		}

		node_entities[idx].entity.setCollision(resources);
	});
}

void CollisionObjectLoader::on_transform_changed(uint32_t p_idx, const godot::Transform3D &transform) {
	// Entities stay registered while temporarily unpickable, so keep their transforms current.
	Base::on_transform_changed(p_idx, transform);
}

static auto hover_effect_prop_hasher = get_hover_effect_3d_prop_hasher();

uint32_t RealityHoverEffectLoader::add(RealityHoverEffect3D *p_node) {
	const uint32_t idx = Base::add(p_node);

	node_hover_effect_states[idx] = HoverEffectState{
		.properties_hash = hover_effect_prop_hasher.hash(p_node)
	};

	if (godot::Node *parent = p_node->get_parent()) {
		const HoverEffectStyle style = get_hover_effect_node_style(p_node);
		const uint64_t parent_id = parent->get_instance_id();
		node_hover_effect_rids[idx] = owner->hover_effect_create(parent_id, style);
	} else {
		node_hover_effect_rids[idx] = godot::RID();
	}

	return idx;
}

uint32_t RealityHoverEffectLoader::remove(RealityHoverEffect3D *p_node) {
	const uint32_t idx = Base::remove(p_node);

	if (godot::Node *parent = p_node->get_parent()) {
		const uint64_t parent_id = parent->get_instance_id();
		owner->hover_effect_free(parent_id);
	}

	return idx;
}

void RealityHoverEffectLoader::update(const ResourceLoaderSet &p_resource_loaders) {
	Base::update(p_resource_loaders);

	for_each_valid([&](uint32_t p_idx) {
		const RealityHoverEffect3D *node = nodes[p_idx];
		const uint32_t properties_hash = hover_effect_prop_hasher.hash(node);
		if (node_hover_effect_states[p_idx].properties_hash != properties_hash) {
			if (godot::Node *parent = node->get_parent()) {
				const uint64_t parent_id = parent->get_instance_id();
				const HoverEffectStyle style = get_hover_effect_node_style(node);
				owner->hover_effect_free(parent_id);
				const godot::RID rid = owner->hover_effect_create(parent_id, style);
				node_hover_effect_rids[p_idx] = rid;
			} else {
				node_hover_effect_rids[p_idx] = godot::RID();
			}

			node_hover_effect_states[p_idx].properties_hash = properties_hash;
		}
	});
}
