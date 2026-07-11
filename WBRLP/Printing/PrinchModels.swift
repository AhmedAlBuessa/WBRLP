//
//  PrinchModels.swift
//  WBRLP
//
//  Codable models for the Princh public-printing REST API (v5),
//  reverse-engineered from the print.princh.com web app.
//

import Foundation

// MARK: - Auth

/// Response from `POST /auth/v2/oauth/token` (snake_case body).
nonisolated struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Device

/// A printer, resolved from its public display id (e.g. "108815").
nonisolated struct Device: Decodable {
    let deviceId: String
    let locationId: String
    let displayId: String
    let connectorId: String
    let domain: String
    let printer: Printer
    let descriptions: Descriptions?

    /// Human-facing location/printer name, best-effort.
    var locationName: String { descriptions?.publicInfo?.name ?? "Printer \(displayId)" }
    var printerName: String { descriptions?.local?.name ?? "Printer" }
    var locationDescription: String? { descriptions?.publicInfo?.locationDescription }
}

nonisolated struct Descriptions: Codable {
    let local: LocalDescription?
    let publicInfo: PublicDescription?

    enum CodingKeys: String, CodingKey {
        case local
        case publicInfo = "public"
    }
}

nonisolated struct LocalDescription: Codable {
    let name: String?
    let model: String?
}

nonisolated struct PublicDescription: Codable {
    let locationDescription: String?
    let name: String?
}

nonisolated struct Printer: Decodable {
    let capabilities: Capabilities
    let defaults: PrinterDefaults?
    let flags: PrinterFlags?
    let prices: PriceTable?
}

/// The printer's price list. Heterogeneous JSON: fixed `currency`/`startPrice`
/// keys mixed with one entry per media size (e.g. "279400x215900").
nonisolated struct PriceTable: Decodable {
    let currency: String
    let startPrice: Int          // order-level base price, minor units (cents)
    let perMedia: [String: MediaPrice]

    struct MediaPrice: Decodable {
        let color: Int?          // STANDARD_COLOR pricePerPage (cents)
        let mono: Int?           // STANDARD_MONOCHROME pricePerPage (cents)

        private struct PerPage: Decodable { let pricePerPage: Int }
        private enum Keys: String, CodingKey {
            case color = "STANDARD_COLOR"
            case mono = "STANDARD_MONOCHROME"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            color = try c.decodeIfPresent(PerPage.self, forKey: .color)?.pricePerPage
            mono = try c.decodeIfPresent(PerPage.self, forKey: .mono)?.pricePerPage
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var currency = "CAD"
        var start = 0
        var media: [String: MediaPrice] = [:]
        for key in c.allKeys {
            switch key.stringValue {
            case "currency": currency = (try? c.decode(String.self, forKey: key)) ?? "CAD"
            case "startPrice": start = (try? c.decode(Int.self, forKey: key)) ?? 0
            default:
                if let price = try? c.decode(MediaPrice.self, forKey: key) {
                    media[key.stringValue] = price
                }
            }
        }
        self.currency = currency
        self.startPrice = start
        self.perMedia = media
    }

    /// Per-page price for a given media key + colour choice, with sensible fallbacks.
    func pricePerPage(mediaKey: String, color: Bool) -> Int? {
        let entry = perMedia[mediaKey] ?? perMedia.values.first
        return color ? entry?.color : entry?.mono
    }
}

nonisolated struct Capabilities: Codable {
    let duplex: Bool
    let maxPagesPerDocument: Int
    let color: [String: ColorCapability]
    let mediaSize: [String: MediaDimensions]

    /// True if the printer can print in colour (a STANDARD_COLOR entry exists).
    var supportsColor: Bool { color.keys.contains("STANDARD_COLOR") }

    /// Available media sizes as sorted, display-friendly options.
    var mediaOptions: [MediaOption] {
        mediaSize.map { MediaOption(key: $0.key, dimensions: $0.value) }
            .sorted { $0.dimensions.area < $1.dimensions.area }
    }
}

nonisolated struct ColorCapability: Codable {
    /// "0" == colour, "1" == monochrome (Princh convention).
    let type: String
}

nonisolated struct MediaDimensions: Codable, Hashable {
    let width_microns: Int
    let height_microns: Int
    var area: Int { width_microns * height_microns }
}

nonisolated struct PrinterDefaults: Codable {
    let format: String?
    let color: String?
    let duplex: String?
}

nonisolated struct PrinterFlags: Codable {
    let printerEnabled: Bool?
    let duplexEnabled: Bool?
    let maskTitles: Bool?
}

/// A user-selectable paper size.
nonisolated struct MediaOption: Identifiable, Hashable {
    let key: String
    let dimensions: MediaDimensions
    var id: String { key }

    /// Portrait width/height in microns for the print ticket.
    var portraitWidth: Int { min(dimensions.width_microns, dimensions.height_microns) }
    var portraitHeight: Int { max(dimensions.width_microns, dimensions.height_microns) }

    /// Best-effort friendly name (Letter, A4, Legal, Tabloid, A3, …).
    var displayName: String {
        let mm = { (microns: Int) in Int((Double(microns) / 1000.0).rounded()) }
        let w = mm(portraitWidth), h = mm(portraitHeight)
        switch (w, h) {
        case (216, 279): return "Letter (8.5×11\")"
        case (216, 356): return "Legal (8.5×14\")"
        case (279, 432): return "Tabloid (11×17\")"
        case (210, 297): return "A4"
        case (297, 420): return "A3"
        default: return "\(w)×\(h) mm"
        }
    }
}

// MARK: - Connector

/// `GET /rest/v5/connectors/{id}` — holds the encryption key id needed for uploads.
nonisolated struct Connector: Decodable {
    let connectorId: String
    let publicKeyId: String?
    let encryptionEnabled: Bool?
    let state: String?
}

// MARK: - File upload options

/// The `options` form field sent with each file upload.
nonisolated struct UploadOptions: Encodable {
    let marginMicrons: Int
    let pageFitting: String
    let pageSize: PageSizeMicrons

    init(widthMicrons: Int, heightMicrons: Int, fitToPage: Bool = true) {
        self.marginMicrons = 5000
        self.pageFitting = fitToPage ? "FIT_TO_PAGE" : "NONE"
        self.pageSize = PageSizeMicrons(widthMicrons: widthMicrons, heightMicrons: heightMicrons)
    }
}

nonisolated struct PageSizeMicrons: Encodable {
    let widthMicrons: Int
    let heightMicrons: Int
}

// MARK: - Print options (user-facing)

/// Per-document print settings chosen in the UI.
nonisolated struct PrintOptions: Equatable {
    var color: Bool = false
    var copies: Int = 1
    var duplex: Bool = false
    var mediaSizeKey: String = ""
}

// MARK: - Print ticket

/// The print settings sent with each document. Keys are snake_case per the API.
nonisolated struct Ticket: Codable {
    let version: String
    let print: PrintTicket

    init(options: PrintOptions, media: MediaOption, pageCount: Int) {
        self.version = "1.0"
        self.print = PrintTicket(
            color: TypeValue(type: options.color ? 0 : 1),
            copies: Copies(copies: options.copies),
            media_size: MediaSize(width_microns: media.portraitWidth,
                                  height_microns: media.portraitHeight),
            fit_to_page: TypeValue(type: 1),
            page_range: PageRange(interval: [Interval(start: 1, end: max(1, pageCount))]),
            duplex: TypeValue(type: options.duplex ? 1 : 0)
        )
    }
}

nonisolated struct PrintTicket: Codable {
    let color: TypeValue
    let copies: Copies
    let media_size: MediaSize
    let fit_to_page: TypeValue
    let page_range: PageRange
    let duplex: TypeValue
}

nonisolated struct TypeValue: Codable { let type: Int }
nonisolated struct Copies: Codable { let copies: Int }
nonisolated struct MediaSize: Codable { let width_microns: Int; let height_microns: Int }
nonisolated struct PageRange: Codable { let interval: [Interval] }
nonisolated struct Interval: Codable { let start: Int; let end: Int }

// MARK: - Documents

/// `POST /rest/v5/documents` request body.
nonisolated struct DocumentRequest: Codable {
    let deviceId: String
    let domain: String
    let title: String
    let pdfFileId: String
    let ticket: Ticket
}

/// `POST /rest/v5/documents` response.
nonisolated struct PrinchDocument: Codable {
    let documentId: String
    let pdfFileId: String
    let title: String
    let price: DocumentPrice
}

nonisolated struct DocumentPrice: Codable {
    let pages: Int
    let price: Int          // minor units (cents)
    let pricePerPage: Int
    let currency: String
}

// MARK: - Payment types

nonisolated struct PaymentTypesResponse: Codable {
    let paytypes: [Paytype]
}

nonisolated struct Paytype: Codable, Identifiable {
    let paytypeId: String
    let typeId: String
    let fee: Int?
    let enabled: Bool?
    let ui: PaytypeUI?

    var id: String { paytypeId }
    var isEnvisionware: Bool { typeId == "ENVISIONWARE" }
}

nonisolated struct PaytypeUI: Codable {
    let name: String?
    let type: String?
    let icon: String?
}

// MARK: - Order session

/// `POST /rest/v5/order-sessions` request body.
nonisolated struct OrderSessionRequest: Codable {
    let documentIds: [String]
    let paytypeId: String
    let secureRelease: Bool
    let appInfo: AppInfo
    let locale: String
    let acceptUrl: String
    let paytypeClientData: PaytypeClientData?
}

nonisolated struct PaytypeClientData: Codable {
    /// Library account / user id used to release the job at the printer.
    let envisionwareUserId: String?
}

nonisolated struct AppInfo: Codable {
    let client: NameVersion
    let os: NameVersion
    let shell: NameVersion

    static let current = AppInfo(
        client: NameVersion(name: "PRINT_WEB_APP", version: "4.13.0"),
        os: NameVersion(name: "IOS", version: "26.5"),
        shell: NameVersion(name: "PrintSpot", version: "1.0")
    )
}

nonisolated struct NameVersion: Codable {
    let name: String
    let version: String
}

/// `POST /rest/v5/order-sessions` response.
nonisolated struct OrderSession: Codable {
    let orderSessionId: String
    let orderDisplayId: String
    let paymentId: String?
    let price: OrderPrice
    let location: OrderLocation?
}

nonisolated struct OrderLocation: Codable {
    let locationId: String?
    let name: String?
}

nonisolated struct OrderPrice: Codable {
    let currency: String
    let documents: [Int]
    let orderFee: Int
    let paytypeFee: Int
    let totalPrice: Int      // minor units (cents)
}

/// `GET /rest/v5/order-sessions/{id}/wait` response (long-poll).
nonisolated struct OrderWaitResponse: Codable {
    let orderId: String?
    let orderDisplayId: String?
    let orderSessionId: String?
}

// MARK: - File upload

/// Result of `POST files.princh.com/v3/files/pdf/` — the id comes from
/// response headers, the converted PDF from the body.
nonisolated struct UploadResult {
    let pdfFileId: String
    let fileKey: String?
    let pageCount: Int
    let pdfData: Data
}
