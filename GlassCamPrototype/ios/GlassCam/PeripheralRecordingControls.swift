import SwiftUI
import UIKit

final class PeripheralRecordingModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var records: [URL] = []
    @Published private(set) var lastSaved: String?
    @Published private(set) var error: String?
    @Published var share: RecordingShare?
    struct RecordingShare: Identifiable { let url: URL; var id: URL { url } }
    private let recorder = PeripheralStateRecorder.shared
    func dismissError() { error = nil }

    func refresh() {
        recorder.list { [weak self] urls in DispatchQueue.main.async { self?.records = urls } }
    }
    func record(source: PeripheralFrameSource?, camera: [String: Any]) {
        guard !isBusy else { return }
        isBusy = true; error = nil; lastSaved = nil
        let inputs = source?.recordingSnapshot()
        var context = camera; context["sourceSnapshot"] = inputs?.state ?? ["available": false]
        let admitted = recorder.record(pair: inputs?.pair, camera: context, unpaired: inputs?.pending ?? []) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let url): self.lastSaved = url.lastPathComponent; self.refresh()
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
        if !admitted { isBusy = false; error = NSLocalizedString("A recording is still being saved. Try again shortly.", comment: "") }
    }
    func export() {
        guard !isBusy else { return }
        isBusy = true; error = nil
        let admitted = recorder.export { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let url): self.share = RecordingShare(url: url)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
        if !admitted { isBusy = false }
    }
}

struct PeripheralRecordingControls: View {
    @ObservedObject var model: PeripheralRecordingModel
    let record: () -> Void
    @State private var showingRecords = false
    @State private var tolerance = PeripheralTolerance.shared.value
    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                HStack {
                    Text("Tolerance").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(tolerance, format: .number.precision(.fractionLength(2)))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .accessibilityIdentifier("glass.tolerance-value")
                }
                Slider(value: Binding(get: { tolerance }, set: { value in
                    PeripheralTolerance.shared.value = value
                    tolerance = PeripheralTolerance.shared.value
                }), in: PeripheralTolerance.range, step: PeripheralTolerance.step)
                .tint(.white).accessibilityLabel("Tolerance")
                .accessibilityValue(Text(tolerance, format: .number.precision(.fractionLength(2))))
                .accessibilityHint("Higher values accept larger differences.")
                .accessibilityIdentifier("glass.tolerance")
            }
            .padding(.horizontal, 12).padding(.top, 8).frame(width: 190)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 0) {
                Button(action: record) {
                    HStack(spacing: 6) {
                        if model.isBusy { ProgressView().controlSize(.mini).tint(.white) }
                        else { Image(systemName: "waveform.path.badge.plus") }
                        Text("Record state")
                        if model.lastSaved != nil { Image(systemName: "checkmark").foregroundStyle(.green) }
                    }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                }.disabled(model.isBusy).accessibilityIdentifier("glass.record-state")
                Divider().frame(height: 20)
                Button { showingRecords = true; model.refresh() } label: {
                    Image(systemName: "folder").overlay(alignment: .topTrailing) {
                        if !model.records.isEmpty {
                            Text("\(model.records.count)").font(.system(size: 8, weight: .bold))
                                .padding(2).background(.black, in: Capsule()).offset(x: 8,y: -7)
                        }
                    }.frame(width: 44,height: 44)
                }.accessibilityLabel("Export state records").accessibilityIdentifier("glass.recordings")
            }
            .foregroundStyle(.white).background(.black.opacity(0.72), in: Capsule())
        }
        .foregroundStyle(.white).fixedSize().onAppear { model.refresh() }
        .sheet(isPresented: $showingRecords) {
            NavigationStack {
                List {
                    Section {
                        Text("Each tap saves original camera frames and the glass decision. Records stay on this iPhone until you copy or export them.")
                        Button(action: model.export) {
                            Label("Export all records", systemImage: "square.and.arrow.up")
                        }.disabled(model.isBusy || model.records.isEmpty).accessibilityIdentifier("glass.export")
                        if model.isBusy { ProgressView("Preparing records…") }
                        Text("Send the ZIP to this Mac with AirDrop, or copy GlassCamStateRecords from GlassCam in Files or Finder.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Saved records") {
                        if model.records.isEmpty { Text("No saved records yet.") }
                        ForEach(model.records.reversed(), id: \.self) { url in
                            Text(url.lastPathComponent).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
                }
                .navigationTitle("State records")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingRecords = false } } }
                .sheet(item: $model.share) { item in
                    RecordingShareSheet(url: item.url)
                }
            }
        }
        .alert("Could not save records", isPresented: Binding(
            get: { model.error != nil && !showingRecords },
            set: { if !$0 { model.dismissError() } })) {
                Button("View records") { showingRecords = true }
        } message: { Text(model.error ?? "") }
    }
}

private struct RecordingShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
