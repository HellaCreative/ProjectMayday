import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// GPX track exchange format.
    static var gpx: UTType {
        UTType(filenameExtension: "gpx") ?? UTType(importedAs: "com.topografix.gpx")
    }
}

/// Parses GPX 1.x track and route files.
enum GPXParser {
    struct ParsedTrack: Sendable {
        let name: String
        /// One polyline per `<trkseg>` or `<rte>`; each has ≥ 2 points.
        let segments: [[RouteCoordinate]]
        let distanceMeters: Double
        let pointCount: Int

        var coordinates: [RouteCoordinate] {
            segments.flatMap { $0 }
        }
    }

    enum ParseError: LocalizedError {
        case empty
        case invalidXML
        case notGPX
        case noTrackOrRoute

        var errorDescription: String? {
            switch self {
            case .empty: "The selected file is empty."
            case .invalidXML: "The selected file is not valid GPX."
            case .notGPX: "The selected file is not a GPX file."
            case .noTrackOrRoute: "No track or route with at least two points was found."
            }
        }
    }

    static func parse(data: Data, fallbackName: String = "Imported GPX track") throws -> ParsedTrack {
        guard !data.isEmpty else { throw ParseError.empty }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.invalidXML
        }
        guard delegate.rootLocalName?.lowercased() == "gpx" else {
            throw ParseError.notGPX
        }

        var segments = delegate.tracks.flatMap(\.segments)
        var name = delegate.metadataName ?? fallbackName
        if let firstTrack = delegate.tracks.first, !firstTrack.name.isEmpty {
            name = firstTrack.name
        }

        if segments.isEmpty {
            let routeSegments = delegate.routes.compactMap { route -> [RouteCoordinate]? in
                let points = route.points
                return points.count >= 2 ? points : nil
            }
            if let firstRoute = delegate.routes.first, !firstRoute.name.isEmpty {
                name = firstRoute.name
            }
            segments = routeSegments
        }

        guard !segments.isEmpty else { throw ParseError.noTrackOrRoute }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackName = trimmed.isEmpty ? "Imported GPX track" : trimmed
        let distance = segments.reduce(0.0) { $0 + GeoMath.lineMeters($1) }
        let pointCount = segments.reduce(0) { $0 + $1.count }

        return ParsedTrack(
            name: trackName,
            segments: segments,
            distanceMeters: distance.rounded(),
            pointCount: pointCount
        )
    }

    static func parse(contentsOf url: URL, fallbackName: String? = nil) throws -> ParsedTrack {
        let data = try Data(contentsOf: url)
        let name = fallbackName ?? url.deletingPathExtension().lastPathComponent
        return try parse(data: data, fallbackName: name)
    }

    // MARK: - XML delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        struct TrackBlock {
            var name = ""
            var segments: [[RouteCoordinate]] = []
        }

        struct RouteBlock {
            var name = ""
            var points: [RouteCoordinate] = []
        }

        var rootLocalName: String?
        var metadataName: String?

        private(set) var tracks: [TrackBlock] = []
        private(set) var routes: [RouteBlock] = []

        private var elementStack: [String] = []
        private var currentTrack: TrackBlock?
        private var currentSegment: [RouteCoordinate] = []
        private var currentRoute: RouteBlock?
        private var textBuffer = ""

        private func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let tag = localName(elementName).lowercased()
            elementStack.append(tag)
            textBuffer = ""

            switch tag {
            case "gpx":
                rootLocalName = tag
            case "trk":
                currentTrack = TrackBlock()
            case "trkseg":
                currentSegment = []
            case "trkpt":
                if let coordinate = coordinate(from: attributeDict) {
                    currentSegment.append(coordinate)
                }
            case "rte":
                currentRoute = RouteBlock()
            case "rtept":
                if let coordinate = coordinate(from: attributeDict) {
                    currentRoute?.points.append(coordinate)
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let tag = localName(elementName).lowercased()
            defer {
                if !elementStack.isEmpty { elementStack.removeLast() }
                textBuffer = ""
            }

            switch tag {
            case "name":
                let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                if elementStack.dropLast().last == "metadata" {
                    metadataName = value
                } else if elementStack.dropLast().last == "trk" {
                    currentTrack?.name = value
                } else if elementStack.dropLast().last == "rte" {
                    currentRoute?.name = value
                }
            case "trkseg":
                if currentSegment.count >= 2 {
                    currentTrack?.segments.append(currentSegment)
                }
                currentSegment = []
            case "trk":
                if let track = currentTrack, !track.segments.isEmpty {
                    tracks.append(track)
                }
                currentTrack = nil
            case "rte":
                if let route = currentRoute, route.points.count >= 2 {
                    routes.append(route)
                }
                currentRoute = nil
            default:
                break
            }
        }

        private func coordinate(from attributes: [String: String]) -> RouteCoordinate? {
            guard let latRaw = attributes["lat"] ?? attributes["Lat"],
                  let lonRaw = attributes["lon"] ?? attributes["Lon"],
                  let lat = Double(latRaw),
                  let lon = Double(lonRaw),
                  abs(lat) <= 90,
                  abs(lon) <= 180 else { return nil }
            return RouteCoordinate(longitude: lon, latitude: lat)
        }
    }
}
