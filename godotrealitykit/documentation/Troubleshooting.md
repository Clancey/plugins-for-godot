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

### Match the Debug and Release export templates

If you only set up the Debug export template but export in Release, Xcode shows the following compilation error:

```
The folder "xros-arm64" doesn't exist.
```

The same error occurs if you only set up the Release export template but export in Debug.

To resolve, do one of the following:
1. Build both the Debug and Release versions of the export template.
2. Export with the matching Debug or Release checkbox.
