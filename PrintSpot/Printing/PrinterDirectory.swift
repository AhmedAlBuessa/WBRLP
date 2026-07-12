//
//  PrinterDirectory.swift
//  PrintSpot
//
//  Fetches the global Princh printer directory used by "Find a printer".
//  Source: geo-bridge.princh.com/get-locations (public, no auth, ~5k printers).
//

import Foundation
import CoreLocation

/// A printer entry from the public directory.
nonisolated struct PrinterLocation: Decodable, Identifiable {
    let printerId: String
    let spec: Specification?
    let place: Place
    let info: Info

    var id: String { printerId }
    var name: String {
        let n = info.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "Printer \(printerId)" : n
    }
    var address: String { place.address ?? "" }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }
    var isHidden: Bool { place.hidden ?? false }

    /// Lowest advertised per-page price, for a quick "from $x" hint.
    var minPricePerPageCents: Int? { spec?.color?.map(\.pricePerPage).min() }
    var currency: String { spec?.priceModel?.currency ?? "USD" }
    var supportsColor: Bool { spec?.color?.contains { $0.type == "STANDARD_COLOR" } ?? false }

    enum CodingKeys: String, CodingKey {
        case printerId
        case spec = "specification"
        case place = "location"
        case info = "description"
    }

    struct Place: Decodable {
        let country: [String]?
        let address: String?
        let region: String?
        let latitude: Double
        let longitude: Double
        let hidden: Bool?
    }
    struct Info: Decodable {
        let name: String?
        let locationDescription: String?
    }
    struct Specification: Decodable {
        let duplex: Bool?
        let color: [ColorPrice]?
        let priceModel: PriceModel?
    }
    struct ColorPrice: Decodable { let pricePerPage: Int; let type: String }
    struct PriceModel: Decodable { let currency: String? }
}

/// Wrapper that decodes to nil instead of throwing, so one malformed record
/// doesn't fail the whole 5k-item array.
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Loads and caches the printer directory.
actor PrinterDirectory {
    static let shared = PrinterDirectory()

    private let url = URL(string: "https://geo-bridge.princh.com/get-locations")!
    private var cache: [PrinterLocation]?

    /// All visible printers, cached after the first successful load.
    func all() async throws -> [PrinterLocation] {
        if let cache { return cache }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PrinchError.http(status: http.statusCode, body: "")
        }
        let list = try JSONDecoder().decode([Failable<PrinterLocation>].self, from: data)
            .compactMap(\.value)
            .filter { !$0.isHidden }
        cache = list
        return list
    }
}
