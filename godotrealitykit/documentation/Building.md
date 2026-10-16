## Prerequisites

- macOS with [Xcode](https://developer.apple.com/xcode/) installed (including the visionOS SDK)
    - Use the visionOS 27 SDK
    - The Metal toolchain is required to build Godot. Install it with `xcodebuild -downloadComponent metalToolchain`.
- [SCons](https://scons.org/) build system: `python3 -m pip install scons` or `brew install scons`
- Python 3.x

## Building the Plugin

GodotRealityKit depends on custom forks of Godot and [godot-cpp](https://github.com/godotengine/godot-cpp). Their URLs and branches are configured in `deps.conf`:

```ini
# Option 1: Specify repository URLs to clone and build from source (default)
GODOT_URL=<godot git repository URL>
GODOT_BRANCH=<godot commit or branch>
GODOT_CPP_URL=<godot-cpp git repository URL>
GODOT_CPP_BRANCH=<godot-cpp commit or branch>

# Option 2: Use an existing shared workspace with pre-built deps
SHARED_WORKSPACE=../../shared_workspace
```

Running `scons` with no arguments builds everything: builds dependencies (if not already present), builds the macOS editor framework and visionOS template framework, assembles the addon, and generates documentation.

```sh
scons
```

The addon is produced at `out/addons/GodotRealityKit/`.

To build with a release configuration:

```sh
scons config=release
```

### Individual build targets

| Command | Description |
|---|---|
| `scons deps` | Clone and build Godot + godot-cpp only |
| `scons framework platform=macos` | Build macOS framework only |
| `scons framework platform=visionos` | Build visionOS framework only (device + simulator, packaged as an XCFramework) |
| `scons addon` | Assemble addon for distribution |
| `scons docs` | Regenerate `doc_data.gen.cpp` from `doc_classes/*.xml` and rebuild the frameworks to embed the updated docs |

## Addon Structure

```
addons/GodotRealityKit/
    GodotRealityKit.gdextension
    plugin.cfg
    gdrk.gd
    gdrk_export.gd
    volume_camera_gizmo/
    directional_light_shadow_gizmo/
    macos.editor/                # or macos.template_release with config=release
        GodotRealityKit.framework
        godot_macos.zip
    macos.template_debug -> macos.editor
    visionos.template_debug/     # or visionos.template_release with config=release
        GodotRealityKit.xcframework  # xros-arm64 + xros-arm64-simulator
        godot_visionos.zip
```

## Building for Xogot

[Xogot](https://xogot.com) runs the Godot editor and the game as two Godot 4.8 instances in one visionOS process, and hosts the game's volume in its own window. Build the plugin against Xogot's engine (branch `xogot-main-4.8-multi-visionos` of xibbon/godot-ios), not against the engine in `deps.conf`, using a shared workspace:

```sh
GDRK=$PWD
ENGINE=<Xogot checkout>/godot-multi-instance
DEPS=$GDRK/out/xogot_workspace/deps/debug
CPP_COMMIT=$(sed -n 's/^GODOT_CPP_BRANCH=//p' deps.conf)
mkdir -p $DEPS
ln -s $ENGINE $DEPS/godot
(cd $ENGINE && make update-api)
cp $ENGINE/extension_api.json $DEPS/
git clone https://github.com/godotengine/godot-cpp.git $DEPS/godot-cpp
git -C $DEPS/godot-cpp checkout $CPP_COMMIT
git -C $DEPS/godot-cpp apply $GDRK/patches/godot-cpp/*.patch
cd $DEPS/godot-cpp
scons platform=visionos target=template_debug custom_api_file=$DEPS/extension_api.json custom_tools=$GDRK/tools use_hot_reload=no
scons platform=visionos target=template_debug visionos_simulator=yes custom_api_file=$DEPS/extension_api.json custom_tools=$GDRK/tools use_hot_reload=no
ln -s libgodot-cpp.visionos.template_debug.arm64.a bin/libgodot-cpp.visionos.template.arm64.a
ln -s libgodot-cpp.visionos.template_debug.arm64.simulator.a bin/libgodot-cpp.visionos.template.arm64.simulator.a
cd $GDRK
SHARED_WORKSPACE=out/xogot_workspace scons framework platform=visionos
```

The godot-cpp patch in `patches/godot-cpp/` is required in Xogot. Xogot initializes the library again for each game it plays, against a new engine instance, while the library image stays loaded. Without the patch, godot-cpp keeps the method binds and class registrations of the previous instance. `scons deps` applies the patches automatically; a shared workspace must apply them as shown above.

Copy the resulting `out/workspace/build/visionOS/Debug/GodotRealityKit.xcframework` into the game's `addons/GodotRealityKit/visionos.template_debug/`. When Xogot hosts the plugin, `GDTExtensionVolume.managesGodotScenes` returns `YES`: Xogot drives the Godot instance loop and owns the volume window, and the plugin attaches its own Godot instance around every RealityKit and SwiftUI callback.
