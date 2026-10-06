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

#include "multimesh_loader.h"
#include "bridge.h"
#include "signposts.h"

using namespace gdrk;

uint32_t MultiMeshLoader::find_or_add(godot::RID p_multimesh_rid) {
	if (multimesh_rid_to_idx.has(p_multimesh_rid)) {
		return multimesh_rid_to_idx.get(p_multimesh_rid);
	}

	const uint32_t idx = alloc_idx();
	// We explicity don't connect the changed callback here, as it isn't needed.

	multimeshes[idx] = MultiMesh{
		.multimesh_rid = p_multimesh_rid,
	};

	multimesh_transform_array_states[idx] = TransformArrayState();
	multimesh_rid_to_idx.insert(p_multimesh_rid, idx);
	return idx;
}

void MultiMeshLoader::prepare_frame_changes() {
	godot::RenderingServer *rs = rendering_server();
	for_each_valid([&](uint32_t idx) {
		const godot::RID multimesh_rid = multimeshes[idx].multimesh_rid;
		if (!multimesh_rid.is_valid()) {
			return;
		}
		if (multimesh_transform_array_states[idx].capacity < (uint32_t)rs->multimesh_get_instance_count(multimesh_rid)) {
			mark_dirty(idx);
		}
	});
}

bool MultiMeshLoader::update() {
	PROFILE_FUNC_SCOPE;

	for_each_valid([&](uint32_t idx) {
		if (!is_used_in_frame(idx)) {
			return;
		}
		godot::RenderingServer *rs = rendering_server();
		godot::RID multimesh_rid = multimeshes[idx].multimesh_rid;
		ERR_FAIL_COND(!multimesh_rid.is_valid());

		uint32_t hash_state = HASH_MURMUR3_SEED;
		const uint32_t instance_count = rs->multimesh_get_instance_count(multimesh_rid);
		const int32_t visible_signed = rs->multimesh_get_visible_instances(multimesh_rid);
		const uint32_t visible_count = visible_signed < 0
				? instance_count
				: godot::MIN((uint32_t)visible_signed, instance_count);

		const bool instance_data_dirty = multimesh_transform_array_states[idx].capacity < instance_count;
		if (instance_data_dirty) {
			GodotRealityKit::LowLevelInstanceData instance_data = GodotRealityKit::LowLevelInstanceData::init(instance_count);

			emplace_replace(&multimeshes[idx].instance_data, instance_data);

			multimesh_transform_array_states[idx].capacity = instance_count;
		}

		for (uint32_t instance_idx = 0; instance_idx < visible_count; instance_idx++) {
			const godot::Transform3D t = rs->multimesh_instance_get_transform(multimesh_rid, instance_idx);
			hash_state = godot::hash_murmur3_one_real(t.basis[0].x, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.basis[0].y, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.basis[0].z, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.basis[1].x, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.basis[1].y, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.basis[1].z, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.basis[2].x, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.basis[2].y, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.basis[2].z, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.origin.x, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.origin.y, hash_state);
			hash_state = godot::hash_murmur3_one_real(t.origin.z, hash_state);
		}
		hash_state = godot::hash_murmur3_one_32(visible_count, hash_state);

		const uint32_t hash = godot::hash_fmix32(hash_state);
		if (instance_data_dirty | (multimesh_transform_array_states[idx].hash != hash)) {
			multimeshes[idx].instance_data.setInstanceCount(visible_count);

			for (uint32_t instance_idx = 0; instance_idx < visible_count; instance_idx++) {
				const godot::Transform3D transform = rs->multimesh_instance_get_transform(multimesh_rid, instance_idx);
				multimeshes[idx].instance_data.setTransform(instance_idx, to_matrix44(transform));
			}

			multimesh_transform_array_states[idx].hash = hash;
		}
	});

	return true;
}
