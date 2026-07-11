//
//  FindPrinterView.swift
//  WBRLP
//
//  Browse/search the global printer directory and pick one to print to.
//

import SwiftUI
import Combine
import CoreLocation

struct FindPrinterView: View {
    @ObservedObject var model: PrintFlowModel
    @EnvironmentObject var savedStore: SavedPrintersStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var location = LocationProvider()

    /// Preprocessed directory: search text + location computed once per printer.
    @State private var index: [IndexedPrinter] = []
    /// The rows currently shown (already filtered, sorted, and capped).
    @State private var displayed: [DisplayRow] = []
    @State private var query = ""
    @State private var loading = true
    @State private var loadError: String?

    private let rowLimit = 150

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading printers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't load printers", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    printerList
                }
            }
            .navigationTitle("Find a printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .searchable(text: $query, prompt: "Name, city, or address")
        .task { await load() }
        // Debounced recompute on typing.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            recompute()
        }
        // Recompute when a location fix arrives (sort by nearest).
        .onChange(of: location.location?.timestamp) { _, _ in recompute() }
    }

    private var printerList: some View {
        List {
            Section {
                if displayed.isEmpty {
                    Text(query.isEmpty ? "No printers available." : "No printers match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(displayed) { row($0) }
            } header: {
                Text(headerText)
            } footer: {
                if displayed.count >= rowLimit {
                    Text("Showing the first \(rowLimit). Search to narrow it down.")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if !location.authorized {
                Button {
                    location.request()
                } label: {
                    Label("Show printers near me", systemImage: "location")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 6)
            }
        }
    }

    private var headerText: String {
        if !query.isEmpty { return "Results" }
        return location.location != nil ? "Nearest to you" : "All printers"
    }

    private func row(_ row: DisplayRow) -> some View {
        Button {
            select(row.printer)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.printer.name).font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if !row.printer.address.isEmpty {
                        Text(row.printer.address).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text("#\(row.printer.printerId)")
                        if let d = row.distanceText { Text("· \(d)") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    savedStore.toggle(SavedPrinter(row.printer))
                } label: {
                    Image(systemName: savedStore.isSaved(row.printer.printerId) ? "star.fill" : "star")
                        .foregroundStyle(savedStore.isSaved(row.printer.printerId) ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        loadError = nil
        do {
            let printers = try await PrinterDirectory.shared.all()
            index = printers.map(IndexedPrinter.init)
            loading = false
            recompute()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            loading = false
        }
    }

    /// Filter + sort + cap once, storing cheap rows for the List to render.
    private func recompute() {
        let here = location.location
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Pair each (matching) printer with its distance in one pass.
        var pairs: [(IndexedPrinter, Double?)] = []
        pairs.reserveCapacity(index.count)
        for item in index {
            if !q.isEmpty && !item.haystack.contains(q) { continue }
            let dist = here.map { item.location.distance(from: $0) }
            pairs.append((item, dist))
        }

        if here != nil {
            pairs.sort { ($0.1 ?? .greatestFiniteMagnitude) < ($1.1 ?? .greatestFiniteMagnitude) }
        } else if q.isEmpty {
            pairs.sort { $0.0.printer.name < $1.0.printer.name }
        }

        displayed = pairs.prefix(rowLimit).map {
            DisplayRow(printer: $0.0.printer,
                       distanceText: $0.1.map(Self.distanceText))
        }
    }

    private func select(_ printer: PrinterLocation) {
        model.loadPrinter(code: printer.printerId)
        dismiss()
    }

    /// Cheap distance string (no NSFormatter allocation per row).
    private static func distanceText(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        if meters < 100_000 { return String(format: "%.1f km", meters / 1000) }
        return "\(Int((meters / 1000).rounded())) km"
    }
}

/// A printer with precomputed search + location, built once after loading.
private struct IndexedPrinter {
    let printer: PrinterLocation
    let haystack: String
    let location: CLLocation

    init(_ printer: PrinterLocation) {
        self.printer = printer
        self.haystack = "\(printer.name) \(printer.address) \(printer.printerId)".lowercased()
        self.location = CLLocation(latitude: printer.coordinate.latitude,
                                   longitude: printer.coordinate.longitude)
    }
}

/// A cheap, render-ready row (no work happens in `body`).
private struct DisplayRow: Identifiable {
    let printer: PrinterLocation
    let distanceText: String?
    var id: String { printer.printerId }
}

/// Minimal one-shot location provider for "near me" sorting.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var authorized = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        let status = manager.authorizationStatus
        authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        if authorized { manager.requestLocation() }
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            authorized = status == .authorizedWhenInUse || status == .authorizedAlways
            if authorized { manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.location = locations.last }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
