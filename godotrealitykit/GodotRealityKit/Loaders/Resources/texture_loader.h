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

#include "resource_loader.h"

#include <godot_cpp/classes/viewport_texture.hpp>

namespace gdrk {

class TextureLoader : public ResourceLoader<TextureLoader> {
	GDCLASS(TextureLoader, Object);

protected:
	static void _bind_methods() {}

public:
	enum TextureUsage : uint8_t {
		Rendering = 0b01, // uses MTLPixelFormatR8Unorm_sRGB Texture View
		Compute = 0b10, // uses MTLPixelFormatR8Unorm Texture View
	};

	void _reserve(uint32_t p_capacity) {
		ResourceLoader<TextureLoader>::_reserve(p_capacity);
		textures.resize(p_capacity);
	}

	uint32_t find_or_add(godot::RID p_texture_rid, godot::Ref<godot::Texture2D> p_texture = nullptr, TextureUsage p_usage = TextureUsage::Rendering);

	void remove(uint32_t p_idx) {
		texture_rid_to_idx.remove(textures[p_idx].texture_rid);
		godot::Texture2D *texture = textures[p_idx].texture.ptr();
		if (texture) {
			disconnect_changed(texture, p_idx);
		}

		textures[p_idx] = Texture();
		free_idx(p_idx);
	}

	void mark_dirty(uint32_t p_idx) {
		ResourceLoader<TextureLoader>::mark_dirty(p_idx);
		textures[p_idx].dirty_usages = textures[p_idx].required_usages;
	}

	bool update(id<MTLCommandBuffer> p_command_buffer);

	GodotRealityKit::TextureResource find_resource_and_mark_used(godot::RID p_texture_rid, TextureUsage p_usage = TextureUsage::Rendering) {
		if (!p_texture_rid.is_valid()) {
			return GodotRealityKit::TextureResource::init();
		}

		ERR_FAIL_COND_V(!texture_rid_to_idx.has(p_texture_rid), GodotRealityKit::TextureResource::init());
		const uint32_t idx = texture_rid_to_idx.get(p_texture_rid);
		mark_used_in_frame(idx);
		return textures[idx].get_resource_for(p_usage);
	}

	void set_purge_after_upload(uint32_t p_idx, bool p_purge_after_upload) {
		textures[p_idx].purge_after_upload = p_purge_after_upload;
	}

private:
	struct Texture {
		uint8_t required_usages;
		uint8_t dirty_usages;
		bool is_viewport_texture = false;
		bool purge_after_upload = false;

		godot::RID texture_rid;

		godot::Ref<godot::Texture2D> texture;
		godot::RID rd_texture_linear_rid;
		GodotRealityKit::TextureResource resource_linear = GodotRealityKit::TextureResource::init();
		godot::RID rd_texture_srgb_rid;
		GodotRealityKit::TextureResource resource_srgb = GodotRealityKit::TextureResource::init();

		inline bool ready_for(TextureUsage p_usage) const {
			return required_usages & p_usage;
		}

		inline GodotRealityKit::TextureResource get_resource_for(TextureUsage p_usage) const {
			return p_usage == TextureUsage::Rendering ? resource_srgb : resource_linear;
		}
	};

	static bool needs_swizzle_bake(id<MTLTexture> p_texture);
	void encode_copy(id<MTLCommandBuffer> p_command_buffer, id<MTLTexture> p_src, id<MTLTexture> p_dst);

	RID_Associated<uint32_t> texture_rid_to_idx;
	godot::LocalVector<Texture> textures;
	id<MTLComputePipelineState> swizzle_bake_pso = nil;
};

} //namespace gdrk
