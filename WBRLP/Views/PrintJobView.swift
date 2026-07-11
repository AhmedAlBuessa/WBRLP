//
//  PrintJobView.swift
//  WBRLP
//
//  Configure the queue, review pricing, place the order, and show release info.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PrintJobView: View {
    @ObservedObject var model: PrintFlowModel

    var body: some View {
        switch model.phase {
        case .configuring:
            ConfigureView(model: model)
        case .preparing:
            BusyView(title: "Preparing your files",
                     message: model.statusMessage.isEmpty ? "Uploading…" : model.statusMessage)
        case .review:
            ReviewView(model: model)
        case .placing:
            BusyView(title: "Placing your order",
                     message: model.statusMessage.isEmpty ? "Please wait…" : model.statusMessage)
        case .completed:
            CompletedView(model: model)
        default:
            EmptyView()
        }
    }
}

// MARK: - Configure

private struct ConfigureView: View {
    @ObservedObject var model: PrintFlowModel
    @EnvironmentObject var savedStore: SavedPrintersStore
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    var body: some View {
        Form {
            if let device = model.device {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "printer.fill").foregroundStyle(.indigo)
                        VStack(alignment: .leading) {
                            Text(device.locationName).font(.headline)
                            if let desc = device.locationDescription {
                                Text(desc).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Printer \(device.displayId) · \(device.printerName)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            savedStore.toggle(SavedPrinter(printerId: device.displayId,
                                                           name: device.locationName,
                                                           address: device.locationDescription ?? ""))
                        } label: {
                            Image(systemName: savedStore.isSaved(device.displayId) ? "star.fill" : "star")
                                .foregroundStyle(savedStore.isSaved(device.displayId) ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if !model.items.isEmpty {
                Section {
                    BulkSettings(model: model)
                } header: {
                    Text("Settings for all files")
                } footer: {
                    Text("Applies to every file. You can still change a single file below.")
                }
            }

            Section("Files to print") {
                if model.items.isEmpty {
                    Text("No files added yet.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                ForEach($model.items) { $item in
                    ItemRow(item: $item, model: model)
                }
                .onDelete { indexSet in
                    for index in indexSet { model.remove(model.items[index]) }
                }

                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Label("Add photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("Add documents", systemImage: "doc.badge.plus")
                }
            }

            if model.requiresLibraryId {
                Section("Library account") {
                    TextField("Library card number or email", text: $model.libraryUserId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Used to release your print at the printer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                if let total = model.estimatedTotalCents {
                    HStack {
                        Text("Estimated total").font(.headline)
                        Spacer()
                        Text(formatPrice(total, currency: model.currency))
                            .font(.headline.monospacedDigit())
                    }
                }
                Button {
                    model.prepareOrder()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.items.isEmpty)
            } footer: {
                if model.hasEstimate {
                    Text("Estimated from the printer's price list. The exact total is confirmed on the next screen.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Change printer") { model.chooseAnotherPrinter() }
            }
        }
        .onChange(of: photoSelection) { _, newValue in
            Task { await importPhotos(newValue) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: Self.importableTypes,
                      allowsMultipleSelection: true) { result in
            handleFileImport(result)
        }
    }

    private static let importableTypes: [UTType] = {
        var types: [UTType] = [.pdf, .image, .plainText, .rtf]
        if let doc = UTType("com.microsoft.word.doc") { types.append(doc) }
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") { types.append(docx) }
        return types
    }()

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let name = "photo_\(UUID().uuidString.prefix(6)).jpg"
                model.addImage(data, filename: name)
            }
        }
        photoSelection = []
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                model.addDocument(data, filename: url.lastPathComponent)
            }
        }
    }
}

// MARK: - Item row + per-item options

// MARK: - Bulk settings (apply to all files)

private struct BulkSettings: View {
    @ObservedObject var model: PrintFlowModel

    var body: some View {
        Toggle("Colour", isOn: Binding(
            get: { model.defaultOptions.color },
            set: { newValue in model.updateDefault { $0.color = newValue } }))
            .disabled(!model.supportsColor)

        Stepper("Copies: \(model.defaultOptions.copies)", value: Binding(
            get: { model.defaultOptions.copies },
            set: { newValue in model.updateDefault { $0.copies = newValue } }),
            in: 1...50)

        if model.supportsDuplex {
            Toggle("Print both sides", isOn: Binding(
                get: { model.defaultOptions.duplex },
                set: { newValue in model.updateDefault { $0.duplex = newValue } }))
        }

        if model.mediaOptions.count > 1 {
            Picker("Paper size", selection: Binding(
                get: { model.defaultOptions.mediaSizeKey },
                set: { newValue in model.updateDefault { $0.mediaSizeKey = newValue } })) {
                ForEach(model.mediaOptions) { option in
                    Text(option.displayName).tag(option.key)
                }
            }
        }
    }
}

private struct ItemRow: View {
    @Binding var item: PrintItem
    @ObservedObject var model: PrintFlowModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            optionControls
        } label: {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename).lineLimit(1).font(.subheadline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let cents = model.estimatedCents(for: item) {
                    Text(formatPrice(cents, currency: model.currency))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let thumb = item.thumbnail {
            Image(uiImage: thumb)
                .resizable().scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: item.isImage ? "photo" : "doc.fill")
                .frame(width: 40, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var summary: String {
        var parts = ["\(item.pageCount) pg", item.options.color ? "Colour" : "B&W"]
        if item.options.copies > 1 { parts.append("\(item.options.copies) copies") }
        if item.options.duplex { parts.append("2-sided") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var optionControls: some View {
        Toggle("Colour", isOn: $item.options.color)
            .disabled(!model.supportsColor)
        Stepper("Copies: \(item.options.copies)", value: $item.options.copies, in: 1...50)
        if model.supportsDuplex {
            Toggle("Print both sides", isOn: $item.options.duplex)
        }
        if model.mediaOptions.count > 1 {
            Picker("Paper size", selection: $item.options.mediaSizeKey) {
                ForEach(model.mediaOptions) { option in
                    Text(option.displayName).tag(option.key)
                }
            }
        }
    }
}

// MARK: - Review

private struct ReviewView: View {
    @ObservedObject var model: PrintFlowModel

    var body: some View {
        Form {
            Section("Order summary") {
                ForEach(model.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.filename).lineLimit(1).font(.subheadline)
                            Text("\(item.pageCount) page\(item.pageCount == 1 ? "" : "s") · \(item.options.color ? "Colour" : "B&W")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let cents = item.priceCents {
                            Text(formatPrice(cents, currency: model.currency))
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text(formatPrice(model.totalCents, currency: model.currency))
                        .font(.headline.monospacedDigit())
                }
                if model.requiresLibraryId {
                    LabeledContent("Release to", value: model.libraryUserId)
                        .font(.subheadline)
                }
            }

            Section {
                Button {
                    model.placeOrder()
                } label: {
                    Text("Send to printer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPlaceOrder)

                Button("Back") { model.phase = .configuring }
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Busy + Completed

private struct BusyView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompletedView: View {
    @ObservedObject var model: PrintFlowModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Sent to the printer!").font(.title2.bold())

            if let order = model.order {
                VStack(spacing: 6) {
                    Text("Order")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(order.orderDisplayId)
                        .font(.title3.monospaced().bold())
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            Text(model.requiresLibraryId
                 ? "Go to the printer and release your job using your library account."
                 : "Go to the printer to collect your printout.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    model.startOver()
                } label: {
                    Text("Print more").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Choose another printer") { model.chooseAnotherPrinter() }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}
