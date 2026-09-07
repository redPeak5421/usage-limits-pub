import SwiftUI
import UsageLimitsCore

@main
struct UsageLimitsWatchApp: App {
    @StateObject private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
                .environment(\.appLanguage, store.language)
                .environment(\.usageDisplayMode, store.usageDisplayMode)
                .environment(\.resetTimeStyle, store.resetTimeStyle)
        }
    }
}
