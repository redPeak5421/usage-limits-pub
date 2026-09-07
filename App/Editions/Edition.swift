import SwiftUI
import UsageLimitsCore

enum EditionFactory {
    @MainActor
    static func make() -> Edition {
        BaseEdition()
    }
}
