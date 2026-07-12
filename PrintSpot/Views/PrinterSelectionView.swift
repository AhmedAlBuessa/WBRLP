//
//  PrinterSelectionView.swift
//  PrintSpot
//
//  First screen: saved printers, find a printer, scan, or type the id.
//

import SwiftUI

struct PrinterSelectionView: View {
    @ObservedObject var model: PrintFlowModel
    @EnvironmentObject var savedStore: SavedPrintersStore
    @State private var showScanner = false
    @State private var showFinder = false
    @State private var manualCode = ""

    var body: some View {
        Group {
            if model.phase == .loadingPrinter {
                ProgressView("Finding printer…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    header

                    Section {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan printer code", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            showFinder = true
                        } label: {
                            Label("Find a printer", systemImage: "mappin.and.ellipse")
                        }
                    }

                    Section("Enter printer ID") {
                        HStack {
                            TextField("e.g. 108815", text: $manualCode)
                                .keyboardType(.numberPad)
                                .submitLabel(.go)
                            Button("Go") { model.loadPrinter(code: manualCode) }
                                .buttonStyle(.borderedProminent)
                                .disabled(manualCode.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    if !savedStore.printers.isEmpty {
                        Section("Saved printers") {
                            ForEach(savedStore.printers) { printer in
                                Button { model.loadPrinter(code: printer.printerId) } label: {
                                    savedRow(printer)
                                }
                            }
                            .onDelete { savedStore.remove(atOffsets: $0) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            ScannerSheet(model: model, isPresented: $showScanner)
        }
        .sheet(isPresented: $showFinder) {
            FindPrinterView(model: model)
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "printer.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.indigo)
                Text("PrintSpot")
                    .font(.headline).multilineTextAlignment(.center)
                Text("Find & print at public printers anywhere.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private func savedRow(_ printer: SavedPrinter) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                if !printer.address.isEmpty {
                    Text(printer.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("#\(printer.printerId)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Full-screen scanner presented as a sheet with a cancel control.
struct ScannerSheet: View {
    @ObservedObject var model: PrintFlowModel
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .top) {
            QRScannerView { value in
                isPresented = false
                model.loadPrinter(fromScan: value)
            } onError: { message in
                isPresented = false
                model.errorMessage = message
            }
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 220, height: 220)
                .frame(maxHeight: .infinity, alignment: .center)

            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
            }
            .padding()

            Text("Point the camera at the printer's QR code")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.5), in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 60)
        }
    }
}
