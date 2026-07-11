//
//  PrinchAPI.swift
//  WBRLP
//
//  Async client for the Princh public-printing API.
//

import Foundation

enum PrinchError: LocalizedError {
    case http(status: Int, body: String)
    case missingUploadHeaders
    case invalidPrinterCode
    case notAuthenticated
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "Server error \(status): \(body.prefix(200))"
        case .missingUploadHeaders:
            return "The file upload did not return a file id."
        case .invalidPrinterCode:
            return "That doesn't look like a valid printer code."
        case .notAuthenticated:
            return "Not signed in to the print service yet."
        case .decoding(let msg):
            return "Unexpected response from the print service. (\(msg))"
        }
    }
}

/// Endpoints and constants for the Princh service.
nonisolated enum PrinchConfig {
    static let restBase = URL(string: "https://rest.princh.com")!
    static let filesUpload = URL(string: "https://files.princh.com/v3/files/pdf/")!
    static let grantType = "urn:com:princh:grants:public-printing"
    static let apiPath = "/rest/v5"
    static let locale = "en-US"
    static let acceptURL = "https://print.princh.com/order?lang=en-US"
}

actor PrinchAPI {
    private let session: URLSession
    private var accessToken: String?
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isAuthenticated: Bool { accessToken != nil }

    // MARK: - Auth

    /// Obtain an anonymous public-printing token. Valid ~24h.
    func authenticate() async throws {
        var request = URLRequest(url: PrinchConfig.restBase.appendingPathComponent("/auth/v2/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        let grant = PrinchConfig.grantType.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? PrinchConfig.grantType
        request.httpBody = "grant_type=\(grant)".data(using: .utf8)

        let data = try await perform(request, authorized: false)
        let token = try decode(TokenResponse.self, from: data)
        accessToken = token.accessToken
    }

    /// Ensure we have a token before an authorized call.
    private func ensureToken() async throws {
        if accessToken == nil { try await authenticate() }
    }

    // MARK: - Device & payment

    /// Resolve a printer by its public display id (e.g. "108815").
    func fetchDevice(displayId: String) async throws -> Device {
        let code = displayId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw PrinchError.invalidPrinterCode }
        try await ensureToken()
        let data = try await perform(get("/devices/\(code)"))
        return try decode(Device.self, from: data)
    }

    func fetchPaymentTypes(deviceId: String) async throws -> [Paytype] {
        try await ensureToken()
        let data = try await perform(get("/payments/types",
                                        query: [URLQueryItem(name: "deviceId", value: deviceId)]))
        return try decode(PaymentTypesResponse.self, from: data).paytypes
    }

    /// The device's connector — carries the `publicKeyId` uploads require.
    func fetchConnector(id: String) async throws -> Connector {
        try await ensureToken()
        let data = try await perform(get("/connectors/\(id)"))
        return try decode(Connector.self, from: data)
    }

    // MARK: - Upload

    /// Upload a file (image or PDF); the server converts to PDF and returns
    /// the converted bytes plus the file id in headers.
    func uploadFile(data fileData: Data,
                    filename: String,
                    mimeType: String,
                    publicKeyId: String?,
                    options: UploadOptions,
                    ttlMillis: Int = 86_400_000) async throws -> UploadResult {
        try await ensureToken()

        let boundary = "----WBRLPBoundary\(UUID().uuidString)"
        var request = URLRequest(url: PrinchConfig.filesUpload)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }

        // File part
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n")

        // Metadata parts required by the service
        if let publicKeyId { field("publicKeyId", publicKeyId) }
        let optionsJSON = String(data: try JSONEncoder().encode(options), encoding: .utf8) ?? "{}"
        field("options", optionsJSON)
        field("ttl", String(ttlMillis))

        append("--\(boundary)--\r\n")
        request.httpBody = body

        let (respData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PrinchError.decoding("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PrinchError.http(status: http.statusCode,
                                   body: String(data: respData, encoding: .utf8) ?? "")
        }
        guard let fileId = http.value(forHTTPHeaderField: "x-pdf-file-id") else {
            throw PrinchError.missingUploadHeaders
        }
        let pageCount = Int(http.value(forHTTPHeaderField: "x-page-count") ?? "1") ?? 1
        return UploadResult(pdfFileId: fileId,
                            fileKey: http.value(forHTTPHeaderField: "x-file-key"),
                            pageCount: pageCount,
                            pdfData: respData)
    }

    // MARK: - Documents & order

    func createDocument(_ req: DocumentRequest) async throws -> PrinchDocument {
        try await ensureToken()
        let data = try await perform(postJSON("/documents", body: req))
        return try decode(PrinchDocument.self, from: data)
    }

    func createOrderSession(_ req: OrderSessionRequest) async throws -> OrderSession {
        try await ensureToken()
        let data = try await perform(postJSON("/order-sessions", body: req))
        return try decode(OrderSession.self, from: data)
    }

    /// Long-poll until the order is released (or the request times out).
    func waitForOrder(sessionId: String) async throws -> OrderWaitResponse {
        try await ensureToken()
        var request = get("/order-sessions/\(sessionId)/wait")
        request.timeoutInterval = 120
        let data = try await perform(request)
        return try decode(OrderWaitResponse.self, from: data)
    }

    // MARK: - Request helpers

    private func get(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        let base = PrinchConfig.restBase.appendingPathComponent(PrinchConfig.apiPath + path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    private func postJSON<T: Encodable>(_ path: String, body: T) throws -> URLRequest {
        var request = URLRequest(url: PrinchConfig.restBase
            .appendingPathComponent(PrinchConfig.apiPath + path))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Execute a request, attaching the bearer token unless disabled.
    private func perform(_ request: URLRequest, authorized: Bool = true) async throws -> Data {
        var request = request
        if authorized {
            guard let token = accessToken else { throw PrinchError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PrinchError.decoding("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PrinchError.http(status: http.statusCode,
                                   body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw PrinchError.decoding("\(error)") }
    }
}

/// Parse a scanned QR payload or typed code into a printer display id.
/// Accepts full `print.princh.com/?pid=108815` URLs or bare numeric codes.
enum PrinterCodeParser {
    static func displayId(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed),
           let pid = comps.queryItems?.first(where: { $0.name == "pid" })?.value,
           !pid.isEmpty {
            return pid
        }
        let digits = trimmed.filter(\.isNumber)
        if !digits.isEmpty, digits.count == trimmed.count { return digits }
        return nil
    }
}
