import SwiftData
import SwiftUI

@main
struct DirtApp: App {
    @State private var appEnvironment = AppEnvironment()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([SavedRoute.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
                .preferredColorScheme(.light)
        }
        .modelContainer(sharedModelContainer)
    }
}
