import SwiftUI

enum DockTab: String, CaseIterable, Identifiable {
    case layers
    case profile
    case group
    case route

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layers: "Layers"
        case .profile: "Profile"
        case .group: "Group"
        case .route: "Route"
        }
    }

    var icon: String {
        switch self {
        case .layers: "square.3.layers.3d.down.right"
        case .profile: "person.crop.circle"
        case .group: "person.2.fill"
        case .route: "arrow.triangle.turn.up.right.diamond.fill"
        }
    }
}

enum ActiveSheet: String, Identifiable {
    case layers
    case profile
    case group

    var id: String { rawValue }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var activeSheet: ActiveSheet?
    @State private var routeCardOpen = false

    private var navActive: Bool { app.navigation.phase != .idle }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapLibreMapView(state: app.mapState, location: app.location)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topChrome
                Spacer()
                if navActive {
                    NavigationHUD()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else if routeCardOpen {
                    RoutePlannerCard(isOpen: $routeCardOpen)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
                dock
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .layers:
                LayersSheet()
                    .presentationDetents([.medium, .large])
            case .profile:
                ProfileSheet()
                    .presentationDetents([.medium, .large])
            case .group:
                GroupsSheet(onClose: { activeSheet = nil })
                    .presentationDetents([.large])
            }
        }
        .overlay(alignment: .top) {
            if let toast = app.planner.toast {
                ToastView(text: toast)
                    .padding(.top, 60)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        app.planner.toast = nil
                    }
            }
        }
        .task {
            app.location.requestWhenInUse()
            await app.supabase.bootstrap()
        }
    }

    private var topChrome: some View {
        HStack(alignment: .top) {
            BrandChip()
            Spacer()
            Button {
                if let coordinate = app.location.currentCoordinate {
                    app.mapState.fly(to: coordinate, zoom: 13.5)
                } else {
                    app.location.requestWhenInUse()
                }
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(DirtTheme.chrome)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(DirtTheme.chromeBorder, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var dock: some View {
        HStack(spacing: 6) {
            ForEach(DockTab.allCases) { tab in
                dockButton(tab)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(DirtTheme.chrome.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(DirtTheme.chromeBorder).frame(height: 1)
        }
    }

    private func isActive(_ tab: DockTab) -> Bool {
        switch tab {
        case .layers: activeSheet == .layers
        case .profile: activeSheet == .profile
        case .group: activeSheet == .group
        case .route: routeCardOpen
        }
    }

    private func dockButton(_ tab: DockTab) -> some View {
        Button {
            // Web parity: only one sheet/tool open at a time.
            switch tab {
            case .route:
                activeSheet = nil
                routeCardOpen.toggle()
            case .layers:
                routeCardOpen = false
                activeSheet = activeSheet == .layers ? nil : .layers
            case .profile:
                routeCardOpen = false
                activeSheet = activeSheet == .profile ? nil : .profile
            case .group:
                routeCardOpen = false
                activeSheet = activeSheet == .group ? nil : .group
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(tab.title.uppercased())
                    .font(.dirtUI(9.5, weight: .heavy))
                    .tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isActive(tab) ? DirtTheme.orange : .clear)
            .foregroundStyle(isActive(tab) ? .white : .white.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive(tab) ? .white : .clear, lineWidth: 1)
            )
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.dirtUI(12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DirtTheme.chrome.opacity(0.95))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DirtTheme.chromeBorder, lineWidth: 1))
            .transition(.opacity)
    }
}
