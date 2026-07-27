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
            AppGateView()
                .environment(appEnvironment)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == "gpx" else { return }
                    let context = sharedModelContainer.mainContext
                    appEnvironment.planner.importGPX(from: url, context: context)
                    appEnvironment.planner.presentRouteCard = true
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
