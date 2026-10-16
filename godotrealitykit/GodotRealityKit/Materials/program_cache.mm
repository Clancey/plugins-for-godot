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

#import "program_cache.h"
#import "bridge.h"

#import "base_material_builder.h"
#import "node_defs.h"
#import "snippets.h"
#import "visual_program_builder.h"
#include "instance_scope.h"

#include <godot_cpp/classes/file_access.hpp>

static GodotRealityKit::SGLMaterial broken_material = GodotRealityKit::SGLMaterial::brokenMaterial();

namespace gdrk {

ProgramCache::ProgramCache(ProgramLoadedCallback &&callback, const char *p_export_directory) :
		notify_program_loaded(std::move(callback)), compiler(GodotRealityKit::Compiler::init(get_node_def_files())), export_directory(p_export_directory) {
}

godot::String ProgramCache::read_file(godot::String p_path) const {
	godot::Ref<godot::FileAccess> file = godot::FileAccess::open(p_path, godot::FileAccess::READ);
	if (!file.is_valid()) {
		return "";
	}

	return file->get_as_text();
}

godot::String ProgramCache::read_from_cache(godot::String p_path) const {
	godot::String prefix = export_directory + godot::String("/");
	godot::String cache_path = p_path.replace("res://", prefix);
	return read_file(cache_path);
}

uint32_t ProgramCache::load_usda(ProgramDescription &&p_desc, swift::String &content, ProgramLoadedCallback &&p_finalize_callback) {
	const uint32_t program_idx = programs.size();
	programs.push_back(Program());
	program_descriptions.push_back(std::move(p_desc));
	program_loading_idxs.resize(programs.size());
	program_loading_idxs.insert(program_idx);

	GodotRealityKit::SGLProgram::load("/bm", content,
			GDRKMaterialLoadDelegate([this, program_idx, finalize = std::move(p_finalize_callback)](void *p_material_load_result) {
				GDRK_INSTANCE_SCOPE_OR_RETURN();
				GodotRealityKit::SGLMaterialLoadResult material_load_result =
						GodotRealityKit::SGLMaterialLoadResult::fromRawPointer(p_material_load_result);

				gdrk::emplace_replace(&programs[program_idx].value, material_load_result.getResult());
				program_loading_idxs.remove(program_idx);

				if (material_load_result.getErrorDescription().isSome()) {
					GodotRealityKit::errPrint(material_load_result.getErrorDescription().getSome());
				}

				notify_program_loaded(program_idx);
				finalize(program_idx);
			}));
	return program_idx;
}

uint32_t ProgramCache::make_usda(ProgramDescription &&p_desc,
		const swift::Array<GodotRealityKit::ProgramPart> &p_program_parts,
		ProgramLoadedCallback &&p_finalize_callback) {
	swift::Optional<swift::String> program_usda = compiler.get().compile(p_program_parts);
	if (program_usda.isNone()) {
		return UINT32_MAX;
	}

	swift::String usda = program_usda.get();
	uint32_t program_index = load_usda(std::move(p_desc), usda, std::move(p_finalize_callback));
	program_description_to_idx.insert(p_desc.hash, program_index);

	return program_index;
}

uint32_t ProgramCache::load_usda_from_file(ProgramDescription &&p_desc,
		godot::String p_resource_path,
		ProgramLoadedCallback &&p_finalize_callback) {
	godot::String usda_content = read_from_cache(p_resource_path);
	if (usda_content.length() == 0) {
		ERR_PRINT(std::format("Failed to load USDA associated with {} from cache directory", to_std_string(p_resource_path)).c_str());
		return UINT32_MAX;
	}
	swift::String usda = to_swift_string(usda_content);
	uint32_t program_index = load_usda(std::move(p_desc), usda, std::move(p_finalize_callback));
	program_description_to_idx.insert(p_desc.hash, program_index);

	return program_index;
}

uint32_t ProgramCache::create_program_async(const ShaderMaterialDescription &p_description) {
	godot::Ref<godot::VisualShader> shader = p_description.shader;
	if (!shader.is_valid()) {
		return UINT32_MAX;
	}

	godot::String resource_path = shader->get_path();
	godot::String metadata_string = read_from_cache(resource_path + ".meta.json");
	ProgramDescription desc(p_description);

	if (loading_mode != LoadingMode::DISABLE_CACHE && metadata_string.length() != 0) {
		VisualProgramMetadata meta;
		bool success = VisualProgramMetadata::unserialize(metadata_string, shader, meta);
		if (success) {
			desc.asShaderMaterial().uniforms = meta.uniforms;
			desc.asShaderMaterial().transparent = meta.is_transparent;

			uint32_t res = load_usda_from_file(std::move(desc), resource_path + ".usda", [=](uint32_t program_index) {
				VisualProgramBuilder::finalize(program_descriptions[program_index].asShaderMaterial(), programs[program_index].value);
			});

			if (res != UINT32_MAX) {
				return res;
			}
		}
	}

	if (loading_mode == LoadingMode::FORCE_CACHE) {
		return UINT32_MAX;
	}

	VisualProgramBuilder builder(compiler, p_description);
	swift::Array<GodotRealityKit::ProgramPart> program_parts = swift::Array<GodotRealityKit::ProgramPart>::init();
	bool success = builder.build(program_parts);
	if (!success) {
		return UINT32_MAX;
	}
	VisualProgramMetadata meta = builder.get_metadata();
	desc.asShaderMaterial().uniforms = meta.uniforms;
	desc.asShaderMaterial().transparent = meta.is_transparent;
	return make_usda(std::move(desc), program_parts, [=](uint32_t program_index) {
		VisualProgramBuilder::finalize(program_descriptions[program_index].asShaderMaterial(), programs[program_index].value);
	});
}

uint32_t ProgramCache::create_program_async(const BaseMaterial3DDescription &p_program_description) {
	BaseMaterialBuilder builder(compiler, p_program_description);
	swift::Array<GodotRealityKit::ProgramPart> program_parts = swift::Array<GodotRealityKit::ProgramPart>::init();
	bool success = builder.build(program_parts);
	if (!success) {
		return UINT32_MAX;
	}

	return make_usda(ProgramDescription(p_program_description), program_parts, [&](uint32_t program_index) {
		BaseMaterialBuilder::finalize(program_descriptions[program_index].asBaseMaterial3D(), programs[program_index].value);
	});
}

uint32_t ProgramCache::create_program_async(const ProgramDescription &p_program_description) {
	if (compiler.isNone()) {
		return UINT32_MAX;
	}

	if (auto found_program = program_description_to_idx.find(p_program_description.hash)) {
		return found_program->value;
	}

	uint32_t index = UINT32_MAX;
	if (p_program_description.material_type == MATERIAL_TYPE_BASE_MATERIAL3D) {
		index = create_program_async(p_program_description.asBaseMaterial3D());
	} else if (p_program_description.material_type == MATERIAL_TYPE_SHADER_MATERIAL) {
		index = create_program_async(p_program_description.asShaderMaterial());
	}

	if (index == UINT32_MAX) {
		index = create_broken_program_async();
	}

	return index;
}

#if DEBUG
#define _SG_VALIDATE                                                                \
	ERR_FAIL_COND_V_MSG(compiler.get().compile(program_parts).isNone(), UINT32_MAX, \
			"Unable to generate invalid material ShaderGraph: error validating snippet");
#else
#define _SG_VALIDATE
#endif

#define SG(snippet)                                                                                      \
	{                                                                                                    \
		swift::String snippet_string = #snippet;                                                         \
		swift::Optional<GodotRealityKit::ProgramPart> part = compiler.get().parse(snippet_string, true); \
		if (!part.isNone()) {                                                                            \
			program_parts.append(part.get());                                                            \
			_SG_VALIDATE                                                                                 \
		} else {                                                                                         \
			return UINT32_MAX;                                                                           \
		}                                                                                                \
	}

#define SG_DECLARATIONS(val)                                                                             \
	{                                                                                                    \
		swift::String snippet_string = sgl::builtin::val();                                              \
		swift::Optional<GodotRealityKit::ProgramPart> part = compiler.get().parse(snippet_string, true); \
		if (!part.isNone()) {                                                                            \
			program_parts.append(part.get());                                                            \
			_SG_VALIDATE                                                                                 \
		} else {                                                                                         \
			return UINT32_MAX;                                                                           \
		}                                                                                                \
	}

uint32_t ProgramCache::create_broken_program_async() {
	if (broken_material_index != UINT32_MAX) {
		return broken_material_index;
	}

	if (compiler.isNone()) {
		return UINT32_MAX;
	}

	swift::Array<GodotRealityKit::ProgramPart> program_parts = swift::Array<GodotRealityKit::ProgramPart>::init();

	SG_DECLARATIONS(utility_functions);
	SG_DECLARATIONS(swizzle);
	SG_DECLARATIONS(constants);
	SG_DECLARATIONS(vertex::attributes);

	SG(
			let geometry_modifier = ND_realitykit_geometrymodifier_2_0_vertexshader(-, -, normal_attribute, bitangent_attribute);)

	SG(
			let scaled_position = ND_multiply_vector3(position_attribute, (10.0f, 10.0f, 10.0f));
			let u_step = ND_round_float(ND_dotproduct_vector3(scaled_position, (1.0f, 1.0f, 1.0f)));
			let u_mix = ND_modulo_float(u_step, 2.0f);
			let base_color = ND_mix_color3((0.7h, 0.7h, 0.7h)c, (1.0h, 1.0h, 1.0h)c, u_mix);
			let surface_shader = ND_realitykit_pbr_surfaceshader(base_color);)

	SG(
			(geometry_modifier, surface_shader);)

	broken_material_index = make_usda(ProgramDescription(), program_parts, [&](uint32_t program_index) {
		programs[program_index].value.setIsBrokenMateiral(true);
	});

	return broken_material_index;
}

GodotRealityKit::SGLMaterial ProgramCache::create_material(uint32_t p_program_idx, godot::RID p_material_rid) {
	ERR_FAIL_COND_V(program_loading_idxs.has(p_program_idx), broken_material);
	const ProgramDescription &program_description = program_descriptions[p_program_idx];
	GodotRealityKit::SGLProgram program = programs[p_program_idx].value;
	GodotRealityKit::SGLMaterial material = program.instantiate();
	return material;
}

void ProgramCache::update() {
}

} // namespace gdrk
