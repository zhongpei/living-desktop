import XCTest
@testable import MyPetCore

final class CastModelTests: XCTestCase {
    func testCastRuntimeStartsFirstStoryBeatInsideTheSameTick() throws {
        let actorID = "actor"
        let requestID = "story/episode/run-1/beat-greet/\(actorID)"
        let pack = CastPack(
            id: "same-tick", groupID: "test", displayName: "Same tick", summary: "",
            members: [
                CastMember(
                    id: actorID, kind: .character, displayName: "Actor",
                    visualPackID: "actor", role: "lead")
            ],
            episodes: [
                StoryEpisode(
                    id: "episode", title: "Episode", participants: [actorID],
                    beats: [
                        StoryBeat(
                            id: "greet", actorIDs: [actorID], intent: "wave",
                            durationTicks: 1)
                    ])
            ])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 1,
                automaticArrivalsEnabled: true),
            arrivalDelayTicks: 0,
            storyConfiguration: StoryDirectorConfiguration(repeatEpisodes: false))

        let report = runtime.tick()

        XCTAssertEqual(report.tick, 0)
        XCTAssertEqual(runtime.kernel.world.behaviors[requestID]?.status, .completed)
        XCTAssertEqual(runtime.consumeStoryActions().map(\.beatID), ["greet"])
    }

    func testLocalizedCastPackSchemaDecodesWithChineseDefaultsAndEnglishDetails() throws {
        let json = #"""
        {
          "id": "journey_west",
          "groupID": "journey_west",
          "displayName": {"zh-Hans": "西游记小队", "en": "Journey to the West"},
          "description": {"zh-Hans": "取经团队", "en": "Pilgrimage cast"},
          "members": [{
            "id": "sun_wukong", "kind": "character",
            "displayName": {"zh-Hans": "孙悟空", "en": "Sun Wukong"},
            "description": {"zh-Hans": "齐天大圣", "en": "Monkey King"},
            "visualPackID": "sun_wukong", "profileID": "sun_wukong", "role": "guardian",
            "entryProfile": "cloud", "exitProfile": "cloud",
            "windowPerchProfile": "swing_perch", "capabilities": ["combat", "window"]
          }],
          "relations": [], "slots": [], "episodes": [],
          "props": [{
            "id": "sacred_scroll",
            "displayName": {"zh-Hans": "经卷", "en": "Sacred Scroll"},
            "description": {"zh-Hans": "取经目标", "en": "Pilgrimage objective"},
            "visualPackID": "book"
          }]
        }
        """#.data(using: .utf8)!

        let pack = try JSONDecoder().decode(CastPack.self, from: json)

        XCTAssertEqual(pack.displayName, "西游记小队")
        XCTAssertEqual(pack.displayNames.en, "Journey to the West")
        XCTAssertEqual(pack.summary, "取经团队")
        XCTAssertEqual(pack.groupID, "journey_west")
        XCTAssertEqual(pack.members[0].profileID, "sun_wukong")
        XCTAssertEqual(pack.members[0].displayName, "孙悟空")
        XCTAssertEqual(pack.members[0].displayNames.en, "Sun Wukong")
        XCTAssertEqual(pack.members[0].entryProfile, .cloud)
        XCTAssertEqual(pack.members[0].exitProfile, .cloud)
        XCTAssertEqual(pack.members[0].windowPerchProfile, .swingPerch)
        XCTAssertEqual(pack.members[0].capabilities, ["combat", "window"])
        XCTAssertEqual(pack.props?.first?.displayNames.en, "Sacred Scroll")
    }

    func testLegacyStringCastLabelsStillDecodeDuringMigration() throws {
        let json = #"""
        {
          "id": "legacy", "groupID": "classic", "displayName": "旧剧组",
          "summary": "旧说明", "members": [{
            "id": "actor", "kind": "character", "displayName": "旧角色", "role": "lead"
          }], "relations": [], "slots": [], "episodes": []
        }
        """#.data(using: .utf8)!

        let pack = try JSONDecoder().decode(CastPack.self, from: json)

        XCTAssertEqual(pack.displayNames, LocalizedLabel(zhHans: "旧剧组", en: "旧剧组"))
        XCTAssertEqual(pack.categoryID, "classic")
        XCTAssertEqual(pack.groupID, "classic")
        XCTAssertEqual(pack.members[0].entryProfile, nil)
        XCTAssertEqual(pack.members[0].capabilities, [])
    }

    func testContentCatalogResolvesRealGroupsProfilesAndBaseRelations() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let catalog = try CastContentLibrary.load(resourcesRoot: resources)
        let resolved = try catalog.resolve(
            CastPackLibrary.loadDirectory(resources.appendingPathComponent("castpacks")))

        XCTAssertEqual(Set(catalog.groups.map(\.id)), Set([
            "dream_red_chamber", "eva", "journey_west", "water_margin"
        ]))
        XCTAssertEqual(Set(catalog.categories.map(\.id)), Set(["anime", "classics", "original"]))
        XCTAssertEqual(Set(resolved.map { $0.pack.groupID }), Set(catalog.groups.map(\.id)))
        let waterMargin = try XCTUnwrap(resolved.first { $0.pack.id == "water_margin" })
        XCTAssertEqual(waterMargin.group.categoryID, "classics")
        XCTAssertEqual(waterMargin.characters["wu_song"]?.displayName, "武松")
        XCTAssertEqual(waterMargin.characters["wu_song"]?.personality.teasing, 40)
        XCTAssertEqual(
            waterMargin.characters["wu_song"]?.dialogue?.fewShot(for: "greet")?.assistant.zhHans,
            "我来了。")
        XCTAssertEqual(waterMargin.characters["pan_jinlian"]?.id, "pan_jinlian")
        XCTAssertEqual(waterMargin.pack.members.first { $0.id == "pan_jinlian" }?.visualPackID,
                       "pan_jinlian")
        let redChamber = try XCTUnwrap(resolved.first { $0.pack.id == "dream_red_chamber" })
        XCTAssertNil(redChamber.pack.members.first { $0.id == "jia_baoyu" }?.visualPackID)
        XCTAssertTrue(catalog.characters.allSatisfy { $0.dialogue != nil })
        XCTAssertEqual(
            waterMargin.pack.initialRelationValues()["wu_song/lu_zhishen/respect"],
            0.72)
    }

    func testContentCatalogRejectsUnknownMembersAndRelationshipStateFields() throws {
        let character = CharacterDefinition(
            id: "a", displayNames: LocalizedLabel(zhHans: "甲", en: "A"),
            background: LocalizedLabel(zhHans: "甲", en: "A"),
            personality: CharacterPersonality(), aptitudes: CharacterAptitudes(),
            performancePrompt: LocalizedLabel(zhHans: "甲", en: "A"))
        let group = CharacterGroup(
            id: "g", categoryID: "test",
            displayNames: LocalizedLabel(zhHans: "组", en: "Group"),
            descriptions: LocalizedLabel(zhHans: "组", en: "Group"),
            memberIDs: ["a", "missing"],
            baseRelations: [CastRelation(
                from: "a", to: "missing", kind: "teammate_of", state: ["unknown": 0.5])])
        let kinds = RelationshipKindCatalog(kinds: [
            RelationshipKindDefinition(
                id: "teammate_of",
                displayNames: LocalizedLabel(zhHans: "队友", en: "Teammate"),
                descriptions: LocalizedLabel(zhHans: "合作关系", en: "Cooperative relation"),
                direction: .symmetric, allowedStateFields: ["trust"])
        ])
        let catalog = CastContentCatalog(characters: [character], groups: [group], relationshipKinds: kinds)

        XCTAssertEqual(Set(catalog.configurationErrors), Set([
            "group g references unknown member missing",
            "group g relation teammate_of uses unsupported state unknown"
        ]))
    }

    func testStoryCatalogFiltersByRelationsFactsAndParticipants() {
        let world = WorldState(
            relationValues: ["a/b/tension": 0.8],
            facts: ["launch_ready": StoryFact(value: "launch_ready", createdAtTick: 2, expiresAtTick: 10)]
        )
        let eligible = StoryCatalog.eligible(
            episodes: [
                StoryEpisode(
                    id: "ok", title: "ok", participants: ["a", "b"],
                    prerequisites: [
                        StoryPrerequisite(relationKey: "a/b/tension", minimum: 0.5),
                        StoryPrerequisite(requiredFact: "launch_ready")
                    ],
                    beats: [StoryBeat(id: "argue", actorIDs: ["a", "b"], intent: "argue")]
                ),
                StoryEpisode(
                    id: "missing", title: "missing", participants: ["a", "c"],
                    beats: [StoryBeat(id: "bad", actorIDs: ["a", "c"], intent: "bad")]
                )
            ],
            world: world,
            tick: 4,
            availableMembers: ["a", "b"]
        )
        XCTAssertEqual(eligible.map(\.id), ["ok"])
    }

    func testStoryDirectorSelectsDeterministicBranchAndCanRunOnce() {
        let episode = StoryEpisode(
            id: "branching", title: "Branching", participants: ["a", "b"],
            branches: [
                StoryBranch(
                    id: "fallback",
                    beats: [StoryBeat(id: "fallback-beat", actorIDs: ["a"], intent: "look")],
                    priority: 0),
                StoryBranch(
                    id: "ready",
                    prerequisites: [StoryPrerequisite(requiredFact: "ready")],
                    beats: [StoryBeat(id: "ready-beat", actorIDs: ["a", "b"], intent: "talk")],
                    priority: 5)
            ])
        let kernel = GameKernel(scenario: HarnessScenario(
            id: "branching", entities: [
                EntityState(id: EntityID("a"), kind: .actor),
                EntityState(id: EntityID("b"), kind: .actor)
            ]))
        kernel.commitStoryEffects([.setFact("ready")])
        _ = kernel.tick()
        let director = StoryDirector(
            episodes: [episode],
            configuration: StoryDirectorConfiguration(repeatEpisodes: false))

        XCTAssertEqual(director.startNext(in: kernel), "branching")
        XCTAssertEqual(director.currentBranchID, "ready")
        XCTAssertEqual(director.drainActions().map { $0.branchID }, ["ready", "ready"])
        _ = kernel.tick()
        director.tick(in: kernel)
        XCTAssertNil(director.currentEpisodeID)
        XCTAssertNil(director.startNext(in: kernel))
        XCTAssertEqual(kernel.world.facts["episode/branching/completed"]?.value,
                       "episode/branching/completed")
    }

    func testCastPackCreatesIndependentEntitiesAndSlots() {
        let pack = CastPack(
            id: "eva",
            groupID: "anime",
            displayName: "EVA",
            summary: "test",
            members: [
                CastMember(id: "rei", kind: .character, displayName: "Rei", visualPackID: "rei_chibi", role: "pilot"),
                CastMember(id: "eva00", kind: .mech, displayName: "EVA-00", role: "mech")
            ],
            slots: [CastSlot(entityID: "eva00", slotID: "cockpit")]
        )
        XCTAssertEqual(Set(pack.initialEntities().map { $0.id.raw }), ["rei", "eva00"])
        XCTAssertEqual(pack.initialSlots().map(\.key), ["eva00/cockpit"])
    }

    func testCastTransitionPlansKeepArrivalAndDepartureSemanticsDeterministic() throws {
        let cloudArrival = CastTransitionPlan.arrival(for: .cloud)
        XCTAssertEqual(cloudArrival.route, .overhead)
        XCTAssertEqual(cloudArrival.cue, "cast.cloud_arrive")
        XCTAssertEqual(cloudArrival.actionCandidates, ["jump", "happy"])
        XCTAssertEqual(cloudArrival.durationTicks, 5)

        let doorDeparture = CastTransitionPlan.departure(for: .door)
        XCTAssertEqual(doorDeparture.phase, .departure)
        XCTAssertEqual(doorDeparture.route, .doorway)
        XCTAssertEqual(doorDeparture.cue, "cast.door_depart")

        let data = try JSONEncoder().encode(cloudArrival)
        XCTAssertEqual(try JSONDecoder().decode(CastTransitionPlan.self, from: data), cloudArrival)
    }

    func testCastTransitionPresentationSamplesRoutesWithoutAppKit() {
        let cloud = CastTransitionPlan.arrival(for: .cloud)
        let cloudStart = cloud.presentation(at: 0)
        let cloudMiddle = cloud.presentation(at: 0.5)
        let cloudEnd = cloud.presentation(at: 1)
        XCTAssertEqual(cloudStart.offsetYRatio, -1)
        XCTAssertLessThan(cloudMiddle.offsetYRatio, 0)
        XCTAssertEqual(cloudEnd.offsetYRatio, 0)
        XCTAssertEqual(cloudStart.opacity, 1)

        let door = CastTransitionPlan.departure(for: .door)
        XCTAssertEqual(door.presentation(at: 0).offsetXRatio, 0)
        XCTAssertEqual(door.presentation(at: 1).offsetXRatio, -1)

        let teleport = CastTransitionPlan.arrival(for: .teleport)
        XCTAssertEqual(teleport.presentation(at: 0).opacity, 0)
        XCTAssertEqual(teleport.presentation(at: 1).opacity, 1)
    }

    func testCastDirectorResolvesTransitionPlanFromMemberStyle() {
        let member = CastMember(
            id: "rei", kind: .character, displayName: "Rei", role: "pilot",
            entryProfile: .teleport, exitProfile: .door)
        let pack = CastPack(
            id: "eva", groupID: "anime", displayName: "EVA", summary: "", members: [member])
        let director = CastDirector(packs: [pack])

        XCTAssertEqual(
            director.transitionPlan(for: "rei", phase: .arrival)?.cue,
            "cast.teleport_arrive")
        XCTAssertEqual(
            director.transitionPlan(for: "rei", phase: .departure)?.cue,
            "cast.door_depart")
        XCTAssertNil(director.transitionPlan(for: "missing", phase: .arrival))
    }

    func testCastSelectionTogglesGroupsAndMembersWithoutChangingDefaultAll() {
        let packs = [
            CastPack(id: "a", groupID: "classic", displayName: "A", summary: "", members: [
                CastMember(id: "a1", kind: .character, displayName: "A1", role: "one")
            ]),
            CastPack(id: "b", groupID: "anime", displayName: "B", summary: "", members: [
                CastMember(id: "b1", kind: .character, displayName: "B1", role: "one")
            ])
        ]
        let all = CastSelection().normalized(availablePacks: packs)
        XCTAssertEqual(all.activeMembers(from: packs).map(\.id), ["a1", "b1"])

        let classicOnly = all.togglingGroup("anime", allGroupIDs: ["anime", "classic"])
        XCTAssertEqual(classicOnly.enabledGroupIDs, ["classic"])
        XCTAssertEqual(classicOnly.activeMembers(from: packs).map(\.id), ["a1"])

        let withoutA1 = classicOnly.togglingMember("a1", allMemberIDs: ["a1", "b1"])
        XCTAssertEqual(withoutA1.enabledMemberIDs, ["b1"])
        XCTAssertTrue(withoutA1.activeMembers(from: packs).isEmpty)
    }

    func testCastSelectionCanExplicitlyDisableAllGroupsOrMembers() {
        let packs = [
            CastPack(id: "a", groupID: "classic", displayName: "A", summary: "", members: [
                CastMember(id: "a1", kind: .character, displayName: "A1", role: "one")
            ])
        ]

        let noGroups = CastSelection(
            allGroupsEnabled: false,
            enabledGroupIDs: [],
            allMembersEnabled: true
        ).normalized(availablePacks: packs)
        XCTAssertTrue(noGroups.activePacks(from: packs).isEmpty)
        XCTAssertTrue(noGroups.activeMembers(from: packs).isEmpty)

        let noMembers = CastSelection(
            allGroupsEnabled: true,
            allMembersEnabled: false,
            enabledMemberIDs: []
        ).normalized(availablePacks: packs)
        XCTAssertEqual(noMembers.activePacks(from: packs).map(\.id), ["a"])
        XCTAssertTrue(noMembers.activeMembers(from: packs).isEmpty)
    }

    func testCastPackResourcesLoadAndExposeFourRequestedGroups() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/castpacks", isDirectory: true)
        let packs = try CastPackLibrary.loadDirectory(root)
        XCTAssertEqual(Set(packs.map(\.id)), Set(["dream_red_chamber", "eva", "journey_west", "water_margin"]))
        XCTAssertEqual(Set(packs.map(\.groupID)), Set(["dream_red_chamber", "eva", "journey_west", "water_margin"]))
        XCTAssertTrue(packs.contains { $0.id == "eva" && $0.members.contains { $0.kind == .mech } })
    }

    func testResolvedCastRuntimeInstallsGroupRelationsAndProfiles() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        let catalog = try CastContentLibrary.load(resourcesRoot: resources)
        let packs = try catalog.resolve(
            CastPackLibrary.loadDirectory(resources.appendingPathComponent("castpacks")))
        let journey = try XCTUnwrap(packs.first { $0.pack.id == "journey_west" })
        let runtime = CastRuntime(
            resolvedPacks: [journey],
            selection: CastSelection(mode: .random, randomCount: 5, maxActiveMembers: 5))

        _ = runtime.start()
        _ = runtime.tick()

        XCTAssertEqual(runtime.kernel.world.relationValues["sun_wukong/tang_sanzang/trust"], 0.72)
        XCTAssertEqual(runtime.characterDefinition(for: "sun_wukong")?.id, "sun_wukong")
        XCTAssertEqual(runtime.director.member("sun_wukong")?.visualPackID, "sun_wukong")
    }

    func testCapabilityGateRejectsCombatBeatBeforeExecution() {
        let socialOnly = CastMember(
            id: "reader", kind: .character, displayName: "Reader", role: "reader",
            capabilities: ["social"])
        let fighter = CastMember(
            id: "fighter", kind: .character, displayName: "Fighter", role: "fighter",
            capabilities: ["combat"])

        XCTAssertFalse(StoryCapabilityGate.canExecute(
            StoryBeat(id: "attack", actorIDs: ["reader"], intent: "attack"),
            membersByID: ["reader": socialOnly]))
        XCTAssertTrue(StoryCapabilityGate.canExecute(
            StoryBeat(id: "attack", actorIDs: ["fighter"], intent: "attack"),
            membersByID: ["fighter": fighter]))
    }

    func testCharacterDefinitionCapabilitiesCannotBeEscalatedByCastPack() {
        let definition = CharacterDefinition(
            id: "reader", displayNames: .init(zhHans: "读者", en: "Reader"),
            background: .init(zhHans: "背景", en: "Background"),
            personality: CharacterPersonality(), aptitudes: CharacterAptitudes(),
            performancePrompt: .init(zhHans: "表演", en: "Perform"),
            capabilities: ["social"])
        let group = CharacterGroup(
            id: "book", categoryID: "test",
            displayNames: .init(zhHans: "书", en: "Book"),
            descriptions: .init(zhHans: "书", en: "Book"), memberIDs: ["reader"])
        let catalog = CastContentCatalog(
            characters: [definition], groups: [group],
            relationshipKinds: RelationshipKindCatalog(kinds: []))
        let pack = CastPack(
            id: "fight", groupID: "book", displayName: "Fight", summary: "",
            members: [CastMember(
                id: "reader", kind: .character, displayName: "Reader",
                profileID: "reader", role: "reader", capabilities: ["combat"])],
            episodes: [StoryEpisode(
                id: "bad", title: "Bad", participants: ["reader"],
                beats: [StoryBeat(id: "attack", actorIDs: ["reader"], intent: "attack")])])

        XCTAssertThrowsError(try catalog.resolve([pack])) { error in
            XCTAssertEqual(
                error as? CastContentError,
                .invalidPack(packID: "fight", reason: "beat attack fails capability gate"))
        }
    }

    func testJourneyWestDeclaresReplayableScrollHandoff() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/castpacks", isDirectory: true)
        let packs = try CastPackLibrary.loadDirectory(root)
        let journey = try XCTUnwrap(packs.first { $0.id == "journey_west" })
        let handoff = try XCTUnwrap(
            journey.episodes
                .flatMap(\.beats)
                .first(where: { $0.id == "hand_off" })?.handoff)

        XCTAssertEqual(handoff.propID, "sacred_scroll")
        XCTAssertEqual(handoff.fromActorID, "tang_sanzang")
        XCTAssertEqual(handoff.toActorID, "sun_wukong")
        XCTAssertEqual(handoff.durationTicks, 4)
    }

    func testGeneratedHandoffSurvivesLaterStoryAbortUntilConsumed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/castpacks", isDirectory: true)
        let packs = try CastPackLibrary.loadDirectory(root)
        let journey = try XCTUnwrap(packs.first { $0.id == "journey_west" })
        let runtime = CastRuntime(
            packs: [journey],
            selection: CastSelection(
                allGroupsEnabled: false,
                enabledGroupIDs: [journey.groupID],
                allMembersEnabled: true,
                maxActiveMembers: journey.members.count,
                automaticArrivalsEnabled: true),
            seed: 48123,
            storyConfiguration: StoryDirectorConfiguration(repeatEpisodes: false))

        _ = runtime.start()
        var queued = false
        for _ in 0..<8 {
            _ = runtime.tick()
            _ = runtime.consumeStoryActions()
            queued = !runtime.storyDirector.snapshot().queuedHandoffEvents.isEmpty
            if queued { break }
        }

        XCTAssertTrue(queued)
        runtime.storyDirector.abortCurrent(in: runtime.kernel)
        let events = runtime.consumeStoryHandoffEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.handoff.propID, "sacred_scroll")
    }

    func testRequestedCastPacksRunRelationshipContactBeats() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/castpacks", isDirectory: true)
        let packs = try CastPackLibrary.loadDirectory(root)

        for pack in packs {
            let selection = CastSelection(
                allGroupsEnabled: false,
                enabledGroupIDs: [pack.groupID],
                allMembersEnabled: true,
                maxActiveMembers: pack.members.count,
                invitationsEnabled: true,
                automaticArrivalsEnabled: true)
            let runtime = CastRuntime(packs: [pack], selection: selection, seed: 48123)
            _ = runtime.start()
            let ticks = pack.id == "eva" ? 60 : 30
            for _ in 0..<ticks { _ = runtime.tick() }

            let projection = CastVisualProjection.project(runtime: runtime)
            XCTAssertTrue(runtime.kernel.manualViolations.isEmpty, pack.id)
            XCTAssertTrue(projection.violations.isEmpty, pack.id)
            XCTAssertTrue(
                projection.entities.contains { $0.kind == .actor && $0.attachedToID != nil },
                "(pack.id) must demonstrate at least one authored actor-to-actor or pilot-to-mech contact beat")
        }
    }

    func testCastProjectionKeepsEveryBandVisibleOnShortDisplay() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/castpacks", isDirectory: true)
        let packs = try CastPackLibrary.loadDirectory(root)
        let journey = try XCTUnwrap(packs.first { $0.id == "journey_west" })
        let selection = CastSelection(
            allGroupsEnabled: false,
            enabledGroupIDs: [journey.groupID],
            allMembersEnabled: true,
            maxActiveMembers: journey.members.count,
            invitationsEnabled: true,
            automaticArrivalsEnabled: true)
        let runtime = CastRuntime(packs: [journey], selection: selection, seed: 61)
        _ = runtime.start()
        for _ in 0..<3 { _ = runtime.tick() }

        let layout = CastVisualProjection.project(
            runtime: runtime,
            in: LayoutRect(x: 0, y: 0, width: 160, height: 120))
        XCTAssertTrue(layout.violations.isEmpty)
        XCTAssertTrue(layout.renderableEntities.allSatisfy { entity in
            guard let frame = entity.frame else { return false }
            return layout.virtualBounds.contains(frame)
        })
    }

    func testCastProjectionUsesEachVisualPackSizeAndAlignsFeet() {
        let pack = CastPack(
            id: "sizes", groupID: "test", displayName: "Sizes", summary: "",
            members: [
                CastMember(id: "wide", kind: .character, displayName: "Wide", visualPackID: "wide-pack", role: "lead"),
                CastMember(id: "narrow", kind: .character, displayName: "Narrow", visualPackID: "narrow-pack", role: "lead")
            ])
        let selection = CastSelection(
            allGroupsEnabled: false, enabledGroupIDs: ["test"],
            allMembersEnabled: true, maxActiveMembers: 2)
        let runtime = CastRuntime(packs: [pack], selection: selection)
        _ = runtime.start()
        _ = runtime.tick()

        let layout = CastVisualProjection.project(
            runtime: runtime,
            in: LayoutRect(x: 0, y: 0, width: 600, height: 500),
            actorSizes: [
                "wide": CastVisualSize(width: 120, height: 100),
                "narrow": CastVisualSize(width: 36, height: 100)
            ])
        let frames = Dictionary(uniqueKeysWithValues: layout.renderableEntities.compactMap {
            entity -> (String, LayoutRect)? in
            guard let frame = entity.frame else { return nil }
            return (entity.id.raw, frame)
        })
        XCTAssertEqual(frames["wide"]?.width, 120)
        XCTAssertEqual(frames["narrow"]?.width, 36)
        XCTAssertEqual(frames["wide"]?.maxY, frames["narrow"]?.maxY)
        XCTAssertTrue(layout.violations.isEmpty)
    }

    func testCastProjectionDoesNotReserveStageSpaceForMissingVisualPack() {
        let pack = CastPack(
            id: "missing-visual", groupID: "test", displayName: "Missing", summary: "",
            members: [
                CastMember(id: "visible", kind: .character, displayName: "Visible",
                           visualPackID: "present-pack", role: "lead"),
                CastMember(id: "missing", kind: .character, displayName: "Missing",
                           visualPackID: "missing-pack", role: "support")
            ])
        let selection = CastSelection(
            allGroupsEnabled: false, enabledGroupIDs: ["test"],
            allMembersEnabled: true, maxActiveMembers: 2)
        let runtime = CastRuntime(packs: [pack], selection: selection)
        _ = runtime.start()
        _ = runtime.tick()

        let layout = CastVisualProjection.project(
            runtime: runtime,
            in: LayoutRect(x: 0, y: 0, width: 240, height: 180),
            renderableMemberIDs: ["visible"])
        XCTAssertEqual(layout.renderableEntities.map { $0.id.raw }, ["visible"])
        XCTAssertTrue(layout.entities.contains { $0.id.raw == "missing" && !$0.renderable })
        XCTAssertTrue(layout.violations.isEmpty)
    }

    func testCastDirectorReplaysArrivalInvitationAndDepartureLifecycle() {
        let pack = CastPack(
            id: "eva",
            groupID: "anime",
            displayName: "EVA",
            summary: "",
            members: [
                CastMember(id: "rei", kind: .character, displayName: "Rei", role: "pilot", arrivalStyle: .walk),
                CastMember(id: "eva00", kind: .mech, displayName: "EVA-00", role: "mech", arrivalStyle: .launch)
            ],
            slots: [CastSlot(entityID: "eva00", slotID: "cockpit")]
        )
        let selection = CastSelection(
            allGroupsEnabled: false,
            enabledGroupIDs: ["anime"],
            allMembersEnabled: false,
            enabledMemberIDs: ["eva00", "rei"],
            maxActiveMembers: 1,
            invitationsEnabled: true)
        let kernel = GameKernel()
        let director = CastDirector(packs: [pack], selection: selection, seed: 7)
        XCTAssertEqual(director.install(in: kernel), ["eva00"])
        _ = kernel.tick()
        XCTAssertTrue(kernel.world.isAlive(EntityID("eva00")))
        XCTAssertEqual(kernel.world.slots["eva00/cockpit"]?.status, .free)
        XCTAssertTrue(kernel.trace.contains { $0.detail.contains("style=launch") })

        XCTAssertTrue(director.depart(memberID: "eva00", in: kernel))
        _ = kernel.tick()
        XCTAssertFalse(kernel.world.isAlive(EntityID("eva00")))
        XCTAssertTrue(director.invite(memberID: "rei", in: kernel))
        _ = kernel.run(ticks: 3)
        XCTAssertTrue(kernel.world.isAlive(EntityID("rei")))
        XCTAssertTrue(director.depart(memberID: "rei", in: kernel))
        _ = kernel.tick()
        XCTAssertFalse(kernel.world.isAlive(EntityID("rei")))
    }

    func testCastRuntimeExposesOnlyKernelConfirmedMembers() {
        let pack = CastPack(
            id: "eva", groupID: "anime", displayName: "EVA", summary: "",
            members: [
                CastMember(id: "rei", kind: .character, displayName: "Rei", role: "pilot"),
                CastMember(id: "asuka", kind: .character, displayName: "Asuka", role: "pilot")
            ])
        let selection = CastSelection(
            allGroupsEnabled: false, enabledGroupIDs: ["anime"],
            allMembersEnabled: false, enabledMemberIDs: ["rei", "asuka"],
            maxActiveMembers: 1, invitationsEnabled: true)
        let runtime = CastRuntime(packs: [pack], selection: selection, arrivalDelayTicks: 2)

        XCTAssertEqual(runtime.start(), ["asuka"])
        XCTAssertTrue(runtime.activeMemberIDs.isEmpty)
        _ = runtime.tick()
        XCTAssertEqual(runtime.activeMemberIDs, ["asuka"])

        XCTAssertTrue(runtime.depart(memberID: "asuka"))
        _ = runtime.tick()
        XCTAssertTrue(runtime.invite(memberID: "rei"))
        XCTAssertFalse(runtime.invite(memberID: "rei"), "同一角色尚未入场时不能重复排队")
        _ = runtime.kernel.run(ticks: 3)
        XCTAssertEqual(runtime.activeMemberIDs, ["rei"])

        XCTAssertTrue(runtime.depart(memberID: "rei"))
        _ = runtime.tick()
        XCTAssertTrue(runtime.activeMemberIDs.isEmpty)
    }

    func testCastRuntimeCanTurnOffAutomaticInitialArrivals() {
        let pack = CastPack(
            id: "one", groupID: "test", displayName: "One", summary: "",
            members: [CastMember(id: "actor", kind: .character, displayName: "Actor", role: "lead")])
        let selection = CastSelection(
            allGroupsEnabled: false, enabledGroupIDs: ["test"],
            allMembersEnabled: false, enabledMemberIDs: ["actor"],
            automaticArrivalsEnabled: false)
        let runtime = CastRuntime(packs: [pack], selection: selection)
        _ = runtime.start()
        _ = runtime.kernel.run(ticks: 3)
        XCTAssertTrue(runtime.activeMemberIDs.isEmpty)
        XCTAssertTrue(runtime.invite(memberID: "actor"))
        _ = runtime.kernel.run(ticks: 3)
        XCTAssertTrue(runtime.activeMemberIDs.contains("actor"))
    }

    func testManualTrayInviteBypassesStoryCandidateAndInvitationSwitches() {
        let pack = CastPack(
            id: "cast", groupID: "test", displayName: "Cast", summary: "",
            members: [
                CastMember(id: "host", kind: .character, displayName: "Host", role: "host"),
                CastMember(id: "guest", kind: .character, displayName: "Guest", role: "guest")
            ])
        let selection = CastSelection(
            allGroupsEnabled: false, enabledGroupIDs: ["test"],
            allMembersEnabled: false, enabledMemberIDs: ["host"],
            maxActiveMembers: 2, invitationsEnabled: false)
        let runtime = CastRuntime(packs: [pack], selection: selection, arrivalDelayTicks: 2)
        _ = runtime.start()
        _ = runtime.tick()

        XCTAssertFalse(runtime.invite(memberID: "guest"))
        XCTAssertTrue(runtime.inviteManually(memberID: "guest"))
        _ = runtime.kernel.run(ticks: 3)
        XCTAssertTrue(runtime.activeMemberIDs.contains("guest"))
    }

    func testManualInitialCastPrefersVisibleCharactersBeforeMechs() {
        let pack = CastPack(
            id: "mixed", groupID: "test", displayName: "Mixed", summary: "",
            members: [
                CastMember(id: "a-mech", kind: .mech, displayName: "Mech", role: "mech"),
                CastMember(
                    id: "z-character", kind: .character, displayName: "Character",
                    visualPackID: "character-pack", role: "lead")
            ])
        let director = CastDirector(
            packs: [pack],
            selection: CastSelection(maxActiveMembers: 1, automaticArrivalsEnabled: true))

        XCTAssertEqual(director.install(in: GameKernel()), ["z-character"])
    }

    func testDormantCastPropsAreNotProjectedUntilAStoryUsesThem() {
        let pack = CastPack(
            id: "props", groupID: "test", displayName: "Props", summary: "",
            members: [CastMember(id: "actor", kind: .character, displayName: "Actor", role: "lead")],
            slots: [CastSlot(entityID: "book", slotID: "pages")],
            props: [CastProp(id: "book", displayName: "Book", visualPackID: "book")])
        let runtime = CastRuntime(packs: [pack], selection: CastSelection(maxActiveMembers: 1))
        _ = runtime.start()
        _ = runtime.tick()

        XCTAssertTrue(runtime.activeProps.contains { $0.id == "book" })
        XCTAssertFalse(runtime.presentedProps.contains { $0.id == "book" })
        XCTAssertFalse(CastVisualProjection.project(runtime: runtime).entities.contains {
            $0.id.raw == "book"
        })
    }

    func testCastSelectionDecodesOlderSettingsWithoutRotationKeys() throws {
        let data = #"{"mode":"manual","allGroupsEnabled":true,"enabledGroupIDs":[],"allMembersEnabled":true,"enabledMemberIDs":[],"randomCount":1,"maxActiveMembers":1,"invitationsEnabled":true,"automaticArrivalsEnabled":true}"#.data(using: .utf8)!
        let selection = try JSONDecoder().decode(CastSelection.self, from: data)
        XCTAssertFalse(selection.automaticRotationEnabled)
        XCTAssertEqual(selection.rotationIntervalTicks, 0)
    }

    func testAutomaticRotationReplacesMembersDeterministically() {
        let pack = CastPack(
            id: "rotation", groupID: "test", displayName: "Rotation", summary: "",
            members: (0..<3).map {
                CastMember(id: "member-\($0)", kind: .character,
                           displayName: "Member \($0)", role: "lead")
            })
        let selection = CastSelection(
            mode: .random,
            allGroupsEnabled: false,
            enabledGroupIDs: ["test"],
            allMembersEnabled: true,
            randomCount: 1,
            maxActiveMembers: 1,
            invitationsEnabled: true,
            automaticArrivalsEnabled: true,
            automaticRotationEnabled: true,
            rotationIntervalTicks: 6)
        let first = CastRuntime(packs: [pack], selection: selection, seed: 99)
        let second = CastRuntime(packs: [pack], selection: selection, seed: 99)
        _ = first.start()
        _ = second.start()
        for _ in 0..<10 {
            _ = first.tick()
            _ = second.tick()
            XCTAssertLessThanOrEqual(first.activeMemberIDs.count, 1)
            XCTAssertLessThanOrEqual(second.activeMemberIDs.count, 1)
        }
        XCTAssertEqual(first.kernel.trace, second.kernel.trace)
        XCTAssertEqual(first.kernel.world.stableDigest(), second.kernel.world.stableDigest())
        XCTAssertEqual(first.activeMemberIDs.count, 1)
        XCTAssertEqual(first.kernel.trace.filter { $0.kind == "event" && $0.detail.contains("castDepart") }.count, 1)
        XCTAssertEqual(first.kernel.trace.filter { $0.kind == "event" && $0.detail.contains("castArrive") }.count, 2)
    }

    func testStoryBeatCanInviteAnotherMemberThroughCastRuntime() {
        let pack = CastPack(
            id: "invite-story", groupID: "test", displayName: "Invite", summary: "",
            members: [
                CastMember(id: "host", kind: .character, displayName: "Host", role: "lead"),
                CastMember(id: "guest", kind: .character, displayName: "Guest", role: "guest")
            ],
            episodes: [StoryEpisode(
                id: "call-guest", title: "Call guest", participants: ["host"],
                beats: [StoryBeat(
                    id: "call", actorIDs: ["host"], intent: "invite_guest", durationTicks: 1,
                    inviteMemberIDs: ["guest"])])])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 2,
                automaticArrivalsEnabled: false),
            arrivalDelayTicks: 1)
        _ = runtime.start()
        XCTAssertTrue(runtime.invite(memberID: "host"))
        for _ in 0..<6 {
            _ = runtime.tick()
            _ = runtime.consumeStoryActions()
        }
        XCTAssertTrue(runtime.activeMemberIDs.contains("host"))
        XCTAssertTrue(runtime.activeMemberIDs.contains("guest"))
        XCTAssertTrue(runtime.kernel.trace.contains {
            $0.kind == "event" && $0.detail.contains("castInvite") && $0.detail.contains("guest")
        })
        XCTAssertTrue(runtime.kernel.manualViolations.isEmpty)
    }

    func testStoryBeatTargetsCastPropAndOccupiesItsSlot() {
        let pack = CastPack(
            id: "prop-story", groupID: "test", displayName: "Prop story", summary: "",
            members: [CastMember(
                id: "actor", kind: .character, displayName: "Actor",
                visualPackID: "actor-pack", role: "lead")],
            slots: [CastSlot(entityID: "tea-prop", slotID: "handle")],
            episodes: [StoryEpisode(
                id: "use-tea", title: "Use tea", participants: ["actor", "tea-prop"],
                beats: [StoryBeat(
                    id: "pick", actorIDs: ["actor"], intent: "drink",
                    durationTicks: 1, targetID: "tea-prop", slotID: "handle",
                    claims: ["body", "hand"], occupySlotOnSuccess: true)],
                cooldownTicks: 30)],
            props: [CastProp(id: "tea-prop", displayName: "Tea", visualPackID: "tea")])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 1,
                automaticArrivalsEnabled: false),
            arrivalDelayTicks: 1)
        _ = runtime.start()
        XCTAssertTrue(runtime.invite(memberID: "actor"))
        var actions: [StoryAction] = []
        for _ in 0..<4 {
            _ = runtime.tick()
            actions.append(contentsOf: runtime.consumeStoryActions())
        }
        XCTAssertEqual(runtime.kernel.world.entities["tea-prop"]?.kind, .prop)
        XCTAssertEqual(runtime.kernel.world.slots["tea-prop/handle"]?.status, .occupied)
        XCTAssertEqual(actions.first?.targetID, "tea-prop")
        let projection = CastVisualProjection.project(
            runtime: runtime,
            in: LayoutRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(
            projection.entities.first(where: { $0.id.raw == "tea-prop" })?.attachedToID?.raw,
            "actor")
        XCTAssertTrue(projection.entities.first(where: { $0.id.raw == "tea-prop" })?.renderable == true)
        XCTAssertTrue(projection.violations.isEmpty)
        XCTAssertTrue(runtime.kernel.manualViolations.isEmpty)
    }

    func testStoryBeatReleasesPropForNextActorToReceiveIt() {
        let pack = CastPack(
            id: "handoff-story", groupID: "test", displayName: "Handoff story", summary: "",
            members: [
                CastMember(id: "giver", kind: .character, displayName: "Giver", visualPackID: "giver-pack", role: "lead"),
                CastMember(id: "receiver", kind: .character, displayName: "Receiver", visualPackID: "receiver-pack", role: "guest")
            ],
            slots: [CastSlot(entityID: "scroll", slotID: "surface")],
            episodes: [StoryEpisode(
                id: "scroll-handoff", title: "Hand off scroll", participants: ["giver", "receiver"],
                beats: [
                    StoryBeat(
                        id: "take", actorIDs: ["giver"], intent: "give", durationTicks: 1,
                        targetID: "scroll", slotID: "surface", claims: ["body", "manipulator"],
                        occupySlotOnSuccess: true, releaseSlotOnSuccess: true,
                        handoff: StoryHandoff(
                            propID: "scroll",
                            fromActorID: "giver",
                            toActorID: "receiver",
                            fromSlotID: "surface",
                            toSlotID: "surface",
                            durationTicks: 3)),
                    StoryBeat(
                        id: "receive", actorIDs: ["receiver"], intent: "receive", durationTicks: 1,
                        targetID: "scroll", slotID: "surface", claims: ["body", "manipulator"],
                        occupySlotOnSuccess: true)
                ])],
            props: [CastProp(id: "scroll", displayName: "Scroll", visualPackID: "book")])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 2,
                automaticArrivalsEnabled: true),
            arrivalDelayTicks: 1,
            storyConfiguration: StoryDirectorConfiguration(repeatEpisodes: false))

        _ = runtime.start()
        var handoffs: [StoryHandoffEvent] = []
        for _ in 0..<8 {
            _ = runtime.tick()
            _ = runtime.consumeStoryActions()
            handoffs.append(contentsOf: runtime.consumeStoryHandoffEvents())
        }

        XCTAssertEqual(handoffs.count, 1)
        XCTAssertEqual(handoffs.first?.episodeID, "scroll-handoff")
        XCTAssertEqual(handoffs.first?.beatID, "take")
        XCTAssertEqual(handoffs.first?.handoff.propID, "scroll")
        XCTAssertEqual(handoffs.first?.handoff.fromActorID, "giver")
        XCTAssertEqual(handoffs.first?.handoff.toActorID, "receiver")
        let slot = runtime.kernel.world.slots["scroll/surface"]
        XCTAssertEqual(slot?.status, .occupied)
        XCTAssertEqual(slot?.occupants.map(\.actorID.raw), ["receiver"])
        XCTAssertEqual(runtime.kernel.world.spatialAttachments["scroll"]?.parentID.raw, "receiver")
        XCTAssertEqual(runtime.kernel.world.spatialAttachments["scroll"]?.socketID, "surface")
        XCTAssertTrue(runtime.kernel.trace.contains {
            $0.kind == "event" && $0.detail.hasPrefix("releaseSlot:scroll/surface:scope=story/")
        })
        let projection = CastVisualProjection.project(
            runtime: runtime,
            in: LayoutRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(
            projection.entities.first(where: { $0.id.raw == "scroll" })?.attachedToID?.raw,
            "receiver")
        XCTAssertTrue(projection.violations.isEmpty)
        XCTAssertTrue(runtime.kernel.manualViolations.isEmpty)
    }

    func testStoryHandoffIgnoresAnUnmatchedReceiveBeat() {
        let pack = CastPack(
            id: "invalid-handoff-story", groupID: "test", displayName: "Invalid handoff", summary: "",
            members: [
                CastMember(id: "giver", kind: .character, displayName: "Giver", visualPackID: "giver-pack", role: "lead"),
                CastMember(id: "receiver", kind: .character, displayName: "Receiver", visualPackID: "receiver-pack", role: "guest")
            ],
            slots: [CastSlot(entityID: "scroll", slotID: "surface")],
            episodes: [StoryEpisode(
                id: "invalid-scroll-handoff", title: "Invalid handoff", participants: ["giver", "receiver"],
                beats: [
                    StoryBeat(
                        id: "give", actorIDs: ["giver"], intent: "give", durationTicks: 1,
                        targetID: "scroll", slotID: "surface", claims: ["body", "manipulator"],
                        occupySlotOnSuccess: true, releaseSlotOnSuccess: true,
                        handoff: StoryHandoff(
                            propID: "scroll",
                            fromActorID: "giver",
                            toActorID: "receiver",
                            fromSlotID: "surface",
                            toSlotID: "surface")),
                    StoryBeat(id: "look", actorIDs: ["receiver"], intent: "look", durationTicks: 1)
                ])],
            props: [CastProp(id: "scroll", displayName: "Scroll", visualPackID: "book")])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 2,
                automaticArrivalsEnabled: true),
            arrivalDelayTicks: 1,
            storyConfiguration: StoryDirectorConfiguration(repeatEpisodes: false))

        _ = runtime.start()
        var handoffs: [StoryHandoffEvent] = []
        for _ in 0..<8 {
            _ = runtime.tick()
            _ = runtime.consumeStoryActions()
            handoffs.append(contentsOf: runtime.consumeStoryHandoffEvents())
        }

        XCTAssertTrue(handoffs.isEmpty)
        XCTAssertTrue(runtime.kernel.manualViolations.isEmpty)
    }

    func testStoryBeatCanReleaseAnOccupiedMechCockpitWithoutReclaimingIt() {
        let pack = CastPack(
            id: "cockpit-story", groupID: "test", displayName: "Cockpit story", summary: "",
            members: [
                CastMember(id: "pilot", kind: .character, displayName: "Pilot", visualPackID: "pilot-pack", role: "pilot"),
                CastMember(id: "mech", kind: .mech, displayName: "Mech", role: "mech")
            ],
            slots: [CastSlot(entityID: "mech", slotID: "cockpit")],
            episodes: [StoryEpisode(
                id: "cockpit-cycle", title: "Cockpit cycle", participants: ["pilot", "mech"],
                beats: [
                    StoryBeat(
                        id: "enter", actorIDs: ["pilot"], intent: "enter_cockpit", durationTicks: 1,
                        targetID: "mech", slotID: "cockpit", claims: ["body", "locomotion"],
                        occupySlotOnSuccess: true),
                    StoryBeat(
                        id: "exit", actorIDs: ["pilot"], intent: "exit_cockpit", durationTicks: 1,
                        targetID: "mech", slotID: "cockpit", claims: ["body", "locomotion"],
                        releaseSlotOnSuccess: true)
                ])])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 2,
                automaticArrivalsEnabled: true),
            arrivalDelayTicks: 1,
            storyConfiguration: StoryDirectorConfiguration(repeatEpisodes: false))

        _ = runtime.start()
        for _ in 0..<8 {
            _ = runtime.tick()
            _ = runtime.consumeStoryActions()
        }

        XCTAssertEqual(runtime.kernel.world.slots["mech/cockpit"]?.status, .free)
        XCTAssertNil(runtime.kernel.world.spatialAttachments["pilot"])
        XCTAssertTrue(runtime.kernel.trace.contains {
            $0.kind == "event" && $0.detail == "releaseSlot:mech/cockpit:scope=pilot"
        })
        XCTAssertTrue(runtime.kernel.manualViolations.isEmpty)
    }

    func testCastProjectionIncludesMissingVisualMembersButNotDormantProps() {
        let pack = CastPack(
            id: "projection", groupID: "test", displayName: "Projection", summary: "",
            members: [
                CastMember(id: "actor", kind: .character, displayName: "Actor", visualPackID: "actor-pack", role: "lead"),
                CastMember(id: "mech", kind: .mech, displayName: "Mech", visualPackID: nil, role: "mech")
            ],
            slots: [CastSlot(entityID: "mech", slotID: "cockpit")],
            props: [CastProp(id: "scroll", displayName: "Scroll", visualPackID: "book")])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 2,
                automaticArrivalsEnabled: true),
            arrivalDelayTicks: 1)
        _ = runtime.start()
        _ = runtime.tick()
        _ = runtime.tick()
        let cockpit = try! XCTUnwrap(runtime.kernel.world.slots["mech/cockpit"])
        runtime.kernel.enqueue(GameEvent(kind: .behaviorRequest, request: BehaviorRequest(
            id: "pilot-enter", actorID: EntityID("actor"), intent: "enter_cockpit",
            priority: .story, target: EntityRef(entityID: EntityID("mech"), revision: 0),
            slot: cockpit.ref, claims: ["body", "locomotion"], durationTicks: 1,
            occupySlotOnSuccess: true)))
        _ = runtime.tick()

        let snapshot = CastVisualProjection.project(
            runtime: runtime,
            in: LayoutRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertTrue(snapshot.violations.isEmpty)
        XCTAssertEqual(snapshot.entities.map { $0.id.raw }, ["actor", "mech"])
        XCTAssertFalse(snapshot.entities.contains { $0.id.raw == "scroll" })
        XCTAssertEqual(
            snapshot.entities.first { $0.id.raw == "actor" }?.attachedToID?.raw,
            "mech")
        XCTAssertEqual(runtime.kernel.world.spatialAttachments["actor"]?.parentID.raw, "mech")
        let actorFrame = try! XCTUnwrap(snapshot.entities.first { $0.id.raw == "actor" }?.frame)
        let mechFrame = try! XCTUnwrap(snapshot.entities.first { $0.id.raw == "mech" }?.frame)
        XCTAssertTrue(mechFrame.contains(actorFrame), "attached cockpit actor must be rendered inside its mech")
        XCTAssertTrue(snapshot.entities.first { $0.id.raw == "mech" }?.renderable == true)
        XCTAssertEqual(snapshot.renderableEntities.count, 2)
    }

    func testCastProjectionPresentsActorToActorAttachmentAtContactSocket() {
        let pack = CastPack(
            id: "social-contact", groupID: "test", displayName: "Social contact", summary: "",
            members: [
                CastMember(id: "host", kind: .character, displayName: "Host", visualPackID: "host-pack", role: "lead"),
                CastMember(id: "guest", kind: .character, displayName: "Guest", visualPackID: "guest-pack", role: "guest")
            ],
            slots: [CastSlot(entityID: "host", slotID: "shoulder")],
            episodes: [StoryEpisode(
                id: "shoulder-contact", title: "Shoulder contact", participants: ["host", "guest"],
                beats: [StoryBeat(
                    id: "lean", actorIDs: ["guest"], intent: "comfort", durationTicks: 1,
                    targetID: "host", slotID: "shoulder", claims: ["body"],
                    occupySlotOnSuccess: true)])])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 2,
                automaticArrivalsEnabled: true),
            arrivalDelayTicks: 1,
            storyConfiguration: StoryDirectorConfiguration(repeatEpisodes: false))

        _ = runtime.start()
        for _ in 0..<5 { _ = runtime.tick(); _ = runtime.consumeStoryActions() }

        XCTAssertEqual(runtime.kernel.world.spatialAttachments["guest"]?.parentID.raw, "host")
        let snapshot = CastVisualProjection.project(
            runtime: runtime,
            in: LayoutRect(x: 0, y: 0, width: 600, height: 400))
        let hostFrame = try! XCTUnwrap(snapshot.entities.first { $0.id.raw == "host" }?.frame)
        let guest = try! XCTUnwrap(snapshot.entities.first { $0.id.raw == "guest" })
        let guestFrame = try! XCTUnwrap(guest.frame)
        XCTAssertEqual(guest.attachedToID?.raw, "host")
        XCTAssertNotNil(hostFrame.intersection(guestFrame), "actor-to-actor contact must be visible")
        XCTAssertTrue(snapshot.violations.isEmpty)
    }

    func testCastProjectionDoesNotLetMissingVisualMembersConsumeStageSlots() {
        let pack = CastPack(
            id: "projection-many", groupID: "test", displayName: "Projection", summary: "",
            members: [
                CastMember(id: "first", kind: .character, displayName: "First", visualPackID: "first-pack", role: "lead"),
                CastMember(id: "missing-a", kind: .mech, displayName: "Missing A", role: "mech"),
                CastMember(id: "missing-b", kind: .mech, displayName: "Missing B", role: "mech"),
                CastMember(id: "last", kind: .character, displayName: "Last", visualPackID: "last-pack", role: "lead")
            ])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: true, maxActiveMembers: 4,
                automaticArrivalsEnabled: true),
            arrivalDelayTicks: 1)
        _ = runtime.start()
        _ = runtime.tick()
        _ = runtime.tick()

        let snapshot = CastVisualProjection.project(
            runtime: runtime,
            in: LayoutRect(x: 0, y: 0, width: 600, height: 400))
        let visible = snapshot.entities.filter { $0.renderable && $0.kind == .actor }
        XCTAssertEqual(visible.map { $0.id.raw }, ["first", "last"])
        let firstMidX = (visible[0].frame?.x ?? -1) + (visible[0].frame?.width ?? 0) / 2
        let lastMidX = (visible[1].frame?.x ?? -1) + (visible[1].frame?.width ?? 0) / 2
        XCTAssertEqual(firstMidX, 200, accuracy: 0.001)
        XCTAssertEqual(lastMidX, 400, accuracy: 0.001)
        XCTAssertTrue(snapshot.violations.isEmpty)
    }

    func testStoryDirectorCommitsEffectsOnlyAfterAllActorsComplete() {
        let actors = [
            EntityState(id: EntityID("a"), kind: .actor),
            EntityState(id: EntityID("b"), kind: .actor)
        ]
        let episode = StoryEpisode(
            id: "argument", title: "Argument", participants: ["a", "b"],
            beats: [StoryBeat(
                id: "talk", actorIDs: ["a", "b"], intent: "argue", durationTicks: 1,
                effectsOnSuccess: [.relationDelta("a/b/tension", 0.1)])])
        let kernel = GameKernel(scenario: HarnessScenario(id: "story", entities: actors))
        _ = kernel.tick()
        let director = StoryDirector(episodes: [episode])
        XCTAssertEqual(director.startNext(in: kernel), "argument")
        XCTAssertEqual(director.drainActions().count, 2)
        _ = kernel.tick()
        director.tick(in: kernel)
        XCTAssertEqual(kernel.world.relationValues["a/b/tension"], 0.1)
        XCTAssertEqual(kernel.world.facts["episode/argument/completed"]?.value,
                       "episode/argument/completed")
        XCTAssertNil(director.currentEpisodeID)
        XCTAssertEqual(director.completedEpisodeCount, 1)
        XCTAssertTrue(kernel.trace.contains {
            $0.kind == "story-effect" && $0.detail.contains("relation:a/b/tension:+0.1")
        })
    }

    func testStoryDirectorInterruptsWithoutCommittingBeatEffects() {
        let actors = [
            EntityState(id: EntityID("a"), kind: .actor),
            EntityState(id: EntityID("b"), kind: .actor)
        ]
        let episode = StoryEpisode(
            id: "argument", title: "Argument", participants: ["a", "b"],
            beats: [StoryBeat(
                id: "talk", actorIDs: ["a", "b"], intent: "argue", durationTicks: 4,
                effectsOnSuccess: [.relationDelta("a/b/tension", 0.1)])])
        let kernel = GameKernel(scenario: HarnessScenario(id: "story", entities: actors))
        _ = kernel.tick()
        let director = StoryDirector(episodes: [episode])
        XCTAssertEqual(director.startNext(in: kernel), "argument")
        _ = kernel.tick()
        kernel.enqueue(GameEvent(kind: .cancelBehavior,
                                 behaviorID: "story/argument/run-1/beat-talk/a"))
        _ = kernel.tick()
        director.tick(in: kernel)
        XCTAssertNil(kernel.world.relationValues["a/b/tension"])
        XCTAssertEqual(director.interruptedEpisodeID, "argument")
        XCTAssertTrue(kernel.trace.contains {
            $0.kind == "story-effect" && $0.detail.contains("fact:episode/argument/interrupted")
        })
    }

    func testStoryConfigurationDisablesEpisodesAndCapsLongEpisode() {
        let actors = [
            EntityState(id: EntityID("a"), kind: .actor),
            EntityState(id: EntityID("b"), kind: .actor)
        ]
        let episode = StoryEpisode(
            id: "long", title: "Long", participants: ["a", "b"],
            beats: [StoryBeat(id: "talk", actorIDs: ["a", "b"], intent: "talk", durationTicks: 20)])

        let disabledKernel = GameKernel(scenario: HarnessScenario(id: "disabled", entities: actors))
        let disabled = StoryDirector(
            episodes: [episode],
            configuration: StoryDirectorConfiguration(enabled: false))
        XCTAssertNil(disabled.startNext(in: disabledKernel))
        XCTAssertNil(disabled.currentEpisodeID)

        let cappedKernel = GameKernel(scenario: HarnessScenario(id: "capped", entities: actors))
        let capped = StoryDirector(
            episodes: [episode],
            configuration: StoryDirectorConfiguration(maxDurationTicks: 1))
        XCTAssertEqual(capped.startNext(in: cappedKernel), "long")
        _ = cappedKernel.tick()
        capped.tick(in: cappedKernel)

        XCTAssertEqual(capped.interruptedEpisodeID, "long")
        XCTAssertNil(capped.currentEpisodeID)
        XCTAssertEqual(cappedKernel.world.facts["episode/long/interrupted"]?.value,
                       "episode/long/interrupted")
    }

    func testStoryConfigurationCanKeepFactsWithoutApplyingRelationshipEffects() {
        let actors = [
            EntityState(id: EntityID("a"), kind: .actor),
            EntityState(id: EntityID("b"), kind: .actor)
        ]
        let episode = StoryEpisode(
            id: "quiet", title: "Quiet", participants: ["a", "b"],
            beats: [StoryBeat(
                id: "talk", actorIDs: ["a", "b"], intent: "talk", durationTicks: 1,
                effectsOnSuccess: [
                    .relationDelta("a/b/trust", 0.5),
                    .setFact("quiet/fact")
                ])])
        let kernel = GameKernel(scenario: HarnessScenario(id: "relations-off", entities: actors))
        let director = StoryDirector(
            episodes: [episode],
            configuration: StoryDirectorConfiguration(relationshipEffectsEnabled: false))

        XCTAssertEqual(director.startNext(in: kernel), "quiet")
        _ = kernel.tick()
        director.tick(in: kernel)

        XCTAssertNil(kernel.world.relationValues["a/b/trust"])
        XCTAssertEqual(kernel.world.facts["quiet/fact"]?.value, "quiet/fact")
        XCTAssertEqual(kernel.world.facts["episode/quiet/completed"]?.value,
                       "episode/quiet/completed")
    }

    func testCastRuntimeCheckpointRestoresStoryCursorAndEffectsExactly() {
        let pack = CastPack(
            id: "checkpoint", groupID: "test", displayName: "Checkpoint", summary: "",
            members: [
                CastMember(id: "a", kind: .character, displayName: "A", role: "lead"),
                CastMember(id: "b", kind: .character, displayName: "B", role: "lead")
            ],
            episodes: [StoryEpisode(
                id: "beat", title: "Beat", participants: ["a", "b"],
                beats: [StoryBeat(
                    id: "talk", actorIDs: ["a", "b"], intent: "talk", durationTicks: 3,
                    effectsOnSuccess: [.relationDelta("a/b/trust", 0.25)])],
                cooldownTicks: 20)])
        let runtime = CastRuntime(
            packs: [pack],
            selection: CastSelection(
                allGroupsEnabled: false, enabledGroupIDs: ["test"],
                allMembersEnabled: false, enabledMemberIDs: ["a", "b"],
                maxActiveMembers: 2),
            seed: 7)

        _ = runtime.start()
        _ = runtime.tick()
        _ = runtime.tick()
        let checkpoint = runtime.snapshot()

        for _ in 0..<2 { _ = runtime.tick() }
        let expectedDigest = runtime.kernel.world.stableDigest()
        let expectedTrace = runtime.kernel.trace
        XCTAssertEqual(runtime.kernel.world.relationValues["a/b/trust"], 0.25)
        XCTAssertEqual(runtime.storyDirector.completedEpisodeCount, 1)

        let restored = CastRuntime(snapshot: checkpoint, packs: [pack])
        for _ in 0..<2 { _ = restored.tick() }
        XCTAssertEqual(restored.kernel.world.stableDigest(), expectedDigest)
        XCTAssertEqual(restored.kernel.trace, expectedTrace)
        XCTAssertEqual(restored.kernel.world.relationValues["a/b/trust"], 0.25)
        XCTAssertEqual(restored.storyDirector.completedEpisodeCount, 1)

        let completedSnapshot = runtime.snapshot()
        let restoredCompleted = CastRuntime(snapshot: completedSnapshot, packs: [pack])
        XCTAssertEqual(restoredCompleted.storyDirector.completedEpisodeCount, 1)
        let encodedDirector = try! JSONEncoder().encode(completedSnapshot.storyDirector)
        let decodedDirector = try! JSONDecoder().decode(
            StoryDirectorSnapshot.self, from: encodedDirector)
        XCTAssertEqual(decodedDirector.completedEpisodeCount, 1)
    }
}
