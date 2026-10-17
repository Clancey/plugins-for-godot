//
//  register_types.cpp
//
//  Copyright © 2026 Apple Inc.
//

#include "register_types.h"

#include "PHASEAudioListener3D.h"
#include "PHASEOccluder3D.h"
#include "PHASEAudioStreamPlayer3D.h"
#include "PHASEManager.h"
#import "PHASEWrapper.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using godot::PHASEAudioListener3D;
using godot::PHASEOccluder3D;
using godot::PHASEAudioStreamPlayer3D;
using godot::PHASEManager;

void initialize_example_module(godot::ModuleInitializationLevel p_level) {
    if (p_level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    GDREGISTER_RUNTIME_CLASS(PHASEAudioListener3D);
    GDREGISTER_RUNTIME_CLASS(PHASEOccluder3D);
    GDREGISTER_RUNTIME_CLASS(PHASEAudioStreamPlayer3D);
    GDREGISTER_RUNTIME_CLASS(PHASEManager);
}

void uninitialize_example_module(godot::ModuleInitializationLevel p_level) {
    if (p_level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    [PHASEEngineWrapper releaseSharedInstance];
}

extern "C" {
GDExtensionBool GDE_EXPORT godotphase_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_example_module);
    init_obj.register_terminator(uninitialize_example_module);
    init_obj.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
