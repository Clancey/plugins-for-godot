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

#include "texture_loader.h"
#include "signposts.h"

using namespace gdrk;

// RealityKit ignores the swizzle of a LowLevelTexture, so swizzled formats such as
// Godot's luminance textures (RG8 read as RRRG) are expanded to RGBA8 on upload.
bool TextureLoader::needs_swizzle_bake(id<MTLTexture> p_texture) {
	const MTLTextureSwizzleChannels swizzle = [p_texture swizzle];
	if (swizzle.red == MTLTextureSwizzleRed && swizzle.green == MTLTextureSwizzleGreen && swizzle.blue == MTLTextureSwizzleBlue && swizzle.alpha == MTLTextureSwizzleAlpha) {
		return false;
	}
	if ([p_texture textureType] != MTLTextureType2D) {
		return false;
	}
	switch ([p_texture pixelFormat]) {
		case MTLPixelFormatR8Unorm:
		case MTLPixelFormatRG8Unorm:
		case MTLPixelFormatRGBA8Unorm:
		case MTLPixelFormatBGRA8Unorm:
			return true;
		default:
			return false;
	}
}

void TextureLoader::encode_copy(id<MTLCommandBuffer> p_command_buffer, id<MTLTexture> p_src, id<MTLTexture> p_dst) {
	if (!needs_swizzle_bake(p_src)) {
		id<MTLBlitCommandEncoder> blit_encoder = [p_command_buffer blitCommandEncoder];
		[blit_encoder copyFromTexture:p_src toTexture:p_dst];
		[blit_encoder endEncoding];
		return;
	}

	if (swizzle_bake_pso == nil) {
		NSError *error = nil;
		id<MTLDevice> device = [p_command_buffer device];
		id<MTLLibrary> library = [device newDefaultLibraryWithBundle:get_gdrk_bundle() error:&error];
		ERR_FAIL_NULL_MSG(library, "Failed to load the GodotRealityKit Metal library");
		id<MTLFunction> function = [library newFunctionWithName:@"bakeSwizzle"];
		ERR_FAIL_NULL_MSG(function, "Failed to find the bakeSwizzle function");
		swizzle_bake_pso = [device newComputePipelineStateWithFunction:function error:&error];
		ERR_FAIL_NULL_MSG(swizzle_bake_pso, "Failed to create the bakeSwizzle pipeline state");
	}

	const NSUInteger w = [swizzle_bake_pso threadExecutionWidth];
	const NSUInteger h = [swizzle_bake_pso maxTotalThreadsPerThreadgroup] / w;
	const NSUInteger levels = godot::MIN([p_src mipmapLevelCount], [p_dst mipmapLevelCount]);
	id<MTLComputeCommandEncoder> encoder = [p_command_buffer computeCommandEncoder];
	[encoder setComputePipelineState:swizzle_bake_pso];
	[encoder setTexture:p_src atIndex:0];
	for (NSUInteger level = 0; level < levels; level++) {
		id<MTLTexture> dst_level = [p_dst newTextureViewWithPixelFormat:[p_dst pixelFormat]
															textureType:MTLTextureType2D
																 levels:NSMakeRange(level, 1)
																 slices:NSMakeRange(0, 1)];
		const uint32_t level_index = (uint32_t)level;
		[encoder setTexture:dst_level atIndex:1];
		[encoder setBytes:&level_index length:sizeof(level_index) atIndex:0];
		const NSUInteger width = [dst_level width];
		const NSUInteger height = [dst_level height];
		[encoder dispatchThreadgroups:MTLSizeMake((width + w - 1) / w, (height + h - 1) / h, 1)
				threadsPerThreadgroup:MTLSizeMake(w, h, 1)];
	}
	[encoder endEncoding];
}

uint32_t TextureLoader::find_or_add(godot::RID p_texture_rid, godot::Ref<godot::Texture2D> p_texture, TextureUsage p_usage) {
	uint32_t idx = UINT32_MAX;

	if (texture_rid_to_idx.has(p_texture_rid)) {
		idx = texture_rid_to_idx.get(p_texture_rid);
		Texture &texture = textures[idx];

		if (texture.ready_for(p_usage)) {
			return idx;
		}

		texture.required_usages |= p_usage;
		texture.dirty_usages |= p_usage;
	} else {
		idx = alloc_idx();

		if (p_texture.is_valid()) {
			connect_changed(p_texture.ptr(), idx);
		}

		const bool is_viewport_texture = p_texture.is_valid() && godot::Object::cast_to<godot::ViewportTexture>(p_texture.ptr()) != nullptr;

		// Purging a texture's source Metal texture after upload is opt-in per texture: set the
		// resource metadata "_gdrk_purge" to true on the Texture2D.
		const bool purge_opt_in = p_texture.is_valid() &&
				p_texture->has_meta("_gdrk_purge") &&
				p_texture->get_meta("_gdrk_purge").booleanize();

		textures[idx] = Texture{
			.required_usages = p_usage,
			.dirty_usages = p_usage,
			.is_viewport_texture = is_viewport_texture,
			.purge_after_upload = purge_opt_in,
			.texture_rid = p_texture_rid,
			.texture = p_texture,
		};

		texture_rid_to_idx.insert(p_texture_rid, idx);
	}
	mark_dirty(idx);
	return idx;
}

bool TextureLoader::update(id<MTLCommandBuffer> p_command_buffer) {
	PROFILE_FUNC_SCOPE;

	for_each_valid([&](uint32_t idx) {
		if (textures[idx].is_viewport_texture || textures[idx].dirty_usages != 0) {
			mark_dirty(idx);
		}
	});

	bool throttle_finished = for_each_dirty_throttled([&](uint32_t idx) {
		if (!is_used_in_frame(idx)) {
			return LocalBitVector::IterationResult::SKIPPED;
		}
		Texture &texture = textures[idx];
		const godot::RID texture_rid = texture.texture_rid;
		ERR_FAIL_COND_V(!texture_rid.is_valid(), LocalBitVector::IterationResult::SKIPPED);

		// A single godot::Texture2D can be bound as MTLPixelFormatR8Unorm or MTLPixelFormatR8Unorm_sRGB
		// RealityKit LowLevelTextures don't support Texture View for native color space conversion
		// To account for that, we store 2 versions for each purpose:
		//	 	- Rendering: Values are in sRGB space, this will automatically be converted in linear space the shader
		// 		- Compute: Values are already in linear space: this is mostly used for data texture
		// Having an extra texture is not a big deal, as it probably will rarely happen to use the texture for both
		// compute and rendering.
		// When calling find_or_add or find, the caller need to provide the usage (Rendering or Compute) based on their
		// internal knowledge of the use of the texture.
		uint8_t processed_usages = 0;
		for (TextureUsage usage : { TextureUsage::Rendering, TextureUsage::Compute }) {
			if (!(usage & texture.dirty_usages)) {
				continue;
			}

			// We assume that if the RD texture RID hasn't changed, then the underlying image size/format hasn't changed
			const godot::RID rd_texture_rid = rendering_server()->texture_get_rd_texture(texture_rid, usage == TextureUsage::Rendering);
			if (!rd_texture_rid.is_valid()) {
				continue;
			}
			const godot::RID existing_rid = usage == TextureUsage::Rendering ? texture.rd_texture_srgb_rid : texture.rd_texture_linear_rid;
			const uint64_t mtl_texture_u64 = rendering_device()->get_driver_resource(godot::RenderingDevice::DRIVER_RESOURCE_TEXTURE, rd_texture_rid, 0);
			if (mtl_texture_u64 == 0) {
				continue;
			}
			id<MTLTexture> src_texture = (__bridge id<MTLTexture>)(void *)mtl_texture_u64;
			if (src_texture == nil) {
				// Render target not yet available (e.g. viewport hasn't rendered its first frame).
				// Leave dirty so we retry next frame.
				return LocalBitVector::IterationResult::SKIPPED;
			}
			if (existing_rid != rd_texture_rid) {
				if ([src_texture mipmapLevelCount] <= 1) {
					godot::String texture_path = rendering_server()->texture_get_path(texture_rid);
					if (texture_path.is_empty()) {
						texture_path = "<none>";
					}

					WARN_COMPAT_MSG(godot::String(
							"No mipmaps for texture with path {0}. This texture may have aliasing artifacts when viewed on visionOS. "
							"If this is a font atlas consider enabling \"Font Generate Mipmaps\" in your project's settings.")
									.format(godot::Array{ texture_path }));
				}

				const bool bake_swizzle = needs_swizzle_bake(src_texture);
				MTLTextureUsage dst_usage = [src_texture usage];
				if (bake_swizzle) {
					dst_usage |= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
				}
				swift::Optional<GodotRealityKit::LowLevelTexture> low_level_texture =
						GodotRealityKit::LowLevelTexture::init([src_texture textureType],
								bake_swizzle ? MTLPixelFormatRGBA8Unorm : [src_texture pixelFormat],
								[src_texture width],
								[src_texture height],
								[src_texture depth],
								[src_texture mipmapLevelCount],
								[src_texture arrayLength],
								dst_usage,
								bake_swizzle ? MTLTextureSwizzleChannelsDefault : [src_texture swizzle]);

				ERR_FAIL_COND_V_MSG(low_level_texture.isNone(), LocalBitVector::IterationResult::SKIPPED, "Failed to create low level texture");

				id<MTLTexture> dst_texture = low_level_texture.get().replace(p_command_buffer);
				encode_copy(p_command_buffer, src_texture, dst_texture);

				swift::Optional<GodotRealityKit::TextureResource> resource = GodotRealityKit::TextureResource::init(low_level_texture.get());
				ERR_FAIL_COND_V(resource.isNone(), LocalBitVector::IterationResult::SKIPPED);
				if (usage == TextureUsage::Rendering) {
					texture.resource_srgb = resource.get();
					texture.rd_texture_srgb_rid = rd_texture_rid;
					ERR_FAIL_COND_V(!texture.resource_srgb.isSome(), LocalBitVector::IterationResult::SKIPPED);
				} else {
					texture.resource_linear = resource.get();
					texture.rd_texture_linear_rid = rd_texture_rid;
					ERR_FAIL_COND_V(!texture.resource_linear.isSome(), LocalBitVector::IterationResult::SKIPPED);
				}
			} else if (rd_texture_rid.is_valid()) {
				id<MTLTexture> dst_texture = nil;
				swift::Optional<GodotRealityKit::LowLevelTexture> low_level_texture = swift::Optional<GodotRealityKit::LowLevelTexture>::none();
				if (usage == TextureUsage::Rendering) {
					ERR_FAIL_COND_V(!texture.resource_srgb.isSome(), LocalBitVector::IterationResult::SKIPPED);
					dst_texture = texture.resource_srgb.lowLevelTexture().get().replace(p_command_buffer);
				} else {
					ERR_FAIL_COND_V(!texture.resource_linear.isSome(), LocalBitVector::IterationResult::SKIPPED);
					dst_texture = texture.resource_linear.lowLevelTexture().get().replace(p_command_buffer);
				}
				encode_copy(p_command_buffer, src_texture, dst_texture);
			}

			if (texture.purge_after_upload) {
				[p_command_buffer addCompletedHandler:^(id<MTLCommandBuffer> _) {
					[src_texture setPurgeableState:MTLPurgeableStateEmpty];
				}];
			}

			processed_usages |= usage;
		}

		// Downstream materials don't need to update their references to this texture
		// since the resource was updated in-place.
		texture.dirty_usages &= ~processed_usages;
		if (texture.dirty_usages == 0) {
			dirty_idxs.remove(idx);
		}
		return processed_usages ? LocalBitVector::IterationResult::PROCESSED : LocalBitVector::IterationResult::SKIPPED;
	});

	return throttle_finished;
}
