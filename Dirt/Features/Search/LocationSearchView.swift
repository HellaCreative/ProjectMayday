import MapKit
import SwiftUI

/// Full-screen search overlay: frosted panel with type-ahead results.
/// Presented over the map when the rider taps the binoculars button.
struct LocationSearchView: View {
    @Bindable var model: LocationSearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            scrim
            panel
        }
        .ignoresSafeArea(.keyboard)
        .onAppear { fieldFocused = true }
    }

    // MARK: - Scrim

    private var scrim: some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture { dismiss() }
            .transition(.opacity.animation(.easeOut(duration: 0.22)))
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            resultsList
        }
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 100)
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(
            .asymmetric(
                insertion: .offset(y: -16)
                    .combined(with: .opacity)
                    .animation(.spring(duration: 0.32, bounce: 0.12)),
                removal: .offset(y: -8)
                    .combined(with: .opacity)
                    .animation(.easeIn(duration: 0.16))
            )
        )
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "binoculars")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DirtTheme.orange.opacity(0.7))

            TextField("Where are you headed?", text: $model.query)
                .textFieldStyle(.plain)
                .font(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .focused($fieldFocused)
                .submitLabel(.search)

            Button("Cancel") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DirtTheme.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    // MARK: - Results

    private var resultsList: some View {
        Group {
            if model.results.isEmpty && !model.isSearching {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            resultRow(result, index: index)
                            if index < model.results.count - 1 {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxHeight: 340)
            }
        }
    }

    private func resultRow(_ result: LocationSearchService.Result, index: Int) -> some View {
        Button {
            model.select(result)
        } label: {
            HStack(spacing: 14) {
                categoryIcon(for: result)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DirtTheme.ink)
                        .lineLimit(1)

                    Text(result.address)
                        .font(.caption)
                        .foregroundStyle(DirtTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let dist = result.distanceMeters {
                    Text(Self.formatDistance(dist))
                        .font(.caption)
                        .foregroundStyle(DirtTheme.muted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(SearchResultStyle())
        .transition(
            .asymmetric(
                insertion: .offset(y: 10)
                    .combined(with: .opacity)
                    .animation(.spring(duration: 0.26).delay(Double(index) * 0.04)),
                removal: .opacity.animation(.easeOut(duration: 0.12))
            )
        )
    }

    private func categoryIcon(for result: LocationSearchService.Result) -> some View {
        let symbol = Self.symbolForResult(result)
        return Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(DirtTheme.muted)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous)
                    .fill(Color(.systemGray6))
            )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "binoculars")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color(.systemGray3))

            Text(model.query.isEmpty
                ? "Search for a place, address,\nor point of interest"
                : (model.searchError ?? "No results found"))
                .font(.subheadline)
                .foregroundStyle(DirtTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Helpers

    private func dismiss() {
        fieldFocused = false
        model.isPresented = false
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters)) m"
        } else {
            let km = meters / 1000
            return km < 10
                ? String(format: "%.1f km", km)
                : "\(Int(km)) km"
        }
    }

    static func symbolForResult(_ result: LocationSearchService.Result) -> String {
        let lower = (result.name + " " + result.address).lowercased()
        if lower.contains("gas") || lower.contains("fuel") || lower.contains("petro")
            || lower.contains("shell") || lower.contains("esso") || lower.contains("irving") {
            return "fuelpump.fill"
        }
        if lower.contains("park") || lower.contains("trail") || lower.contains("lake") {
            return "leaf.fill"
        }
        if lower.contains("hotel") || lower.contains("inn") || lower.contains("lodge")
            || lower.contains("motel") || lower.contains("campground") {
            return "bed.double.fill"
        }
        return "mappin"
    }
}

// MARK: - Result press style

private struct SearchResultStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color(.systemGray5).opacity(0.6)
                    : Color.clear
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
