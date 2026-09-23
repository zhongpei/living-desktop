import MyPetContent
import MyPetCore

enum RuntimeSpeechPolicy {
    static let builtIn = LocalSpeechPolicyLibrary.loadAvailable() ?? .fallback

    static func resolved(usesCustom: Bool, overrides: LocalSpeechPromptOverrides) -> LocalSpeechPolicy {
        usesCustom ? overrides.applying(to: builtIn) : builtIn
    }
}
