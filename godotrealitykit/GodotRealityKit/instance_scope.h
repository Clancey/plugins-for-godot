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

#include <godot_cpp/godot.hpp>

#include <cstdint>

namespace gdrk {

// Reads the host's GDTExtensionVolume class. A host that answers YES to +managesGodotScenes
// (Xogot) owns the Godot windows and the volume window, and may run several Godot instances in
// one process.
bool is_host_managed();

// Looks up the multi-instance interface functions when the host is managed. Called from the
// entry point, while the instance that is loading this library is attached.
void instance_scope_setup(GDExtensionInterfaceGetProcAddress p_get_proc_address);

// Marks the instance that loaded this library as shut down, so late callbacks skip Godot.
void instance_scope_shutdown();

// RealityKit and SwiftUI call back outside the engine's iteration. In a multi-instance host
// another Godot instance may be attached then, so each callback attaches the instance that
// loaded this library and restores the previous one. A no-op in a single-instance host.
class InstanceScope {
public:
	InstanceScope();
	~InstanceScope();

	// False once the instance has shut down; the callback must not touch Godot.
	bool is_valid() const { return valid; }

private:
	uint8_t previous_instance = 0;
	bool restore = false;
	bool valid = true;
};

} // namespace gdrk

// Attaches this library's Godot instance for the rest of the scope, or returns m_retval if the
// instance has shut down.
#define GDRK_INSTANCE_SCOPE_OR_RETURN(m_retval) \
	gdrk::InstanceScope gdrk_instance_scope;    \
	if (!gdrk_instance_scope.is_valid()) {      \
		return m_retval;                        \
	}
