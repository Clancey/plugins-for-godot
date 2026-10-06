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

### Match the Debug and Release export templates

If you only set up the Debug export template but export in Release, Xcode shows the following compilation error:

```
The folder "xros-arm64" doesn't exist.
```

The same error occurs if you only set up the Release export template but export in Debug.

To resolve, do one of the following:
1. Build both the Debug and Release versions of the export template.
2. Export with the matching Debug or Release checkbox.
