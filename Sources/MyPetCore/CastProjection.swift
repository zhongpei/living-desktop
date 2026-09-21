import Foundation

/// CastRuntime 到桌面表现层的只读投影。
///
/// 这是一个有明确深度（Depth）的模块：它只把已经由 GameKernel 确认
/// alive 的角色/道具排成可见框并运行 SpatialSafety，不重新决定生命周期、
/// 关系或剧情。Harness 和 AppKit 都消费这个 Interface，避免各自复制一套
/// “角色是否会被窗口吃掉/道具是否重叠”的实现。
public struct CastVisualEntity: Codable, Equatable, Sendable {
    public let id: EntityID
    public let kind: EntityKind
    public let displayName: String
    public let visualPackID: String?
    public let renderable: Bool
    public let frame: LayoutRect?
    public let zIndex: Int
    /// Non-nil when a confirmed occupied prop/cockpit slot has a spatial
    /// participant attachment. This is a projection attachment, not a new
    /// world ownership field; GameKernel slot state remains authoritative.
    public let attachedToID: EntityID?

    public init(
        id: EntityID,
        kind: EntityKind,
        displayName: String,
        visualPackID: String?,
        renderable: Bool,
        frame: LayoutRect?,
        zIndex: Int,
        attachedToID: EntityID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.visualPackID = visualPackID
        self.renderable = renderable
        self.frame = frame
        self.zIndex = zIndex
        self.attachedToID = attachedToID
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, visualPackID, renderable, frame, zIndex, attachedToID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(EntityID.self, forKey: .id),
            kind: try values.decode(EntityKind.self, forKey: .kind),
            displayName: try values.decode(String.self, forKey: .displayName),
            visualPackID: try values.decodeIfPresent(String.self, forKey: .visualPackID),
            renderable: try values.decodeIfPresent(Bool.self, forKey: .renderable) ?? false,
            frame: try values.decodeIfPresent(LayoutRect.self, forKey: .frame),
            zIndex: try values.decodeIfPresent(Int.self, forKey: .zIndex) ?? 100,
            attachedToID: try values.decodeIfPresent(EntityID.self, forKey: .attachedToID))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(displayName, forKey: .displayName)
        try values.encodeIfPresent(visualPackID, forKey: .visualPackID)
        try values.encode(renderable, forKey: .renderable)
        try values.encodeIfPresent(frame, forKey: .frame)
        try values.encode(zIndex, forKey: .zIndex)
        try values.encodeIfPresent(attachedToID, forKey: .attachedToID)
    }
}

/// Per-pet visual dimensions supplied by the renderer adapter. The projection
/// owns placement, but it must not make every character borrow the first
/// petpack's aspect ratio.
public struct CastVisualSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct CastLayoutSnapshot: Codable, Equatable, Sendable {
    public let virtualBounds: LayoutRect
    public let entities: [CastVisualEntity]
    public let violations: [SpatialViolation]

    public init(
        virtualBounds: LayoutRect,
        entities: [CastVisualEntity],
        violations: [SpatialViolation]
    ) {
        self.virtualBounds = virtualBounds
        self.entities = entities
        self.violations = violations
    }

    public var renderableEntities: [CastVisualEntity] {
        entities.filter { $0.renderable && $0.frame != nil }
    }
}

public enum CastVisualProjection {
    /// Shared prop-to-hand geometry used by both the steady projection and the
    /// AppKit hand-off animation. Keeping this calculation here prevents a
    /// presentation adapter from creating a second attachment convention.
    public static func attachedPropFrame(
        actorFrame: LayoutRect,
        propSize: Double
    ) -> LayoutRect {
        let size = min(max(1, propSize), max(1, actorFrame.height * 0.38))
        return LayoutRect(
            x: actorFrame.x + actorFrame.width * 0.58,
            y: actorFrame.y + actorFrame.height * 0.30,
            width: size,
            height: size)
    }

    /// Creates a deterministic two-band stage: characters/mechs occupy the
    /// lower band, props occupy the upper band. The bands are a testable default,
    /// not a claim that every scene must use this exact composition.
    public static func project(
        runtime: CastRuntime,
        in bounds: LayoutRect = LayoutRect(x: 0, y: 0, width: 1440, height: 900),
        actorHeight: Double? = nil,
        propSize: Double? = nil,
        actorWidth: Double? = nil,
        actorSizes: [String: CastVisualSize] = [:],
        renderableMemberIDs: Set<String>? = nil
    ) -> CastLayoutSnapshot {
        let members = runtime.activeMembers.sorted { $0.id < $1.id }
        let props = runtime.presentedProps.sorted { $0.id < $1.id }
        let gap = 8.0

        // A missing visual member remains in the logical cast report, but it
        // must not consume a horizontal stage slot. Otherwise an invisible
        // mech can push the last visible character outside the stage and make
        // SpatialSafety.fit hide the real composition at an edge.
        let renderableMembers = members.filter {
            $0.visualPackID != nil &&
                (renderableMemberIDs == nil || renderableMemberIDs?.contains($0.id) == true)
        }
        let fallbackMechs = members.filter { $0.kind == .mech && $0.visualPackID == nil }
        let fallbackActorHeight = actorHeight ?? min(240, max(80, bounds.height * 0.30))
        let fallbackActorWidth = actorWidth.map { min(bounds.width, max(1, $0)) }
            ?? min(180, max(48, fallbackActorHeight * 0.72))
        let memberSizes = Dictionary(uniqueKeysWithValues: renderableMembers.map { member in
            (member.id, actorSizes[member.id] ?? CastVisualSize(
                width: fallbackActorWidth, height: fallbackActorHeight))
        })
        let requestedActorHeight = memberSizes.values.map(\.height).max() ?? fallbackActorHeight
        let requestedMechHeight = min(160, max(72, requestedActorHeight * 0.62))
        let requestedPropSize = propSize ?? min(96, max(32, bounds.height * 0.12))
        let hasPropBand = !props.isEmpty
        let hasMechBand = !fallbackMechs.isEmpty
        let activeBands = 1 + (hasPropBand ? 1 : 0) + (hasMechBand ? 1 : 0)
        // The normal 1440x900 composition has generous vertical space, but a
        // narrow/short display or a maximized window can be much smaller. Scale
        // all independent bands together before projection so props, fallback
        // mechs and actors cannot overlap merely because their default bands
        // were designed for a full-size desktop.
        let verticalGaps = gap * Double(activeBands + 1)
        let verticalBudget = max(1, bounds.height - verticalGaps)
        let requestedHeight = requestedActorHeight +
            (hasMechBand ? requestedMechHeight : 0) +
            (hasPropBand ? requestedPropSize : 0)
        let verticalScale = min(1, verticalBudget / max(1, requestedHeight))
        let mechHeight = hasMechBand ? max(1, requestedMechHeight * verticalScale) : 0
        let size = hasPropBand ? max(1, requestedPropSize * verticalScale) : 0
        let propBandY = bounds.minY + gap
        let mechBandY = propBandY + (hasPropBand ? size + gap : 0)

        let memberActors = renderableMembers.enumerated().map { index, member -> LayoutActor in
            let count = max(1, renderableMembers.count)
            let anchorX = bounds.minX + bounds.width * Double(index + 1) / Double(count + 1)
            let dimensions = memberSizes[member.id] ?? CastVisualSize(
                width: fallbackActorWidth, height: fallbackActorHeight)
            let width = max(1, dimensions.width * verticalScale)
            let height = max(1, dimensions.height * verticalScale)
            let raw = LayoutRect(
                x: anchorX - width / 2,
                y: bounds.maxY - height - gap,
                width: width,
                height: height)
            return LayoutActor(id: EntityID(member.id), frame: SpatialSafety.fit(raw, in: bounds), zIndex: 100)
        }
        // A missing mech pack still gets a small, upper-band fallback frame.
        // It is intentionally separate from the actor baseline, so a missing
        // EVA sprite cannot push visible characters out of the work area.
        let mechWidth = min(120, max(56, mechHeight * 0.68))
        let mechActors = fallbackMechs.enumerated().map { index, member -> LayoutActor in
            let count = max(1, fallbackMechs.count)
            let anchorX = bounds.minX + bounds.width * Double(index + 1) / Double(count + 1)
            let raw = LayoutRect(
                x: anchorX - mechWidth / 2,
                y: mechBandY,
                width: mechWidth,
                height: mechHeight)
            return LayoutActor(
                id: EntityID(member.id),
                frame: SpatialSafety.fit(raw, in: bounds),
                zIndex: 90)
        }

        // Keep each visual band independent. A missing/fallback mech belongs to
        // the upper band and must never consume one of the visible actor
        // anchors; otherwise adding two logical mechs moves the actual
        // characters even though they have not changed.
        let baseMemberCandidates = SpatialSafety.separate(memberActors, in: bounds, gap: gap)
        let baseMechCandidates = SpatialSafety.separate(mechActors, in: bounds, gap: gap)
        let baseCandidates = baseMemberCandidates + baseMechCandidates
        let baseFrames = Dictionary(uniqueKeysWithValues: baseCandidates.map { ($0.id, $0) })
        let memberIDs = Set(members.map { EntityID($0.id) })
        let memberAttachments = runtime.kernel.world.spatialAttachments.values
            .filter { memberIDs.contains($0.childID) && baseFrames[$0.parentID] != nil }
            .reduce(into: [EntityID: SpatialAttachment]()) { result, attachment in
                result[attachment.childID] = attachment
            }

        func attachedFrame(child: LayoutRect, parent: LayoutRect, socketID: String) -> LayoutRect {
            let isCockpit = socketID.lowercased().contains("cockpit")
            let width = min(child.width, max(1, parent.width * (isCockpit ? 0.62 : 0.58)))
            let height = min(child.height, max(1, parent.height * (isCockpit ? 0.62 : 0.58)))
            let x = isCockpit
                ? parent.x + (parent.width - width) / 2
                : parent.x + parent.width * 0.46
            let y = parent.y + parent.height * (isCockpit ? 0.22 : 0.24)
            return LayoutRect(x: x, y: y, width: width, height: height)
        }

        func projectedFrame(for id: EntityID, visiting: Set<EntityID> = []) -> LayoutRect? {
            guard let base = baseFrames[id] else { return nil }
            guard let attachment = memberAttachments[id], !visiting.contains(id),
                  let parent = projectedFrame(for: attachment.parentID, visiting: visiting.union([id])) else {
                return base.frame
            }
            return attachedFrame(child: base.frame, parent: parent, socketID: attachment.socketID)
        }

        let attachedMemberIDs = Set(memberAttachments.keys)
        let attachedMembers = attachedMemberIDs.sorted { $0.raw < $1.raw }.compactMap { id -> LayoutActor? in
            guard let base = baseFrames[id], let frame = projectedFrame(for: id) else { return nil }
            return LayoutActor(
                id: id,
                frame: SpatialSafety.fit(frame, in: bounds),
                zIndex: max(130, base.zIndex + 30),
                allowsOverlap: true)
        }
        // A confirmed member attachment replaces the child's free-standing
        // stage position. The parent remains in its original band; the child
        // is rendered from the attachment socket so cockpit/character contact
        // is visible instead of existing only in the kernel trace.
        let memberCandidates = baseMemberCandidates.filter { !attachedMemberIDs.contains($0.id) } + attachedMembers.filter { attached in
            baseMemberCandidates.contains { base in base.id == attached.id }
        }
        let mechCandidates = baseMechCandidates.filter { !attachedMemberIDs.contains($0.id) } + attachedMembers.filter { attached in
            baseMechCandidates.contains { base in base.id == attached.id }
        }
        let presentationCandidates = memberCandidates + mechCandidates
        let memberFrames = Dictionary(uniqueKeysWithValues: presentationCandidates.map { ($0.id, $0.frame) })
        let propIDs = Set(props.map(\.id))
        // SpatialAttachment is the shared Interface between Kernel, Harness
        // and AppKit. Slot occupancy remains the capacity authority; the
        // attachment itself is no longer re-derived independently in each
        // presentation layer.
        let attachments = runtime.kernel.world.spatialAttachments.values.compactMap {
            attachment -> (String, EntityID)? in
            guard propIDs.contains(attachment.childID.raw),
                  memberFrames[attachment.parentID] != nil else { return nil }
            return (attachment.childID.raw, attachment.parentID)
        }
        let attachedTo = Dictionary(attachments, uniquingKeysWith: { first, _ in first })
        let propActors = props.enumerated().map { index, prop in
            let propID = EntityID(prop.id)
            if let actorID = attachedTo[prop.id], let actor = memberFrames[actorID] {
                let raw = attachedPropFrame(actorFrame: actor, propSize: size)
                return LayoutActor(
                    id: propID,
                    frame: SpatialSafety.fit(raw, in: bounds),
                    zIndex: 120,
                    allowsOverlap: true)
            }
            let count = max(1, props.count)
            let anchorX = bounds.minX + bounds.width * Double(index + 1) / Double(count + 1)
            let raw = LayoutRect(
                x: anchorX - size / 2,
                y: propBandY,
                width: size,
                height: size)
            return LayoutActor(id: propID, frame: SpatialSafety.fit(raw, in: bounds), zIndex: 80)
        }

        let propCandidates = SpatialSafety.separate(propActors, in: bounds, gap: gap)
        let candidates = memberCandidates + mechCandidates + propCandidates
        let frames = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let layoutSnapshot = SpatialSnapshot(
            virtualBounds: bounds,
            actors: candidates,
            occluders: [])
        let violations = SpatialSafety.check(layoutSnapshot)

        let memberEntities = members.map { member in
            let frame = frames[EntityID(member.id)]?.frame
            return CastVisualEntity(
                id: EntityID(member.id),
                kind: member.kind == .mech ? .mech : .actor,
                displayName: member.displayName,
                visualPackID: member.visualPackID,
                renderable: frame != nil &&
                    (member.visualPackID != nil || (member.kind == .mech && member.visualPackID == nil)),
                frame: frame,
                zIndex: frames[EntityID(member.id)]?.zIndex ?? 100,
                attachedToID: runtime.kernel.world.spatialAttachments[member.id]?.parentID)
        }
        let propEntities = props.map { prop in
            let frame = frames[EntityID(prop.id)]?.frame
            // Cast props intentionally have a guaranteed emoji/fallback path in
            // the AppKit adapter, so a missing dedicated sprite is still visible.
            return CastVisualEntity(
                id: EntityID(prop.id),
                kind: .prop,
                displayName: prop.displayName,
                visualPackID: prop.visualPackID,
                renderable: frame != nil,
                frame: frame,
                zIndex: frames[EntityID(prop.id)]?.zIndex ?? 80,
                attachedToID: attachedTo[prop.id])
        }

        return CastLayoutSnapshot(
            virtualBounds: bounds,
            entities: (memberEntities + propEntities).sorted { $0.id.raw < $1.id.raw },
            violations: violations)
    }
}
