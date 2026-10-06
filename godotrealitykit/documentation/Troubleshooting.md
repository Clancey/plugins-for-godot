## Troubleshooting

### Running in the visionOS simulator

GodotRealityKit supports the visionOS simulator. The visionOS export template and
`GodotRealityKit.xcframework` include both `xros-arm64` and `xros-arm64-simulator` slices,
so select a visionOS simulator destination in the exported Xcode project.

Hand and controller tracking aren't available in the simulator.

If Xcode shows the following error, rebuild the dependencies with `scons deps` so the
export template includes the simulator slice:

```
The folder "xros-arm64-simulator" doesn't exist.
```

### Diagnose window and scene lifecycle issues

On visionOS, Godot launches in a 2D window that GodotRealityKit replaces with a loading screen and
destroys once the volume, portal or immersive space is visible. GodotRealityKit also retires any
other Godot window the system opens or restores later, and restarts Godot's audio and focus when a
Godot window closes while the volume is frontmost.

GodotRealityKit logs each scene lifecycle event, window adoption, destruction request and audio
resume. The messages appear in the Godot output and log file with the prefix
`GodotRealityKit[scenes]:`, and in the unified system log with the subsystem
`com.apple.GodotRealityKit` and category `Scenes`. To stream them from a device or simulator, run:

```
log stream --level info --predicate 'subsystem == "com.apple.GodotRealityKit"'
```

### Check where the volume opens

`reality_kit/volume_default_placement`, `reality_kit/volume_default_size`,
`reality_kit/volume_resizable` and `reality_kit/volume_world_alignment` apply when GodotRealityKit
opens the Volumetric Window through the `GDTExtensionVolume` window that the addon's visionOS
export template declares in Godot's SwiftUI app. visionOS only applies window placement to windows
opened this way. With other export templates, GodotRealityKit opens the volume through UIKit, and
the volume opens at the system default position, farther away.

The scene log shows which path ran:

- `opened app-hosted volume: size=... placement=...`, followed by
  `volume placement closure ran; windows=[...] -> utilityPanel`, when the placement applies.
- `opening the volume through UIKit; reality_kit/volume_default_placement has no effect on this path`
  when it doesn't. The preceding line gives the reason, such as `Godot template has no GDTExtensionVolume`.
- `volume bounds W x H x D m` whenever the volume's size changes, including when the user resizes it.

### Match the Debug and Release export templates

If you only set up the Debug export template but export in Release, Xcode shows the following compilation error:

```
The folder "xros-arm64" doesn't exist.
```

The same error occurs if you only set up the Release export template but export in Debug.

To resolve, do one of the following:
1. Build both the Debug and Release versions of the export template.
2. Export with the matching Debug or Release checkbox.
