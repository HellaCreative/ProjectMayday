import SwiftUI

struct LocationSearchView: View {
    @Bindable var model: LocationSearchModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            if !compact { HStack {
                Text("Search places").font(.title2.bold())
                Spacer(minLength: 8)
                Button("Cancel") { model.isPresented = false }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            } }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("Place or address", text: $model.query)
                    .accessibilityIdentifier("placeSearchField")
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .focused($fieldFocused)
                    .onSubmit { model.retry() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Clear search")
                }
                if compact {
                    Button("Cancel") { model.isPresented = false }
                        .font(.body.weight(.semibold))
                        .frame(minHeight: 44)
                        .padding(.trailing, 12)
                }
            }
            .padding(.leading, 14)
            .frame(minHeight: 50)
            .dirtGroupingSurface(radius: 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.isSearching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching…")
                        }
                        .frame(maxWidth: .infinity, minHeight: 70)
                    } else if let error = model.searchError {
                        Text(error).foregroundStyle(DirtTheme.muted)
                        Button("Try again") { model.retry() }
                            .buttonStyle(DirtSecondaryButtonStyle())
                    } else if model.results.isEmpty {
                        Text(model.hasSearchQuery ? "No places found. Try a nearby town or a fuller address." : "Find a place or address, then route there or add it to your plan.")
                            .foregroundStyle(DirtTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Place search needs an internet connection.")
                            .font(.footnote).foregroundStyle(DirtTheme.muted)
                    } else {
                        ForEach(model.results) { result in
                            Button { model.select(result) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title2).foregroundStyle(DirtTheme.action)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.name).font(.headline)
                                        if !result.address.isEmpty {
                                            Text(result.address).font(.subheadline).foregroundStyle(DirtTheme.muted)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").accessibilityHidden(true)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                                .dirtGroupingSurface(radius: 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.top)
        }
        .foregroundStyle(DirtTheme.ink)
        .tint(DirtTheme.action)
        .padding(compact ? 12 : 20)
        .background { DirtGlassSheetSurface(shape: RoundedRectangle(cornerRadius: 24)) }
        .onAppear { fieldFocused = true }
    }
}

struct SearchConfirmationCard: View {
    let result: LocationSearchResult
    let onRoute: () -> Void
    let onWaypoint: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name).font(.title3.bold())
                    if !result.address.isEmpty {
                        Text(result.address).font(.subheadline).foregroundStyle(DirtTheme.muted)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).dirtGlassControl(tint: .white)
                }
                .accessibilityLabel("Dismiss place")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(spacing: 12) { actions }
            }
        }
        .foregroundStyle(DirtTheme.ink)
        .padding(20)
        .background { DirtGlassSheetSurface(shape: RoundedRectangle(cornerRadius: 24)) }
    }

    @ViewBuilder private var actions: some View {
        Button("Route here", systemImage: "location.north.fill", action: onRoute)
            .buttonStyle(DirtCTAStyle.brand())
        Button("Add waypoint", systemImage: "plus", action: onWaypoint)
            .buttonStyle(DirtSecondaryButtonStyle())
    }
}
