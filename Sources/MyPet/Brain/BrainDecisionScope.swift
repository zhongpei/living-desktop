/// Identity of the world and plan for which an asynchronous brain answer was
/// requested. Time and event age are deliberately excluded: neither changes
/// the meaning of the user's current activity or the legal action set.
struct BrainDecisionScope: Equatable {
    private struct Context: Equatable {
        let activeApp: String
        let windowTitle: String
        let appActivity: String
        let userActivity: String
        let focusRole: String
        let visibleContext: [String]
        let salientUI: [String]
        let nearbyWindows: [String]

        init(_ world: BrainContextSnapshot) {
            activeApp = world.activeApp
            windowTitle = world.windowTitle
            appActivity = world.appActivity
            userActivity = world.userActivity
            focusRole = world.focusRole
            visibleContext = world.visibleContext
            salientUI = world.salientUI
            nearbyWindows = world.nearbyWindows
        }
    }

    private let context: Context?
    private let planEpoch: Int64
    private let goalTraceID: String?
    private let sceneID: String?

    init(world: BrainContextSnapshot?, planEpoch: Int64,
         goalTraceID: String?, sceneID: String?) {
        context = world.map(Context.init)
        self.planEpoch = planEpoch
        self.goalTraceID = goalTraceID
        self.sceneID = sceneID
    }

    func matches(world: BrainContextSnapshot?, planEpoch: Int64,
                 goalTraceID: String?, sceneID: String?) -> Bool {
        self == BrainDecisionScope(world: world, planEpoch: planEpoch,
                                   goalTraceID: goalTraceID, sceneID: sceneID)
    }
}
