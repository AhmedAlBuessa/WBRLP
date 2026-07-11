//
//  PrintFlowModel.swift
//  WBRLP
//
//  Orchestrates the end-to-end print flow and drives the UI.
//

import Foundation
import SwiftUI
import Combine
import PDFKit
import UniformTypeIdentifiers

/// One file queued for printing, with its own settings and server state.
struct PrintItem: Identifiable {
    let id = UUID()
    var filename: String
    var sourceData: Data
    var mimeType: String
    var options: PrintOptions
    var upload: UploadResult?
    var document: PrinchDocument?
    var thumbnail: UIImage?
    /// Best local guess before upload (exact for PDFs, 1 for images).
    var localPageCount: Int = 1

    var isImage: Bool { mimeType.hasPrefix("image/") }
    /// Server page count once uploaded, else the local estimate.
    var pageCount: Int { upload?.pageCount ?? localPageCount }
    /// Authoritative price once the document is created on the server.
    var priceCents: Int? { document?.price.price }
}

@MainActor
final class PrintFlowModel: ObservableObject {

    enum Phase: Equatable {
        case selectingPrinter
        case loadingPrinter
        case configuring
        case preparing        // uploading + pricing
        case review
        case placing          // creating order + waiting for release
        case completed
    }

    // MARK: Published state
    @Published var phase: Phase = .selectingPrinter
    @Published var device: Device?
    @Published var items: [PrintItem] = []
    @Published var libraryUserId: String = ""
    @Published var order: OrderSession?
    @Published var errorMessage: String?
    @Published var statusMessage: String = ""

    /// Settings applied to every file at once, and the defaults for new files.
    @Published var defaultOptions = PrintOptions()

    private let api = PrinchAPI()
    private var paytype: Paytype?
    private var publicKeyId: String?

    // MARK: Derived
    var mediaOptions: [MediaOption] { device?.printer.capabilities.mediaOptions ?? [] }
    var supportsColor: Bool { device?.printer.capabilities.supportsColor ?? false }
    var supportsDuplex: Bool { device?.printer.capabilities.duplex ?? false }
    var maxPages: Int { device?.printer.capabilities.maxPagesPerDocument ?? 999 }
    var requiresLibraryId: Bool { paytype?.isEnvisionware ?? false }

    var currency: String {
        order?.price.currency ?? device?.printer.prices?.currency ?? "CAD"
    }

    /// Total from the server if we have it, else the sum of document prices.
    var totalCents: Int {
        if let order { return order.price.totalPrice }
        return items.compactMap(\.priceCents).reduce(0, +)
    }

    var canPlaceOrder: Bool {
        guard !items.isEmpty, items.allSatisfy({ $0.document != nil }) else { return false }
        if requiresLibraryId && libraryUserId.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    // MARK: - Printer selection

    func loadPrinter(fromScan raw: String) {
        guard let code = PrinterCodeParser.displayId(from: raw) else {
            errorMessage = PrinchError.invalidPrinterCode.errorDescription
            return
        }
        loadPrinter(code: code)
    }

    func loadPrinter(code: String) {
        phase = .loadingPrinter
        errorMessage = nil
        Task {
            do {
                let device = try await api.fetchDevice(displayId: code)
                let paytypes = try await api.fetchPaymentTypes(deviceId: device.deviceId)
                let connector = try await api.fetchConnector(id: device.connectorId)
                self.device = device
                self.paytype = paytypes.first(where: \.isEnvisionware) ?? paytypes.first
                self.publicKeyId = connector.publicKeyId
                self.defaultOptions = self.makeInitialOptions()
                self.phase = .configuring
            } catch {
                self.errorMessage = describe(error)
                self.phase = .selectingPrinter
            }
        }
    }

    private func makeInitialOptions() -> PrintOptions {
        let mediaKey = device?.printer.defaults?.format
            ?? mediaOptions.first(where: { $0.displayName.hasPrefix("Letter") })?.key
            ?? mediaOptions.first?.key ?? ""
        return PrintOptions(color: false, copies: 1, duplex: false, mediaSizeKey: mediaKey)
    }

    /// Change a setting for every file at once and for files added later.
    func updateDefault(_ mutate: (inout PrintOptions) -> Void) {
        mutate(&defaultOptions)
        for index in items.indices { mutate(&items[index].options) }
    }

    // MARK: - Queue management

    func addImage(_ data: Data, filename: String) {
        let thumb = UIImage(data: data)?.thumbnail(maxDimension: 240)
        items.append(PrintItem(filename: filename, sourceData: data,
                               mimeType: mimeType(for: filename, fallback: "image/jpeg"),
                               options: defaultOptions, thumbnail: thumb))
    }

    func addDocument(_ data: Data, filename: String) {
        let pages = PDFDocument(data: data)?.pageCount ?? 1
        items.append(PrintItem(filename: filename, sourceData: data,
                               mimeType: mimeType(for: filename, fallback: "application/pdf"),
                               options: defaultOptions, localPageCount: max(1, pages)))
    }

    func remove(_ item: PrintItem) {
        items.removeAll { $0.id == item.id }
    }

    func mediaOption(for item: PrintItem) -> MediaOption? {
        mediaOptions.first { $0.key == item.options.mediaSizeKey } ?? mediaOptions.first
    }

    // MARK: - Live price estimate

    /// Estimated cost for one file, computed locally from the printer's price
    /// table. `nil` if the printer didn't advertise prices.
    func estimatedCents(for item: PrintItem) -> Int? {
        guard let prices = device?.printer.prices,
              let perPage = prices.pricePerPage(mediaKey: item.options.mediaSizeKey,
                                                color: item.options.color) else { return nil }
        return perPage * item.pageCount * item.options.copies
    }

    /// Estimated total for the whole queue (before the server confirms).
    var estimatedTotalCents: Int? {
        guard device?.printer.prices != nil, !items.isEmpty else { return nil }
        let start = device?.printer.prices?.startPrice ?? 0
        let sum = items.reduce(0) { $0 + (estimatedCents(for: $1) ?? 0) }
        return start + sum
    }

    var hasEstimate: Bool { estimatedTotalCents != nil }

    // MARK: - Prepare (upload + price)

    func prepareOrder() {
        guard let device else { return }
        phase = .preparing
        errorMessage = nil
        Task {
            do {
                for index in items.indices {
                    statusMessage = "Uploading \(items[index].filename)…"
                    let item = items[index]
                    let media = mediaOption(for: item)
                        ?? MediaOption(key: "letter",
                                       dimensions: MediaDimensions(width_microns: 215900,
                                                                   height_microns: 279400))
                    let uploadOptions = UploadOptions(widthMicrons: media.portraitWidth,
                                                      heightMicrons: media.portraitHeight,
                                                      fitToPage: true)
                    let upload = try await api.uploadFile(data: item.sourceData,
                                                          filename: item.filename,
                                                          mimeType: item.mimeType,
                                                          publicKeyId: publicKeyId,
                                                          options: uploadOptions)
                    items[index].upload = upload

                    let ticket = Ticket(options: item.options,
                                        media: media,
                                        pageCount: upload.pageCount)
                    let request = DocumentRequest(deviceId: device.deviceId,
                                                  domain: device.domain,
                                                  title: item.filename,
                                                  pdfFileId: upload.pdfFileId,
                                                  ticket: ticket)
                    let doc = try await api.createDocument(request)
                    items[index].document = doc
                }
                statusMessage = ""
                phase = .review
            } catch {
                errorMessage = describe(error)
                phase = .configuring
            }
        }
    }

    // MARK: - Place order

    func placeOrder() {
        guard let paytype else { return }
        phase = .placing
        errorMessage = nil
        let documentIds = items.compactMap { $0.document?.documentId }
        let clientData = requiresLibraryId
            ? PaytypeClientData(envisionwareUserId: libraryUserId.trimmingCharacters(in: .whitespaces))
            : nil
        Task {
            do {
                statusMessage = "Sending to \(device?.locationName ?? "the library")…"
                let request = OrderSessionRequest(
                    documentIds: documentIds,
                    paytypeId: paytype.paytypeId,
                    secureRelease: false,
                    appInfo: .current,
                    locale: PrinchConfig.locale,
                    acceptUrl: PrinchConfig.acceptURL,
                    paytypeClientData: clientData)
                let order = try await api.createOrderSession(request)
                self.order = order

                statusMessage = "Waiting for release at the printer…"
                _ = try? await api.waitForOrder(sessionId: order.orderSessionId)
                statusMessage = ""
                phase = .completed
            } catch {
                errorMessage = describe(error)
                phase = .review
            }
        }
    }

    // MARK: - Reset

    func startOver() {
        items.removeAll()
        order = nil
        errorMessage = nil
        statusMessage = ""
        phase = .configuring
    }

    func chooseAnotherPrinter() {
        device = nil
        paytype = nil
        startOver()
        phase = .selectingPrinter
    }

    // MARK: - Helpers

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func mimeType(for filename: String, fallback: String) -> String {
        let ext = (filename as NSString).pathExtension
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return fallback
    }
}

/// Format cents (minor units) as a currency string.
func formatPrice(_ cents: Int, currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    return formatter.string(from: NSNumber(value: Double(cents) / 100.0))
        ?? "\(Double(cents) / 100.0) \(currency)"
}

extension UIImage {
    /// Downscaled copy for list thumbnails.
    func thumbnail(maxDimension: CGFloat) -> UIImage {
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
