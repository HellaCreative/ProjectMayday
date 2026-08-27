import SwiftUI

/// One compact route-surface visualization. The visible vocabulary stays
/// Dirt/Paved while the bar honestly preserves the four available families.
struct SurfaceMixBar: View {
    let composition: RouteSurfaceComposition
    var height: CGFloat = 8
    var showsLabels = true

    private let order: [SurfaceFamily] = [.gravel, .loose, .unknown, .paved]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(order, id: \.self) { family in
                        let width = segmentWidth(family, totalWidth: proxy.size.width)
                        if width > 0 {
                            SurfaceFamilyFill(family: family)
                                .frame(width: width)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(DirtTheme.routeUnknown.opacity(0.25))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DirtTheme.hairline, lineWidth: 0.5))
            }
            .frame(height: height)

            if showsLabels {
                HStack {
                    Text("Dirt")
                        .font(.dirtUI(12, weight: .bold))
                        .foregroundStyle(DirtTheme.dirtMix)
                    Spacer(minLength: 0)
                    Text("Paved")
                        .font(.dirtUI(12, weight: .bold))
                        .foregroundStyle(DirtTheme.pavedMix)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Surface mix")
        .accessibilityValue(accessibilityValue)
    }

    private func segmentWidth(_ family: SurfaceFamily, totalWidth: CGFloat) -> CGFloat {
        guard composition.totalMeters > 0 else { return family == .unknown ? totalWidth : 0 }
        return totalWidth * CGFloat(composition.meters(for: family) / composition.totalMeters)
    }

    private var accessibilityValue: String {
        "\(composition.dirtPercent) percent dirt, including "
            + "\(composition.gravelPercent) gravel, "
            + "\(composition.loosePercent) loose, and "
            + "\(composition.unknownPercent) unknown; "
            + "\(composition.pavedPercent) percent paved"
    }
}

private struct SurfaceFamilyFill: View {
    let family: SurfaceFamily

    var body: some View {
        if family == .unknown {
            GeometryReader { proxy in
                ZStack {
                    DirtTheme.routeUnknown
                    Path { path in
                        for x in stride(
                            from: -proxy.size.height,
                            through: proxy.size.width,
                            by: 5
                        ) {
                            path.move(to: CGPoint(x: x, y: proxy.size.height))
                            path.addLine(to: CGPoint(x: x + proxy.size.height, y: 0))
                        }
                    }
                    .stroke(Color.white.opacity(0.58), lineWidth: 1)
                }
            }
        } else {
            color
        }
    }

    private var color: Color {
        switch family {
        case .paved: DirtTheme.routePaved
        case .gravel: DirtTheme.routeGravel
        case .loose: DirtTheme.routeLoose
        case .unknown: DirtTheme.routeUnknown
        }
    }
}
