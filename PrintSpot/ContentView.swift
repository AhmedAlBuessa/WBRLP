//
//  ContentView.swift
//  PrintSpot
//
//  Created by Ahmed AlBuessa on 2026-07-11.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model = PrintFlowModel()
    @StateObject private var savedStore = SavedPrintersStore()

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .selectingPrinter, .loadingPrinter:
                    PrinterSelectionView(model: model)
                default:
                    PrintJobView(model: model)
                }
            }
            .navigationTitle("PrintSpot")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(savedStore)
        .tint(.indigo)
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

#Preview {
    ContentView()
}
