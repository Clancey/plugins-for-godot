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

#pragma once

#include "resource_loader.h"
#include "signposts.h"

namespace gdrk {

// TODO: support per-instance colors
class MultiMeshLoader : public ResourceLoader<MultiMeshLoader> {
	GDCLASS(MultiMeshLoader, Object);

protected:
	static void _bind_methods() {}

public:
	void _reserve(uint32_t p_capacity) {
		ResourceLoader<MultiMeshLoader>::_reserve(p_capacity);
		multimeshes.resize(p_capacity);
		multimesh_transform_array_states.resize(p_capacity);
	}

	uint32_t find_or_add(godot::RID p_multimesh_rid);

	void remove(uint32_t p_idx) {
		free_idx(p_idx);
	}

	// Marks multimeshes whose instance buffer must grow as dirty before node dirty flags are
	// computed, so dependent nodes rebind to the new buffer that update() allocates.
	void prepare_frame_changes();

	bool update();

	GodotRealityKit::LowLevelInstanceData find_resource(godot::RID p_multimesh_rid) const {
		if (!p_multimesh_rid.is_valid()) {
			return GodotRealityKit::LowLevelInstanceData::init();
		}

		ERR_FAIL_COND_V(!multimesh_rid_to_idx.has(p_multimesh_rid), GodotRealityKit::LowLevelInstanceData::init());
		const uint32_t idx = multimesh_rid_to_idx.get(p_multimesh_rid);
		return multimeshes[idx].instance_data;
	}

private:
	struct alignas(8) TransformArrayState {
		uint32_t capacity = 0;
		uint32_t hash = 0;
	};

	struct MultiMesh {
		godot::RID multimesh_rid;
		GodotRealityKit::LowLevelInstanceData instance_data = GodotRealityKit::LowLevelInstanceData::init();
	};

	RID_Associated<uint32_t> multimesh_rid_to_idx;
	godot::LocalVector<MultiMesh> multimeshes;
	godot::LocalVector<TransformArrayState> multimesh_transform_array_states;
};

} //namespace gdrk
