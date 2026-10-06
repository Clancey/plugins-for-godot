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

import RealityKit
import Spatial
import SwiftUI
@preconcurrency import GameController

#if os(macOS)
import AppKit
#else
import ARKit
import AVFoundation
import Combine
import UIKit
import os
#endif

public enum ScenePresentationStyle : String, Sendable {
    case sharedVolumetric = "shared-volumetric"
    case sharedPortal = "shared-portal"
    case immersive = "immersive"
}

public enum SceneImmersionStyle : Sendable {
    case mixed
    case full
    case progressive
}

extension RealityView {
#if os(macOS)
    public typealias Size = CGSize
#else
    public typealias Size = Size3D
#endif

#if os(macOS)
    public typealias Value = SpatialEventCollection
#else
    public typealias Value = EntityTargetValue<SpatialEventCollection>
#endif

#if os(macOS)
    private func calculateRay(delegate: GDRKBridgeDelegate?,
                              event: SpatialEventCollection.Event,
                              value: SpatialEventCollection,
                              size: CGSize) -> GDRKRay? {
        guard let rawCameraPointer = delegate?.getCameraEntity() else {
            return  nil
        }

        let camera = Unmanaged<RealityKit.Entity>.fromOpaque(rawCameraPointer).takeRetainedValue()
        if let cameraComponent = camera.components[PerspectiveCameraComponent.self] {
            let projectiveTransform = ProjectiveTransform3DFloat(
                fovY: Angle2DFloat(degrees: cameraComponent.fieldOfViewInDegrees),
                aspectRatio: Float(size.width / size.height),
                nearZ: cameraComponent.near,
                farZ: cameraComponent.far,
                reverseZ: true)

            guard let invProjectiveTransform = projectiveTransform.inverse?.matrix else {
                return nil
            }

            let locationN = (SIMD2<Double>(event.location.x, event.location.y) /
                             SIMD2<Double>(size.width, size.height))
            let locationNDC = (locationN * 2.0 - 1.0) * SIMD2<Double>(1.0, -1.0)
            let locationH = invProjectiveTransform *
            simd_float4(Float(locationNDC.x), Float(locationNDC.y), 1.0, 1.0)
            let direction3D = SIMD3<Float>(locationH.x / locationH.w,
                                           locationH.y / locationH.w,
                                           locationH.z / locationH.w)
            let worldDirection4D = camera.transform.matrix * SIMD4<Float>(direction3D.x, direction3D.y, direction3D.z, 0.0)
            let worldDirection3D = simd_normalize(SIMD3<Float>(worldDirection4D.x, worldDirection4D.y, worldDirection4D.z))

            return GDRKRay(origin: camera.transform.translation, direction: worldDirection3D)
        } else if let cameraComponent = camera.components[OrthographicCameraComponent.self] {
            let aspectRatio = Float(size.width / size.height)
            let locationN = (SIMD2<Double>(event.location.x, event.location.y) /
                             SIMD2<Double>(size.width, size.height))
            let locationNDC = (locationN - 0.5) * SIMD2<Double>(1.0, -1.0)

            let locationScaled: SIMD2<Float>
            if cameraComponent.scaleDirection == .horizontal {
                locationScaled = SIMD2<Float>(Float(locationNDC.x) * cameraComponent.scale,
                                              Float(locationNDC.y) * cameraComponent.scale / aspectRatio)
            } else {
                locationScaled = SIMD2<Float>(Float(locationNDC.x) * cameraComponent.scale * aspectRatio,
                                              Float(locationNDC.y) * cameraComponent.scale)
            }

            let worldLocation4D = camera.transform.matrix * SIMD4<Float>(locationScaled.x, locationScaled.y, 0.0, 1.0)
            let worldLocation3D = SIMD3<Float>(worldLocation4D.x, worldLocation4D.y, worldLocation4D.z)
            let worldDirection4D = camera.transform.matrix * SIMD4<Float>(0.0, 0.0, 1.0, 0.0)
            let worldDirection3D = SIMD3<Float>(worldDirection4D.x, worldDirection4D.y, worldDirection4D.z)
            return GDRKRay(origin: worldLocation3D, direction: worldDirection3D)
        } else {
            return nil
        }
    }
#else
    private func calculateRay(delegate: GDRKBridgeDelegate?,
                              event: SpatialEventCollection.Event,
                              value: EntityTargetValue<SpatialEventCollection>,
                              size: Size3D) -> GDRKRay? {
		let origin = value.convert(Point3D(x: event.location.x, y: event.location.y, z: 0.0), from: .local, to: .scene)
        let direction = normalize(value.convert(Vector3D(x: 0.0, y: 0.0, z: 1.0), from: .local, to: .scene))
        return GDRKRay(origin: origin, direction: direction)
    }
#endif

    private func findHit(hits: [CollisionCastHit], position: SIMD3<Float>?) -> CollisionCastHit? {
        guard let position = position else {
            return hits.first
        }

        return hits.reduce(Optional<(CollisionCastHit, Float)>(nil)) { best, hit in
            let distance = distance_squared(position, hit.position)
            if let (_, bestDistance) = best {
                return distance < bestDistance ? (hit, distance) : best
            } else {
                return (hit, distance)
            }
        }?.0
    }

    private func handleEvent(event: SpatialEventCollection.Event, value: Value, delegate: GDRKBridgeDelegate?, root: RealityKit.Entity, size: Size, ended: Bool) {
        let eventID = event.id.hashValue

#if os(macOS)
        let position3D: SIMD3<Float>? = nil
#else
        let position3D: SIMD3<Float>? = value.convert(event.location3D, from: .local, to: .scene)
#endif

        guard let ray = self.calculateRay(delegate: delegate, event: event, value: value, size: size) else {
            return
        }

        guard let hits = root.scene?.raycast(origin: ray.origin, direction: ray.direction) else {
            return
        }

        let hit = self.findHit(hits: hits, position: position3D)

#if os(macOS)
        let entityID = hit?.entity.id ?? 0
#else
        let entityID = event.targetedEntity?.id ?? 0
#endif

#if os(macOS)
        let inputDevicePose: GDRKPose? = nil
#else
        let inputDevicePose = (event.inputDevicePose?.pose3D).map{ pose in
            let poseTransform = Transform(scale: SIMD3<Float>(repeating: 1.0),
                                          rotation: value.convert(pose.rotation, from: .local, to: .scene),
                                          translation: value.convert(pose.position, from: .local, to: .scene))

            let godotPoseTransform = root.convert(transform: poseTransform, from: nil)
            return GDRKPose(position: godotPoseTransform.translation, orientation: godotPoseTransform.rotation)
        }
#endif

#if os(macOS)
        let selectionRay: GDRKRay? = nil
#else
        let selectionRay = event.selectionRay.map{ ray in
            return GDRKRay(origin: root.convert(position: value.convert(ray.origin, from: .local, to: .scene), from: nil),
                         direction: root.convert(direction: value.convert(ray.direction, from: .local, to: .scene), from: nil))
        }
#endif

#if os(macOS)
        let chirality: UInt32? = nil
#else
        let chirality = event.chirality.map{ chirality in
            chirality == .left ? UInt32(0) : UInt32(1)
        }
#endif

        delegate?.onEntityPressUpdate(Int64(eventID),
                                      ended,
                                      UInt64(entityID),
                                      position3D.map{ root.convert(position: $0, from: nil) } ?? SIMD3<Float>(),
                                      (hit?.position).map{ root.convert(position: $0, from: nil) } ?? SIMD3<Float>(),
                                      (hit?.normal).map{ normalize(root.convert(normal: $0, from: nil)) } ?? SIMD3<Float>(),
                                      Int64(hit?.shapeIndex ?? -1),
                                      inputDevicePose != nil,
                                      inputDevicePose ?? GDRKPose(),
                                      selectionRay != nil,
                                      selectionRay ?? GDRKRay(),
                                      chirality != nil,
                                      chirality ?? UInt32(1))
    }

    private func spatialEventGesture(delegate: GDRKBridgeDelegate?, root: RealityKit.Entity, size: Size) -> some Gesture {
        SpatialEventGesture()
#if !os(macOS)
            .targetedToAnyEntity()
#endif
            .onChanged{ value in

#if os(macOS)
                let events = value
#else
                let events = value.gestureValue
#endif

                for event in events {
                    self.handleEvent(event: event, value: value, delegate: delegate, root: root, size: size, ended: false)
                }
            }
            .onEnded{ value in

#if os(macOS)
                let events = value
#else
                let events = value.gestureValue
#endif

                for event in events {
                    self.handleEvent(event: event, value: value, delegate: delegate, root: root, size: size, ended: true)
                }
            }
    }

    func installGestures(delegate: GDRKBridgeDelegate?, root: RealityKit.Entity, size: Size) -> some View {
        self.simultaneousGesture(self.spatialEventGesture(delegate: delegate, root: root, size: size))
    }
}

#if !os(macOS)

// Stores the bounds of the Swift UI View in RealityKit scene space
class PortalRealityViewState {
    var lastViewBounds: BoundingBox? = nil
    var lastCageScale: Float? = nil
}

// Workaround for : RealityKit's RealityView does not receive
// .handlesGameControllerEvents when the gaze target is inside the view (e.g.
// the portal surface), because the GC input remote effect is applied on a
// layer upstream from the CA hit-test leaf. A collision cage around the view
// provides a valid hit-test destination so gamepad events reach the app.
private func createGamepadInputCagePlane(
        size: SIMD3<Float>,
        position: SIMD3<Float>) -> RealityKit.Entity {
    let entity = RealityKit.Entity()
    entity.position = position
    var collision = CollisionComponent(shapes: [.generateBox(size: size)], mode: .trigger)
    collision.isStatic = true
    entity.components.set(collision)
    entity.components.set(InputTargetComponent(allowedInputTypes: .all))
    return entity
}

private func createGamepadInputCage(size: SIMD3<Float>, thickness: Float = 0.01) -> RealityKit.Entity {
    let halfSize = size / 2
    let halfThickness = thickness / 2
    let container = RealityKit.Entity()

    let frontBackSize = SIMD3<Float>(size.x, size.y, thickness)
    let leftRightSize = SIMD3<Float>(thickness, size.y, size.z)
    let topBottomSize = SIMD3<Float>(size.x, thickness, size.z)

    container.addChild(createGamepadInputCagePlane(size: frontBackSize,
            position: SIMD3(0, 0, halfSize.z - halfThickness)))
    container.addChild(createGamepadInputCagePlane(size: frontBackSize,
            position: SIMD3(0, 0, -halfSize.z + halfThickness)))
    container.addChild(createGamepadInputCagePlane(size: leftRightSize,
            position: SIMD3(-halfSize.x + halfThickness, 0, 0)))
    container.addChild(createGamepadInputCagePlane(size: leftRightSize,
            position: SIMD3(halfSize.x - halfThickness, 0, 0)))
    container.addChild(createGamepadInputCagePlane(size: topBottomSize,
            position: SIMD3(0, halfSize.y - halfThickness, 0)))
    container.addChild(createGamepadInputCagePlane(size: topBottomSize,
            position: SIMD3(0, -halfSize.y + halfThickness, 0)))
    return container
}

// Shows a 2D portal into the game in place of Godot's Camera3D
struct PortalRealityView : View {
    let root: RealityKit.Entity
    let delegate: GDRKBridgeDelegate?

    let portal = RealityKit.Entity()
    let state = PortalRealityViewState()

    @State private var subscription: EventSubscription? = nil

    @State private var worldScaleExponent: Float = -1; // 1/10 of the size

    @Environment(\.physicalMetrics) private var physicalMetrics

    @State private var interactionTarget: RealityKit.Entity?

    var worldScale: Float {
        let fixedWorldScale = self.fixedWorldScale
        if fixedWorldScale != 0 {
            return fixedWorldScale
        }
        return 1.0 / pow(10.0, self.worldScaleExponent)
    }

    // Set via reality_kit/portal_presentation_world_scale; 0 means unset, use the interactive slider instead.
    private var fixedWorldScale: Float {
        delegate?.getExtensionSettings().portalWorldScale ?? 0
    }

    private var handlesGameControllerEvents: Bool {
        delegate?.getExtensionSettings().handlesGameControllerEvents ?? true
    }

    private func updateInteractionTarget(_ target: RealityKit.Entity, in proxy: GeometryProxy3D) {
        let size = physicalMetrics.convert(proxy.size, to: .meters)
        let minimumDimension: CGFloat = 1.0
        let maxDimension = Swift.max(size.width, Swift.max(size.height, size.depth))
        let scale = Float(Swift.max(maxDimension, minimumDimension))
        if state.lastCageScale != scale {
            target.transform.scale = SIMD3(repeating: scale)
            state.lastCageScale = scale
        }
    }

    public var body: some View {
        GeometryReader3D{ proxy in
            RealityView(make: { content in
                self.root.components.set(WorldComponent())

                self.portal.components.set(PortalComponent(target: self.root))

                content.add(self.root)
                content.add(self.portal)
                if self.handlesGameControllerEvents {
                    let cage = createGamepadInputCage(size: SIMD3<Float>(0.94, 0.43, 0.40))
                    content.add(cage)
                    self.updateInteractionTarget(cage, in: proxy)
                    self.interactionTarget = cage
                }

                self.subscription = content.subscribe(to: SceneEvents.Update.self, self.onSceneUpdate)
                self.delegate?.onWorldScaleChanged(self.worldScale)
            }, update: { content in
                let viewBounds = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                if self.state.lastViewBounds != viewBounds {
                    let portalMesh = RealityKit.MeshResource.generatePlane(width: viewBounds.extents.x,
                                                                           height: viewBounds.extents.y,
                                                                           cornerRadius: 0.02)
                    let portalModel = ModelComponent(mesh: portalMesh,
                                                     materials: [PortalMaterial()])
                    self.portal.components[ModelComponent.self] = portalModel
                    self.state.lastViewBounds = viewBounds
                }

                if let target = self.interactionTarget {
                    self.updateInteractionTarget(target, in: proxy)
                }

                self.delegate?.onWindowResized(simd_float3(proxy.size.vector))
            })
            .installGestures(delegate: self.delegate, root: self.root, size: proxy.size)
            .setupProjectSettings(from: delegate, portalMode: true)
            .offset(z: -(proxy.size.depth / 2) + 1)
            .realityViewLayoutBehavior(.centered)
        }
        if self.fixedWorldScale == 0 {
            Slider(value: $worldScaleExponent, in: -8.0 ... 8.0, label: { Text("World Scale") })
                .padding()
                .onChange(of: self.worldScale) {
                    self.delegate?.onWorldScaleChanged(self.worldScale)
                }
        }
    }

    private func onSceneUpdate(event: SceneEvents.Update) {
        self.updateCamera()
    }

    private func updateCamera() {

        if let rawCameraPointer = delegate?.getCameraEntity() {
            let camera = Unmanaged<RealityKit.Entity>.fromOpaque(rawCameraPointer).takeRetainedValue()
            let invWorldScale = SIMD3<Float>(repeating: Float(1.0 / self.worldScale));
            let normalized = Transform(scale: invWorldScale * camera.transform.scale,
                                       rotation: camera.transform.rotation,
                                       translation: camera.transform.translation)
            self.root.components[Transform.self] = Transform(matrix: normalized.matrix.inverse)
        } else {
            self.root.components[Transform.self] = Transform()
        }
    }
}

extension SwiftUI.View {
    // In portal mode, pair with a collision cage () so gamepad
    // events are delivered even when the gaze target is inside the RealityView.
    func setupProjectSettings(from delegate: GDRKBridgeDelegate?, portalMode: Bool = false) -> some View {
        let handles = delegate?.getExtensionSettings().handlesGameControllerEvents ?? true
        return self.handlesGameControllerEvents(
            matching: handles ? .gamepad : [],
            withOptions: (handles && portalMode) ? .receivesEventsInView(false) : nil)
    }
}

@Observable
class ImmersiveRealityViewState {
    @MainActor static let shared = ImmersiveRealityViewState()
    var lastScale: SIMD3<Float>? = nil
    var hasInputTargets: Bool = false
}

// Shows the Godot scene in an immersive space
struct ImmersiveRealityView : View {
    let root: RealityKit.Entity
    let delegate: GDRKBridgeDelegate?
    
    let state = ImmersiveRealityViewState()

    @State private var subscription: EventSubscription? = nil

    public var body: some View {
        // Read sceneReady so toggling it triggers a body re-evaluation.
        let _ = state.hasInputTargets
        GeometryReader3D{ proxy in
            RealityView(make: { content in
                content.add(self.root)
                self.subscription = content.subscribe(to: SceneEvents.Update.self, self.onSceneUpdate)
            }, update: { content in
            })
            .installGestures(delegate: self.delegate, root: self.root, size: proxy.size)
            .setupProjectSettings(from: delegate)
        }
    }

    private func onSceneUpdate(event: SceneEvents.Update) {
        if let xrOrigin = delegate?.getXROrigin() {
            if xrOrigin.scale != state.lastScale {
                // Assuming all scale components are the same
                delegate?.onWorldScaleChanged(xrOrigin.scale.min())
                state.lastScale = xrOrigin.scale
            }

            let worldScale = xrOrigin.scale
            let worldRotation = xrOrigin.orientation.inverse
            let worldTranslation = -worldScale * simd_act(worldRotation, xrOrigin.position)
            self.root.components.set(Transform(scale: worldScale, rotation: worldRotation, translation: worldTranslation))
        }
    }
}

class SharedVolumetricRealityViewState {
    var lastCameraTransform: Transform? = nil
    var lastViewBounds: BoundingBox? = nil
    var lastScale: Float? = nil

    // Spatial-accessory anchoring state.
    var spatialTrackingSession: SpatialTrackingSession? = nil
    var connectObserver: NSObjectProtocol? = nil
    var pendingControllers: [GCController] = []
    // An AnchorEntity(.accessory) resolves asynchronously, but content.add() has to run
    // synchronously in the update closure, so resolved anchors wait here until the next tick.
    var resolvedAnchors: [ControllerHand: AnchorEntity] = [:]
    var anchors: [ControllerHand: AnchorEntity] = [:]
    // The GCController anchored per hand, polled each frame for button / thumbstick input.
    var controllers: [ControllerHand: GCController] = [:]
    var trackingStarted: Bool = false
}

// Shows the Godot scene in a volumetric window.
// If the scene has a RealityVolumeCamera3D it shows what is inside the volume camera,
// scaled to fit the volumetric window.
// otherwise it scales down the whole world to fit in the volumetric window
struct SharedVolumetricRealityView : View {
    let root: RealityKit.Entity
    let delegate: GDRKBridgeDelegate?

    let anchor = RealityKit.Entity()

    let state = SharedVolumetricRealityViewState()

    @State private var subscription: EventSubscription? = nil

    public var body: some View {
        GeometryReader3D{
            proxy in
                RealityView(make: { content in
                    self.anchor.addChild(self.root)
                    content.add(self.anchor)
                    self.subscription = content.subscribe(to: SceneEvents.Update.self, self.onSceneUpdate)
            }, update: { content in
                   let viewBounds = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                   self.updateCamera(viewBounds: viewBounds)
                   self.delegate?.onWindowResized(simd_float3(proxy.size.vector))
                   self.updateAccessoryAnchors(content: content)
            })
             .installGestures(delegate: self.delegate, root: self.root, size: proxy.size)
            .realityViewLayoutBehavior(.flexible)
            .setupProjectSettings(from: delegate)
        }
    }

    // Keeps an AnchorEntity(.accessory) attached to each connected spatial controller. Runs only
    // while the engine's shared-volume controller interface is live, which is what keeps
    // accessory tracking off in other presentation styles and when controller tracking is
    // disabled.
    private func updateAccessoryAnchors(content: RealityViewContent) {
        guard self.delegate?.wantsControllerAnchors() ?? false else { return }

        self.startAccessoryTrackingIfNeeded()

        for (hand, anchor) in self.state.resolvedAnchors {
            // Each connect gives the controller a new accessory identity, so the newest resolved
            // anchor replaces what is installed; the one it replaces can no longer track.
            if let stale = self.state.anchors[hand] {
                content.remove(stale)
            }
            content.add(anchor)
            self.state.anchors[hand] = anchor
        }
        self.state.resolvedAnchors.removeAll()

        self.resolvePendingControllers()
    }

    // Starts the accessory tracking session and queues the spatial controllers for anchoring;
    // an AnchorEntity(.accessory) only resolves once a live session is running.
    private func startAccessoryTrackingIfNeeded() {
        guard !self.state.trackingStarted else { return }
        self.state.trackingStarted = true

        Task { @MainActor in
            let session = SpatialTrackingSession()
            _ = await session.run(SpatialTrackingSession.Configuration(tracking: [.accessory]))
            self.state.spatialTrackingSession = session
        }

        self.state.connectObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { notification in
            guard let controller = notification.object as? GCController,
                  controller.productCategory == GCProductCategorySpatialController else { return }
            self.state.pendingControllers.append(controller)
        }

        for controller in GCController.controllers()
        where controller.productCategory == GCProductCategorySpatialController {
            self.state.pendingControllers.append(controller)
        }
    }

    // Resolves an anchoring source per queued controller and stages the resulting anchor for the
    // next update tick.
    private func resolvePendingControllers() {
        guard !self.state.pendingControllers.isEmpty else { return }
        let controllers = self.state.pendingControllers
        self.state.pendingControllers.removeAll()

        for controller in controllers {
            Task { @MainActor in
                do {
                    let source = try await AnchoringComponent.AccessoryAnchoringSource(device: controller)
                    guard let hand = Self.hand(of: source) else {
                        NSLog("[GDRK] accessory anchor: controller reports no chirality; ignoring")
                        return
                    }
                    // The startup scan and the connect notification can queue the same controller
                    // twice, so bail if this device is anchored — but let a different one replace it.
                    if let anchored = self.state.controllers[hand], anchored === controller {
                        return
                    }
                    guard let location = source.locationName(named: "grip") else {
                        NSLog("[GDRK] accessory anchor: no 'grip' location for controller")
                        return
                    }
                    self.state.resolvedAnchors[hand] = AnchorEntity(.accessory(from: source, location: location),
                                                                    trackingMode: .predicted)
                    self.state.controllers[hand] = controller
                } catch {
                    NSLog("[GDRK] AccessoryAnchoringSource init failed: \(error)")
                }
            }
        }
    }

    // Spatial controllers come as a handed pair, so the accessory's inherent chirality is the
    // hand it is held in.
    private static func hand(of source: AnchoringComponent.AccessoryAnchoringSource) -> ControllerHand? {
        switch source.underlyingAccessory?.inherentChirality {
        case .left: return .leftHand
        case .right: return .rightHand
        default: return nil
        }
    }

    // Pushes each anchored controller's scene-root-local transform to the engine, once per frame.
    private func publishControllerPoses() {
        guard let delegate = self.delegate, !self.state.anchors.isEmpty else { return }

        for (hand, anchor) in self.state.anchors {
            let t = Transform(matrix: anchor.transformMatrix(relativeTo: self.root))
            delegate.setControllerAnchor(hand, GDRKTransform(
                scale: t.scale,
                position: t.translation,
                orientation: t.rotation
            ), anchor.isAnchored)
        }
    }

    // Pushes each anchored controller to the engine once per frame; the engine samples its
    // buttons / thumbstick (via GameController) so XRController3D's button_pressed keeps working.
    private func publishControllerInputs() {
        guard let delegate = self.delegate, !self.state.controllers.isEmpty else { return }

        for (hand, controller) in self.state.controllers {
            delegate.setControllerInput(hand, Unmanaged.passUnretained(controller).toOpaque())
        }
    }

    private func onSceneUpdate(event: SceneEvents.Update) {
        if let viewBounds = self.state.lastViewBounds {
            self.updateCamera(viewBounds: viewBounds)
        }
        self.publishControllerPoses()
        self.publishControllerInputs()
    }

    private func updateCamera(viewBounds: BoundingBox) {
        var cameraTransform: Transform! = nil
        if let rawCameraPointer = delegate?.getCameraEntity() {
            let camera = Unmanaged<RealityKit.Entity>.fromOpaque(rawCameraPointer).takeRetainedValue()
            if let volumetricCameraSize = camera.components[VolumeCameraComponent.self]?.size {
                cameraTransform = camera.transform
                cameraTransform.scale *= volumetricCameraSize;
            }
        }

        if cameraTransform == nil {
            if !self.root.children.isEmpty {
                let rootBounds = self.root.visualBounds(relativeTo: self.anchor)
                if !rootBounds.isEmpty {
                    cameraTransform = Transform(scale: rootBounds.extents,
                                                rotation: simd_quatf(ix: 0.0, iy: 0.0, iz: 0.0, r: 1.0),
                                                translation: rootBounds.center)
                } else {
                    cameraTransform = Transform()
                }
            } else {
                cameraTransform = Transform()
            }
        }

        let worldScale = (viewBounds.extents / cameraTransform.scale).min()
        let viewBoundsChanged =  self.state.lastViewBounds != viewBounds
        let scaleChanged = self.state.lastScale != worldScale

        // For now, we assume that the volume camera component size does not change.
        // We only adapt to changes in view bounds
        if self.state.lastCameraTransform?.translation != cameraTransform.translation ||
            self.state.lastCameraTransform?.rotation != cameraTransform.rotation ||
            scaleChanged || viewBoundsChanged
        {
            let worldRotation = cameraTransform.rotation.inverse
            var worldTranslation = -worldScale * simd_act(worldRotation, cameraTransform.translation)

            if scaleChanged {
                self.state.lastScale = worldScale
                self.delegate?.onWorldScaleChanged(worldScale)
            }

            worldTranslation.y -= 0.5 * (viewBounds.extents.y - worldScale * cameraTransform.scale.y)

            self.anchor.components[Transform.self] = Transform(scale: SIMD3<Float>(repeating: worldScale),
                                                               rotation: worldRotation,
                                                               translation: worldTranslation)

            delegate?.setPHASETransform(GDRKTransform(
                scale: SIMD3<Float>(repeating: worldScale),
                position: worldTranslation,
                orientation: worldRotation
            ))

            self.state.lastCameraTransform = cameraTransform
            self.state.lastViewBounds = viewBounds
        }
    }
}

class LoadingViewController: UIViewController {
    override func loadView() {
        let loadingView = UIView()
        loadingView.backgroundColor = Bridge.bootSplashBgColor

        if let bootImage = Bridge.bootSplashImage {
            let imageView = UIImageView(image: bootImage)
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            loadingView.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor),
                imageView.widthAnchor.constraint(lessThanOrEqualTo: loadingView.widthAnchor),
                imageView.heightAnchor.constraint(lessThanOrEqualTo: loadingView.heightAnchor),
            ])
        }

        view = loadingView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Retired Godot windows also show this screen; don't request another volume for them.
        if let existing = UIApplication.shared.connectedScenes.first(where: { Bridge.isBridgeScene($0) }) {
            Bridge.logScene("loading screen appeared; bridge scene already connected (\(Bridge.describe(existing))), not activating another")
            return
        }
        Bridge.logScene("loading screen appeared; requesting \(Bridge.presentationStyle.rawValue) scene")

        guard let request = UISceneSessionActivationRequest(hostingDelegateClass: BridgeScene.self, id: Bridge.presentationStyle.rawValue) else {
            Bridge.logScene("unable to create UISceneSessionActivationRequest")
            return
        }

        UIApplication.shared.activateSceneSession(for: request) { error in
            Bridge.logScene("error activating bridge scene session: \(error)")
        }
    }
}

class GodotViewController: UIViewController {
    let godotViewController: UIViewController? = Bridge.originalViewController

    var displayLink: CADisplayLink? = nil
    var isActive: Bool = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startRendering()
    }

    func startRendering() {
        if self.isActive {
            return
        }

        self.isActive = true

        if let godotView = godotViewController?.view {
            displayLink = CADisplayLink(target: self, selector: #selector(update))
            if let framerate = godotView.value(forKey: "preferredFrameRate") as? Int {
                displayLink?.preferredFramesPerSecond = framerate
            }
            displayLink?.add(to: .current, forMode: .common)
        }
    }

    @objc
    func update() {
        // The problem: inside drawView, Godot temporarily hands control back to the system's main
        // run loop (the mechanism iOS uses to process events like touches, timers, and other
        // callbacks while an app is idle) so that any input events waiting to be delivered get
        // handled immediately, instead of waiting until drawView returns. Godot pauses its own
        // CADisplayLink first so that handing control back to the run loop can't turn around and
        // call drawView again through its own display link. But Godot has no idea our separate
        // CADisplayLink exists, so it doesn't pause it. That means while control is handed back to
        // the run loop, our CADisplayLink can fire, which calls update(), which calls drawView
        // again - all before the first drawView call has returned. That inner drawView call does
        // the exact same thing, calling drawView a third time, and so on, forever, until the app
        // runs out of stack space and crashes.
        // The fix: pause our own CADisplayLink before calling drawView, the same way Godot pauses
        // its own, so it can't fire again while we're still inside drawView. Resume it once
        // drawView returns.
        displayLink?.isPaused = true

        if let godotView = godotViewController?.view {
            // If the view was active, it means that the a display link is installed to update the
            // view. To remove it, we call `stopRendering`
            let viewIsActive: Bool =  godotView.value(forKey: "isActive") as! Bool
            if (viewIsActive) {
                if godotView.responds(to: Selector(("stopRendering"))) {
                    godotView.perform(Selector(("stopRendering")))
                } else {
                    print("GodotRealityKit Error: missing function 'stopRendering' on Godot's GDTView")
                }
            }
            
            // The GDTView drawView will only run if `isActive` is true. So we force it here
            // and reverse it back after the view has been updated.
            godotView.setValue(true, forKey: "isActive")
            if godotView.responds(to: Selector(("drawView"))) {
                godotView.perform(Selector(("drawView")))
            } else {
                print("GodotRealityKit Error: missing function 'drawView' on Godot's GDTView")
            }
            godotView.setValue(false, forKey: "isActive")
        }

        displayLink?.isPaused = false
    }

    func stopRendering() {
        if !self.isActive {
            return
        }

        self.isActive = false

        self.displayLink?.invalidate()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopRendering()
    }

    override func pressesBegan(
        _ presses: Set<UIPress>,
        with event: UIPressesEvent?
    ) {
        self.godotViewController?.pressesBegan(presses, with: event)
    }

    override func pressesEnded(
        _ presses: Set<UIPress>,
        with event: UIPressesEvent?
    ) {
        self.godotViewController?.pressesEnded(presses, with: event)
    }
}

struct GodotViewControllerRepresentable : UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GodotViewController {
        return GodotViewController()
    }

    func updateUIViewController(_ uiViewController: GodotViewController, context: Context) {}
}

class BridgeScene: NSObject, @MainActor UIHostingSceneDelegate {
    // The system default volume size (1280pt per side, ~0.94m), used when
    // reality_kit/volume_default_size is unset.
    static let systemDefaultVolumeSize = Size3D(width: 1280.0 / 1360.0, height: 1280.0 / 1360.0, depth: 1280.0 / 1360.0)

    @MainActor static var volumeDefaultSize: Size3D {
        guard let settings = Bridge.delegate?.getExtensionSettings(),
              settings.volumeDefaultWidth > 0,
              settings.volumeDefaultHeight > 0,
              settings.volumeDefaultDepth > 0 else {
            return systemDefaultVolumeSize
        }
        return Size3D(width: Double(settings.volumeDefaultWidth),
                      height: Double(settings.volumeDefaultHeight),
                      depth: Double(settings.volumeDefaultDepth))
    }

    @MainActor static var volumeResizability: WindowResizability {
        (Bridge.delegate?.getExtensionSettings().volumeResizable ?? true) ? .contentMinSize : .automatic
    }

    @MainActor static var volumePlacementPosition: WindowPlacement.Position? {
        switch Bridge.delegate?.getExtensionSettings().volumePlacement {
        case .utilityPanel: return .utilityPanel
        default: return nil
        }
    }

    @MainActor static var volumeWorldAlignment: WorldAlignmentBehavior {
        switch Bridge.delegate?.getExtensionSettings().volumeWorldAlignment {
        case .adaptive: return .adaptive
        case .gravityAligned: return .gravityAligned
        default: return .automatic
        }
    }

    static var rootScene: some SwiftUI.Scene {
        WindowGroup(id: ScenePresentationStyle.sharedVolumetric.rawValue) {
            SharedVolumetricRealityView(root: Bridge.root.value, delegate: Bridge.delegate)
            .overlay{GodotViewControllerRepresentable()}
        }
        .windowStyle(.volumetric)
        .defaultSize(volumeDefaultSize, in: .meters)
        .windowResizability(volumeResizability)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(volumePlacementPosition)
        }
        .volumeWorldAlignment(volumeWorldAlignment)
        .restorationBehavior(.disabled)
        WindowGroup(id: ScenePresentationStyle.sharedPortal.rawValue) {
            PortalRealityView(root: Bridge.root.value, delegate: Bridge.delegate)
            .overlay{GodotViewControllerRepresentable()}
        }
        .restorationBehavior(.disabled)
        ImmersiveSpace(id: ScenePresentationStyle.immersive.rawValue) {
            ImmersiveRealityView(root: Bridge.root.value, delegate: Bridge.delegate)
            .overlay{GodotViewControllerRepresentable()}
        }
        .immersionStyle(selection: Binding(get: {
            switch Bridge.immersionStyle {
            case .mixed: return .mixed
            case .full: return .full
            case .progressive: return .progressive
            }
        }, set: { _ in }), in: .mixed, .full, .progressive)
        .restorationBehavior(.disabled)
    }

    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        Bridge.bridgeSessionIDs.insert(session.persistentIdentifier)
        Bridge.logScene("bridge scene willConnect \(Bridge.describe(scene))")
    }

    public func sceneWillEnterForeground(_ scene: UIScene) {
        Bridge.bridgeSessionIDs.insert(scene.session.persistentIdentifier)
        Bridge.sceneVisible = true
        Bridge.logScene("bridge scene willEnterForeground; volume visible")
    }

    public func sceneDidBecomeActive(_ scene: UIScene) {
        Bridge.bridgeSessionIDs.insert(scene.session.persistentIdentifier)
        Bridge.resumeGodotFocus(reason: "bridge scene became active")
    }

    public func sceneWillResignActive(_ scene: UIScene) {
        Bridge.logScene("bridge scene willResignActive; forwarding focus out to Godot")
        Bridge.forwardToGodotSceneDelegate(Selector(("sceneWillResignActive:")), scene: scene)
    }

    public func sceneDidEnterBackground(_ scene: UIScene) {
        Bridge.sceneVisible = false
        Bridge.logScene("bridge scene didEnterBackground; volume hidden")
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        Bridge.logScene("bridge scene didDisconnect \(Bridge.describe(scene))")
    }
}

#else

struct DesktopRealityView : View {
    let root: RealityKit.Entity
    let delegate: GDRKBridgeDelegate?

    public static let light = createBlackIBLEntity()

    public var body: some View {
        GeometryReader{ proxy in
            RealityView(make: { content in
                content.add(self.root)
            }, update: { content in
                self.delegate?.onWindowResized(simd_float2(Float(proxy.size.width), Float(proxy.size.height)))
            })
            .installGestures(delegate: self.delegate, root: self.root, size: proxy.size)
//            .allowsHitTesting(false)
            .background(.black)
        }
    }

    static func createBlackEnvironmentResource() -> RealityKit.EnvironmentResource? {
        var srgbData = [UInt32](repeating: 0x0, count: 1)
        let cgImage = srgbData.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue +
                    CGImageAlphaInfo.premultipliedFirst.rawValue
                )!
            return ctx.makeImage()
        }

        guard let cgImage else {
            return nil
        }

        return try? RealityKit.EnvironmentResource(equirectangular: cgImage)
    }

    static func createBlackIBLEntity() -> RealityKit.Entity? {
        if let blackEnvResource = createBlackEnvironmentResource() {
            return RealityKit.Entity(components: [ImageBasedLightComponent(source: .single(blackEnvResource))])
        } else {
            return nil
        }
    }
}

#endif

public class Bridge {
    @MainActor static public var delegate: GDRKBridgeDelegate? = nil
    @MainActor static var root = Entity.initAndMaterialize()

    @MainActor static var blockingAsyncTaskCount = 0
    @MainActor static var sceneVisible = false

    @MainActor static var presentationStyle = ScenePresentationStyle.sharedVolumetric
    @MainActor static var immersionStyle = SceneImmersionStyle.full

    #if !os(macOS)
    // Godot-owned UIWindowScenes (the launch scene plus any scene re-adopted after a renderer
    // relaunch) that show the loading screen until the volume is visible, then get destroyed.
    // Holding them here also keeps them alive until destruction.
    @MainActor static var originalScenes: [UIWindowScene] = []
    @MainActor static var originalViewController: UIViewController? = nil
    @MainActor static var retiredGodotViews: [UIView] = []
    @MainActor static var bootSplashImage: UIImage? = nil
    @MainActor static var bootSplashBgColor: UIColor = .black
    @MainActor static var audioInterruptionObserver: Any? = nil
    @MainActor static var godotSceneLifecycleObservers: [Any] = []
    // Session IDs of scenes hosting BridgeScene content. Used with `delegate is BridgeScene`
    // because SwiftUI may wrap the hosting scene delegate.
    @MainActor static var bridgeSessionIDs: Set<String> = []
    // Godot scenes we asked the system to destroy, kept alive until they disconnect.
    @MainActor static var destroyRequests: [String: (scene: UIWindowScene, requestedAt: Date, attempts: Int)] = [:]
    @MainActor static var pendingFocusResume: DispatchWorkItem? = nil
    static let sceneLogger = Logger(subsystem: "com.apple.GodotRealityKit", category: "Scenes")
    #endif

    public init() {}

    public static func initialize(delegate: GDRKBridgeDelegate) {
        assumeMainActor(delegate) { delegate in
            Self.delegate = delegate
            _ = Self.root

            let settings = delegate.getExtensionSettings()

            Self.presentationStyle = {
                switch settings.presentationStyle {
                case .immersive: return .immersive
                case .volumetricPortal: return .sharedPortal
                case .volumetricWindow: return .sharedVolumetric
                @unknown default: return .sharedVolumetric
                }
            }()

            Self.immersionStyle = {
                switch settings.immersionStyle {
                case .mixed: return .mixed
                case .full: return .full
                case .progressive: return .progressive
                @unknown default: return .full
                }
            }()
        }

#if os(macOS)
        assumeMainActor(self, delegate){ s, delegate in
            let rkViewHost =
                NSHostingController(
                    rootView: DesktopRealityView(root: s.root.value,
                                                 delegate: Bridge.delegate)
                )
            if let window = delegate.getDisplayServerWindow() {
                if let contentView = window.contentView {
                    contentView.addSubview(rkViewHost.view)
                    rkViewHost.view.setFrameSize(contentView.frame.size)
                    rkViewHost.view.translatesAutoresizingMaskIntoConstraints = false;

                    let top = rkViewHost.view.topAnchor.constraint(equalTo: contentView.topAnchor)
                    let leading = rkViewHost.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
                    let trailing = rkViewHost.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
                    let bottom = rkViewHost.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)

                    NSLayoutConstraint.activate([ top, leading, trailing, bottom ]);
                }
            } else {
                print("no window or no content view controller!")
            }

            Bridge.sceneVisible = true
        }

#else
        assumeMainActor(delegate) { delegate in
            Self.originalViewController = delegate.getDisplayServerViewController()
            Self.bootSplashImage = delegate.getBootSplashImage()
            Self.bootSplashBgColor = delegate.getBootSplashBgColor()

            Self.installSceneLifecycleObservers()
            Self.logScene("initialize; connected scenes: \(Self.describeConnectedScenes())")

            // The scene transition below may interrupt the AVAudioSession.
            // Godot's own interruption handler calls on_focus_in() when the
            // interruption ends, but we also reactivate the session ourselves
            // as a safety net.
            Self.audioInterruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { notification in
                guard let info = notification.userInfo,
                      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                      type == .ended else {
                    return
                }
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    print("GodotRealityKit: failed to reactivate audio session after interruption: \(error)")
                }
            }

            // Prefer the scene that actually hosts Godot's display-server view controller; with
            // several restored Godot windows `connectedScenes.first` is arbitrary.
            let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let originalScene = Self.originalViewController?.viewIfLoaded?.window?.windowScene
                ?? windowScenes.first { Self.isGodotWindowScene($0) }
                ?? windowScenes.first
            guard let originalScene else {
                Self.logScene("initialize: no connected window scene to show the loading screen in")
                return
            }

            // Show just the loading screen in the original Godot window. Replacing the root view
            // controller unlinks Godot's display link, stopping its own game loop. The loading
            // screen requests the volume/portal/immersive scene when it appears.
            Self.retireGodotScene(originalScene, reason: "launch scene")
            // Retire any other Godot windows that are already connected (e.g. restored ones).
            _ = Self.sweepGodotWindowScenes()

            NotificationCenter.default.addObserver(
                forName: Self.relaunchNotification,
                object: nil,
                queue: .main
            ) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Bridge.reattachAfterRelaunch()
                    }
                }
            }
        }
#endif
    }

    public static func getRoot() -> Entity {
        MainActor.assumeIsolated{ Self.root }
    }

    public static func isSceneVisible() -> Bool {
        MainActor.assumeIsolated{ Self.sceneVisible }
    }

#if !os(macOS)
    public static let relaunchNotification = Notification.Name("GDRKRendererRelaunchDetected")

    @MainActor
    static func reattachAfterRelaunch() {
        logScene("renderer relaunch detected; connected scenes: \(describeConnectedScenes())")
        if sweepGodotWindowScenes() == 0 {
            logScene("relaunch: no new Godot window scene found yet; will retry each frame")
        }
    }

    // MARK: Scene diagnostics

    @MainActor
    static func logScene(_ message: String) {
        sceneLogger.notice("\(message, privacy: .public)")
        let line = "GodotRealityKit[scenes]: " + message
        line.withCString { delegate?.printMessage($0) }
    }

    @MainActor
    static func activationStateName(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .unattached: return "unattached"
        case .foregroundActive: return "foregroundActive"
        case .foregroundInactive: return "foregroundInactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    @MainActor
    static func viewControllers(in scene: UIScene) -> [UIViewController] {
        guard let windowScene = scene as? UIWindowScene else { return [] }
        return windowScene.windows.flatMap { viewControllers(in: $0) }
    }

    @MainActor
    static func viewControllers(in window: UIWindow) -> [UIViewController] {
        var result: [UIViewController] = []
        var stack = [window.rootViewController].compactMap { $0 }
        while let vc = stack.popLast() {
            result.append(vc)
            stack.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController { stack.append(presented) }
        }
        return result
    }

    @MainActor
    static func isGodotViewController(_ vc: UIViewController) -> Bool {
        if vc is LoadingViewController { return true }
        if NSStringFromClass(type(of: vc)).hasPrefix("GDT") { return true }
        return String(describing: type(of: vc)).contains("GodotSwiftUIViewController")
    }

    @MainActor
    static func isBridgeScene(_ scene: UIScene) -> Bool {
        if scene.delegate is BridgeScene { return true }
        if bridgeSessionIDs.contains(scene.session.persistentIdentifier) { return true }
        if scene.session.role == .windowApplicationVolumetric || scene.session.role == .immersiveSpaceApplication {
            return true
        }
        return viewControllers(in: scene).contains { $0 is GodotViewController }
    }

    // A Godot-owned 2D window: Godot's own WindowGroup scene (launch, restored or relaunched),
    // identified by its GDTViewController or our loading screen.
    @MainActor
    static func isGodotWindowScene(_ scene: UIScene) -> Bool {
        guard scene is UIWindowScene, !isBridgeScene(scene) else { return false }
        return viewControllers(in: scene).contains { isGodotViewController($0) }
    }

    @MainActor
    static func describe(_ scene: UIScene) -> String {
        let kind = isBridgeScene(scene) ? "bridge" : (isGodotWindowScene(scene) ? "godot" : "other")
        let delegateName = scene.delegate.map { String(describing: type(of: $0)) } ?? "nil"
        let root = (scene as? UIWindowScene)?.windows.first?.rootViewController.map { String(describing: type(of: $0)) } ?? "nil"
        return "\(kind) id=\(scene.session.persistentIdentifier) role=\(scene.session.role.rawValue) " +
            "state=\(activationStateName(scene.activationState)) delegate=\(delegateName) root=\(root)"
    }

    @MainActor
    static func describeConnectedScenes() -> String {
        let scenes = UIApplication.shared.connectedScenes.map { "[\(describe($0))]" }
        return scenes.isEmpty ? "none" : scenes.joined(separator: " ")
    }

    @MainActor
    static func installSceneLifecycleObservers() {
        guard godotSceneLifecycleObservers.isEmpty else { return }
        let events: [(Notification.Name, String)] = [
            (UIScene.willConnectNotification, "willConnect"),
            (UIScene.willEnterForegroundNotification, "willEnterForeground"),
            (UIScene.didActivateNotification, "didActivate"),
            (UIScene.willDeactivateNotification, "willDeactivate"),
            (UIScene.didEnterBackgroundNotification, "didEnterBackground"),
            (UIScene.didDisconnectNotification, "didDisconnect"),
        ]
        for (name, label) in events {
            godotSceneLifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { notification in
                guard let scene = notification.object as? UIScene else { return }
                MainActor.assumeIsolated {
                    Bridge.handleSceneEvent(label, scene: scene)
                }
            })
        }
    }

    @MainActor
    static func handleSceneEvent(_ label: String, scene: UIScene) {
        logScene("scene \(label) \(describe(scene))")
        let id = scene.session.persistentIdentifier
        if label == "didDisconnect" {
            if destroyRequests.removeValue(forKey: id) != nil {
                logScene("destroyed Godot window scene id=\(id)")
            }
            originalScenes.removeAll { $0.session.persistentIdentifier == id }
        }
        guard !isBridgeScene(scene) else { return }
        switch label {
        case "willDeactivate", "didEnterBackground", "didDisconnect":
            // Godot's scene delegate calls on_focus_out() (stopping audio and pausing focus-aware
            // games) for every scene, including Godot windows we retire or the user closes.
            // Restore focus if a volume/portal/immersive scene is still frontmost.
            scheduleFocusResume(reason: "Godot window \(label) id=\(id)")
        default:
            break
        }
    }

    @MainActor
    static func scheduleFocusResume(reason: String) {
        pendingFocusResume?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                Bridge.pendingFocusResume = nil
                guard let bridgeScene = Bridge.foregroundActiveBridgeScene() else {
                    Bridge.logScene("not resuming after \(reason): no foreground-active bridge scene")
                    return
                }
                Bridge.resumeGodotFocus(reason: reason, scene: bridgeScene)
            }
        }
        pendingFocusResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @MainActor
    static func foregroundActiveBridgeScene() -> UIScene? {
        UIApplication.shared.connectedScenes.first { isBridgeScene($0) && $0.activationState == .foregroundActive }
    }

    // MARK: Godot window retirement

    // Detach a Godot window from the game: show the loading screen and stop its GDTView's own
    // display link. The bridge scene's GodotViewController keeps driving Godot's main view.
    @MainActor
    static func retireGodotScene(_ scene: UIWindowScene, reason: String) {
        let id = scene.session.persistentIdentifier
        let alreadyRetired = originalScenes.contains(scene) || destroyRequests[id] != nil
        if !alreadyRetired {
            originalScenes.append(scene)
        }
        let godotViews = viewControllers(in: scene)
            .filter { !($0 is LoadingViewController) && NSStringFromClass(type(of: $0)).hasPrefix("GDT") }
            .compactMap { $0.viewIfLoaded }
        for view in godotViews where !retiredGodotViews.contains(view) {
            retiredGodotViews.append(view)
            if view !== originalViewController?.viewIfLoaded, view.responds(to: Selector(("stopRendering"))) {
                view.perform(Selector(("stopRendering")))
            }
        }
        var replaced = 0
        // Only touch windows hosting Godot content; UIKit's internal windows (e.g.
        // UITextEffectsWindow) don't support replacing their root view controller.
        for window in scene.windows where !(window.rootViewController is LoadingViewController) &&
            viewControllers(in: window).contains(where: { isGodotViewController($0) }) {
            window.rootViewController = LoadingViewController()
            replaced += 1
        }
        if !alreadyRetired || replaced > 0 {
            logScene("adopted Godot window (\(reason)) as loading screen: \(describe(scene)), replaced \(replaced) root(s), retired \(godotViews.count) GDTView(s)")
        }
    }

    // Retire every connected Godot window not already being destroyed. Returns how many were found.
    @MainActor
    @discardableResult
    static func sweepGodotWindowScenes() -> Int {
        var found = 0
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard destroyRequests[scene.session.persistentIdentifier] == nil, isGodotWindowScene(scene) else { continue }
            found += 1
            if !originalScenes.contains(scene) || !viewControllers(in: scene).allSatisfy({ !NSStringFromClass(type(of: $0)).hasPrefix("GDT") }) {
                retireGodotScene(scene, reason: "sweep")
            }
        }
        return found
    }

    // Called every frame from SceneLoader; also retries destruction that didn't take.
    @MainActor
    static func hasGodotWindowsToDestroy() -> Bool {
        sweepGodotWindowScenes()
        let now = Date()
        for (id, request) in destroyRequests where now.timeIntervalSince(request.requestedAt) > 2.0 {
            guard request.scene.activationState != .unattached,
                  UIApplication.shared.connectedScenes.contains(request.scene) else {
                destroyRequests.removeValue(forKey: id)
                continue
            }
            if request.attempts >= 3 {
                logScene("giving up destroying Godot window id=\(id) after \(request.attempts) attempts: \(describe(request.scene))")
                destroyRequests[id] = (request.scene, .distantFuture, request.attempts)
                continue
            }
            logScene("Godot window id=\(id) still connected \(String(format: "%.1f", now.timeIntervalSince(request.requestedAt)))s after destroy request; retrying")
            requestDestruction(of: request.scene, attempts: request.attempts + 1)
        }
        return !originalScenes.isEmpty
    }

    @MainActor
    static func destroyGodotWindowScenes() {
        let scenes = originalScenes
        originalScenes.removeAll()
        for scene in scenes {
            requestDestruction(of: scene, attempts: 1)
        }
    }

    @MainActor
    static func requestDestruction(of scene: UIWindowScene, attempts: Int) {
        let id = scene.session.persistentIdentifier
        destroyRequests[id] = (scene, Date(), attempts)
        logScene("requesting destruction (attempt \(attempts)) of \(describe(scene))")
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in
            MainActor.assumeIsolated {
                Bridge.logScene("destroy request for id=\(id) failed: \(error.localizedDescription) (\(error))")
            }
        }
    }

    @MainActor
    static func hasForegroundBridgeScene() -> Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            isBridgeScene(scene) &&
                (scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive)
        }
    }

    // Godot's scene delegate (GDTAppDelegate) is installed per scene by SwiftUI, and
    // UIApplication.shared.delegate is SwiftUI's own, so message Godot's static services directly.
    @MainActor
    @discardableResult
    static func forwardToGodotSceneDelegate(_ selector: Selector, scene: UIScene?) -> String {
        if let cls = NSClassFromString("GDTAppDelegate") as AnyObject?,
           cls.responds(to: Selector(("services"))),
           let services = cls.perform(Selector(("services")))?.takeUnretainedValue() as? [AnyObject] {
            var count = 0
            for service in services where service.responds(to: selector) {
                _ = service.perform(selector, with: scene)
                count += 1
            }
            if count > 0 {
                return "GDTAppDelegate services (\(count))"
            }
        }
        if let appDelegate = UIApplication.shared.delegate, appDelegate.responds(to: selector) {
            appDelegate.perform(selector, with: scene)
            return "UIApplication delegate \(type(of: appDelegate))"
        }
        return "nothing (no Godot delegate responds)"
    }

    // Restarts Godot's audio driver and focus (on_focus_in) after a scene transition.
    @MainActor
    static func resumeGodotFocus(reason: String, scene: UIScene? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            var sessionError: Error? = nil
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                sessionError = error
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let target = scene ?? Bridge.foregroundActiveBridgeScene()
                        ?? UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
                        ?? UIApplication.shared.connectedScenes.first
                    let via = Bridge.forwardToGodotSceneDelegate(Selector(("sceneDidBecomeActive:")), scene: target)
                    // on_focus_in() restarts the display link of GDTAppDelegateService.viewController,
                    // which may be a retired Godot window's view; keep those stopped.
                    for view in Bridge.retiredGodotViews where view !== Bridge.originalViewController?.viewIfLoaded {
                        if view.responds(to: Selector(("stopRendering"))) {
                            view.perform(Selector(("stopRendering")))
                        }
                    }
                    let sessionNote = sessionError.map { "; audio session activation failed: \($0)" } ?? ""
                    Bridge.logScene("audio/focus resume (\(reason)) via \(via)\(sessionNote)")
                }
            }
        }
    }
#endif
}
