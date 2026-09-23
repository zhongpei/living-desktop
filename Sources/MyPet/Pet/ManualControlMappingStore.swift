import Foundation
import MyPetCombat

/// Persists the physical-key-to-logical-control catalog independently from
/// character move profiles. AppKit key codes never enter combat content data.
final class ManualControlMappingStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "combat.manual-control-mappings.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ManualControlMappingCatalog {
        guard let data = defaults.data(forKey: key),
              let catalog = try? JSONDecoder().decode(
                ManualControlMappingCatalog.self, from: data) else {
            return ManualControlMappingCatalog()
        }
        return catalog
    }

    func save(_ catalog: ManualControlMappingCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: key)
    }
}
