import Foundation
import MyPetCore
import MyPetEngine

public struct SimulationActionDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var family: String
    public var requiredCapability: String?

    public init(id: String, family: String, requiredCapability: String? = nil) {
        self.id = id
        self.family = family
        self.requiredCapability = requiredCapability
    }
}

public enum SimulationActionSupportMode: String, Codable, Sendable {
    case all
    case allowlist
}

public struct SimulationActionSupport: Codable, Equatable, Sendable {
    public var mode: SimulationActionSupportMode
    public var actions: [String]?

    public init(mode: SimulationActionSupportMode, actions: [String]? = nil) {
        self.mode = mode
        self.actions = actions
    }

    public func contains(_ action: String) -> Bool {
        mode == .all || (actions ?? []).contains(action)
    }
}

public enum SimulationExactAssetMode: String, Codable, Sendable {
    case all
}

public struct SimulationRoleAssets: Codable, Equatable, Sendable {
    public var exactMode: SimulationExactAssetMode?
    public var exactActions: [String]?
    public var fallbackActions: [String: [String]]?

    public init(
        exactMode: SimulationExactAssetMode? = nil,
        exactActions: [String]? = nil,
        fallbackActions: [String: [String]]? = nil
    ) {
        self.exactMode = exactMode
        self.exactActions = exactActions
        self.fallbackActions = fallbackActions
    }
}

public struct SimulationRoleDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var capabilities: [String]
    public var support: SimulationActionSupport
    public var assets: SimulationRoleAssets

    public init(
        id: String, capabilities: [String], support: SimulationActionSupport,
        assets: SimulationRoleAssets = SimulationRoleAssets()
    ) {
        self.id = id
        self.capabilities = capabilities
        self.support = support
        self.assets = assets
    }
}

public enum SimulationActionMatrixStatus: String, Codable, Sendable {
    case exact
    case fallback
    case missing
    case unsupported
    case failed
}

public struct SimulationClassicStep: Codable, Equatable, Sendable {
    public var role: String
    public var action: String
    public var expected: SimulationActionMatrixStatus

    public init(role: String, action: String, expected: SimulationActionMatrixStatus) {
        self.role = role
        self.action = action
        self.expected = expected
    }
}

public struct SimulationClassicScenario: Codable, Equatable, Sendable {
    public var id: String
    public var category: String?
    public var steps: [SimulationClassicStep]

    public init(id: String, category: String? = nil, steps: [SimulationClassicStep]) {
        self.id = id
        self.category = category
        self.steps = steps
    }
}

public struct SimulationSuiteConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var actions: [SimulationActionDefinition]
    public var roles: [SimulationRoleDefinition]
    public var classicScenarios: [SimulationClassicScenario]

    public init(
        schemaVersion: Int = 1,
        actions: [SimulationActionDefinition],
        roles: [SimulationRoleDefinition],
        classicScenarios: [SimulationClassicScenario]
    ) {
        self.schemaVersion = schemaVersion
        self.actions = actions
        self.roles = roles
        self.classicScenarios = classicScenarios
    }

    public static func loadJSON(at url: URL) throws -> SimulationSuiteConfiguration {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public var configurationErrors: [String] {
        var errors: [String] = []
        if schemaVersion != 1 { errors.append("unsupported simulation suite schema \(schemaVersion)") }
        let actionIDs = Set(actions.map(\.id))
        let roleIDs = Set(roles.map(\.id))
        if actionIDs.count != actions.count { errors.append("duplicate action id") }
        if roleIDs.count != roles.count { errors.append("duplicate role id") }
        if Set(classicScenarios.map(\.id)).count != classicScenarios.count {
            errors.append("duplicate classic scenario id")
        }
        for role in roles {
            let fallbackKeys = Array((role.assets.fallbackActions ?? [:]).keys)
            let declared = Set(role.support.actions ?? [])
                .union(role.assets.exactActions ?? [])
                .union(fallbackKeys)
            for action in declared where !actionIDs.contains(action) {
                errors.append("role \(role.id) references unknown action \(action)")
            }
            for action in actions where role.support.contains(action.id) {
                if let capability = action.requiredCapability,
                   !role.capabilities.contains(capability) {
                    errors.append("role \(role.id) supports \(action.id) without capability \(capability)")
                }
            }
        }
        for scenario in classicScenarios {
            for step in scenario.steps {
                if !roleIDs.contains(step.role) {
                    errors.append("scenario \(scenario.id) references unknown role \(step.role)")
                }
                if !actionIDs.contains(step.action) {
                    errors.append("scenario \(scenario.id) references unknown action \(step.action)")
                }
            }
        }
        return Array(Set(errors)).sorted()
    }
}

public struct SimulationActionMatrixResult: Codable, Equatable, Sendable {
    public var role: String
    public var action: String
    public var family: String
    public var status: SimulationActionMatrixStatus
    public var resolvedAction: String?
    public var completed: Bool
}

public struct SimulationClassicStepResult: Codable, Equatable, Sendable {
    public var sequence: Int
    public var role: String
    public var action: String
    public var expected: SimulationActionMatrixStatus
    public var actual: SimulationActionMatrixStatus
    public var completed: Bool
}

public struct SimulationClassicScenarioResult: Codable, Equatable, Sendable {
    public var id: String
    public var passed: Bool
    public var steps: [SimulationClassicStepResult]
    public var failures: [String]
}

public struct SimulationSuiteReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var passed: Bool
    public var configurationErrors: [String]
    public var matrix: [SimulationActionMatrixResult]
    public var scenarios: [SimulationClassicScenarioResult]
    public var semanticCharacters: [SimulationCharacterSemanticResult]

    public func result(role: String, action: String) -> SimulationActionMatrixResult? {
        matrix.first { $0.role == role && $0.action == action }
    }
}

public struct CharacterVisibleState: Codable, Equatable, Sendable {
    public var health: String
    public var stamina: String
    public var conditions: [String]
    public var actionHints: [String]

    public static func project(
        health: Double, stamina: Double, conditions: [String]
    ) -> CharacterVisibleState {
        let healthLabel = health <= 0 ? "无法行动" : health < 0.25 ? "伤势严重"
            : health < 0.6 ? "明显受伤" : health < 0.85 ? "轻微受伤" : "状态良好"
        let staminaLabel = stamina <= 0.05 ? "无法继续" : stamina < 0.2 ? "明显力竭"
            : stamina < 0.4 ? "有些疲惫" : stamina >= 0.8 ? "精力充沛" : "状态正常"
        let conditionLabels = conditions.compactMap { condition in
            ["injured": "受伤", "exhausted": "力竭", "afraid": "有些害怕",
             "angry": "略显恼怒", "poisoned": "中毒", "stunned": "头晕"][condition]
        }
        var hints: [String] = []
        if stamina < 0.4 { hints += ["sit", "rest", "yawn"] }
        if conditions.contains("afraid") { hints += ["retreat", "recover"] }
        if conditions.contains("angry") { hints += ["complain", "annoyed"] }
        if health <= 0 || stamina <= 0.05 { hints = ["idle", "rest"] }
        return CharacterVisibleState(
            health: healthLabel, stamina: staminaLabel,
            conditions: conditionLabels, actionHints: Array(Set(hints)).sorted())
    }
}

public struct SimulationCharacterSemanticResult: Codable, Equatable, Sendable {
    public var character: String
    public var passed: Bool
    public var personalityTypes: [String]
    public var signatureBehaviors: [String]
    public var signatureActionCandidates: [String]
    public var playCapabilities: [String]
    public var stateSamples: [CharacterVisibleState]
    public var failures: [String]
}

public struct SimulationSuiteRunner {
    public let configuration: SimulationSuiteConfiguration
    public let characterDefinitions: [CharacterDefinition]

    public init(
        configuration: SimulationSuiteConfiguration,
        characterDefinitions: [CharacterDefinition] = []
    ) {
        self.configuration = configuration
        self.characterDefinitions = characterDefinitions
    }

    public func run() -> SimulationSuiteReport {
        let errors = configuration.configurationErrors
        guard errors.isEmpty else {
            return SimulationSuiteReport(
                schemaVersion: configuration.schemaVersion, passed: false,
                configurationErrors: errors, matrix: [], scenarios: [], semanticCharacters: [])
        }
        let matrix = configuration.roles.flatMap { role in
            configuration.actions.map { run(action: $0, role: role) }
        }
        let scenarios = configuration.classicScenarios.map(run(scenario:))
        let semanticCharacters = characterDefinitions.map(run(character:))
        return SimulationSuiteReport(
            schemaVersion: configuration.schemaVersion,
            passed: scenarios.allSatisfy(\.passed) && matrix.allSatisfy { $0.status != .failed }
                && semanticCharacters.allSatisfy(\.passed),
            configurationErrors: [], matrix: matrix, scenarios: scenarios,
            semanticCharacters: semanticCharacters)
    }

    private func run(character: CharacterDefinition) -> SimulationCharacterSemanticResult {
        guard let profile = character.semanticProfile else {
            return SimulationCharacterSemanticResult(
                character: character.id, passed: false, personalityTypes: [],
                signatureBehaviors: [], signatureActionCandidates: [],
                playCapabilities: [], stateSamples: [],
                failures: ["missing semantic profile"])
        }
        var failures: [String] = []
        if profile.personality.count != 8 { failures.append("personality needs 8 semantic facets") }
        if profile.aptitudes.count != 5 { failures.append("aptitudes need 5 semantic facets") }
        if profile.personalityTypes.isEmpty { failures.append("missing personality type") }
        if profile.signatureBehaviors.isEmpty { failures.append("missing signature behavior") }
        let actionIDs = Set(configuration.actions.map(\.id))
        let signatureActions = profile.signatureBehaviors.values.flatMap(\.actionCandidates)
        if signatureActions.isEmpty || !signatureActions.allSatisfy(actionIDs.contains) {
            failures.append("signature behavior has no executable action candidates")
        }
        if Set(profile.playCapabilities.keys) != Set(character.capabilities) {
            failures.append("play capability labels do not match runtime ids")
        }
        return SimulationCharacterSemanticResult(
            character: character.id, passed: failures.isEmpty,
            personalityTypes: profile.personalityTypes,
            signatureBehaviors: profile.signatureBehaviors.values.map(\.label).sorted(),
            signatureActionCandidates: Array(Set(signatureActions)).sorted(),
            playCapabilities: profile.playCapabilities.values.sorted(),
            stateSamples: [
                .project(health: 1, stamina: 0.9, conditions: []),
                .project(health: 0.72, stamina: 0.32, conditions: ["angry"]),
                .project(health: 0.18, stamina: 0.04, conditions: ["injured", "exhausted"]),
            ], failures: failures)
    }

    private func run(
        action: SimulationActionDefinition,
        role: SimulationRoleDefinition
    ) -> SimulationActionMatrixResult {
        guard supports(action, role: role) else {
            return SimulationActionMatrixResult(
                role: role.id, action: action.id, family: action.family,
                status: .unsupported, resolvedAction: nil, completed: false)
        }
        let execution = execute(action: action.id, role: role)
        return SimulationActionMatrixResult(
            role: role.id, action: action.id, family: action.family,
            status: execution.status, resolvedAction: execution.resolvedAction,
            completed: execution.completed)
    }

    private func run(scenario: SimulationClassicScenario) -> SimulationClassicScenarioResult {
        var results: [SimulationClassicStepResult] = []
        var failures: [String] = []
        let roleIDs = Set(scenario.steps.map(\.role))
        let actors = configuration.roles
            .filter { roleIDs.contains($0.id) }
            .map { EntityState(id: EntityID($0.id), kind: .actor) }
        let game = GameRuntime(kernel: GameKernel(
            scenario: HarnessScenario(id: scenario.id, entities: actors)))
        for (index, step) in scenario.steps.enumerated() {
            guard let role = configuration.roles.first(where: { $0.id == step.role }),
                  let action = configuration.actions.first(where: { $0.id == step.action }) else {
                continue
            }
            let execution: ExecutionResult
            if supports(action, role: role) {
                execution = execute(action: action.id, role: role, runtime: game)
            } else {
                execution = ExecutionResult(status: .unsupported, resolvedAction: nil, completed: false)
            }
            results.append(SimulationClassicStepResult(
                sequence: index,
                role: role.id, action: action.id, expected: step.expected,
                actual: execution.status, completed: execution.completed))
            if execution.status != step.expected {
                failures.append("step \(index) expected \(step.expected.rawValue) got \(execution.status.rawValue)")
            }
            if [.exact, .fallback].contains(step.expected), !execution.completed {
                failures.append("step \(index) did not complete")
            }
        }
        return SimulationClassicScenarioResult(
            id: scenario.id, passed: failures.isEmpty,
            steps: results, failures: failures)
    }

    private func supports(_ action: SimulationActionDefinition, role: SimulationRoleDefinition) -> Bool {
        guard role.support.contains(action.id) else { return false }
        guard let required = action.requiredCapability else { return true }
        return role.capabilities.contains(required)
    }

    private struct ExecutionResult {
        var status: SimulationActionMatrixStatus
        var resolvedAction: String?
        var completed: Bool
    }

    private func execute(action: String, role: SimulationRoleDefinition) -> ExecutionResult {
        let actor = EntityState(id: EntityID(role.id), kind: .actor)
        let scenario = HarnessScenario(id: "matrix/\(role.id)/\(action)", entities: [actor])
        let runtime = GameRuntime(kernel: GameKernel(scenario: scenario))
        return execute(action: action, role: role, runtime: runtime)
    }

    private func execute(
        action: String, role: SimulationRoleDefinition, runtime game: GameRuntime
    ) -> ExecutionResult {
        let actorID = EntityID(role.id)
        let exact = role.assets.exactMode == .all
            ? Set(configuration.actions.map(\.id))
            : Set(role.assets.exactActions ?? [])
        let runtime = ActionRuntime(assetCatalog: AssetCatalog(
            exactActions: exact, fallbackActions: role.assets.fallbackActions ?? [:]))
        let execution = runtime.execute(
            .perform(action), tick: game.clock.tick, actorID: actorID,
            world: game.world, context: RuntimeContext())
        let status: SimulationActionMatrixStatus
        switch execution.resolution?.kind {
        case .exact: status = .exact
        case .fallback: status = .fallback
        case .missing: status = .missing
        case nil: status = .failed
        }
        guard let request = execution.request else {
            return ExecutionResult(
                status: status, resolvedAction: execution.resolution?.resolvedAction,
                completed: false)
        }
        _ = game.submitAction(execution)
        for _ in 0..<3 where game.world.behaviors[request.id]?.status != .completed {
            _ = game.step()
        }
        return ExecutionResult(
            status: status, resolvedAction: execution.resolution?.resolvedAction,
            completed: game.world.behaviors[request.id]?.status == .completed)
    }
}
