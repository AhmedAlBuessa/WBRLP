//
//  SavedPrintersStore.swift
//  PrintSpot
//
//  Persists the user's saved/favourite printers in UserDefaults.
//

import Foundation
import Combine

/// A printer the user has saved for quick access.
struct SavedPrinter: Codable, Identifiable, Equatable {
    let printerId: String
    var name: String
    var address: String

    var id: String { printerId }

    init(printerId: String, name: String, address: String = "") {
        self.printerId = printerId
        self.name = name
        self.address = address
    }

    init(_ location: PrinterLocation) {
        self.init(printerId: location.printerId, name: location.name, address: location.address)
    }
}

@MainActor
final class SavedPrintersStore: ObservableObject {
    @Published private(set) var printers: [SavedPrinter] = []

    private let key = "printspot.savedPrinters.v1"

    init() { load() }

    func isSaved(_ printerId: String) -> Bool {
        printers.contains { $0.printerId == printerId }
    }

    func toggle(_ printer: SavedPrinter) {
        isSaved(printer.printerId) ? remove(printer.printerId) : add(printer)
    }

    func add(_ printer: SavedPrinter) {
        guard !isSaved(printer.printerId) else { return }
        printers.append(printer)
        save()
    }

    func remove(_ printerId: String) {
        printers.removeAll { $0.printerId == printerId }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where printers.indices.contains(index) {
            printers.remove(at: index)
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([SavedPrinter].self, from: data) else { return }
        printers = saved
    }

    private func save() {
        if let data = try? JSONEncoder().encode(printers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
