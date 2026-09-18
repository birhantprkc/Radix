import AppKit
import SwiftUI
import QuickLook

// Standalone API experiment; intentionally not part of a Radix build target.
// See ../quick-look-review.md for findings and reproduction instructions.

struct ProbeFile: Identifiable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@main
struct QuickLookProbeApp: App {
    var body: some Scene {
        Window("Quick Look API Probe", id: "probe") { ProbeView() }
    }
}

struct ProbeView: View {
    let files = ["First.txt", "Second.txt", "Third.txt"].map {
        ProbeFile(url: URL(fileURLWithPath: "/tmp/radix-quicklook-fixtures/" + $0))
    }
    @FocusState private var tableFocused: Bool
    @State private var selected: URL?
    @State private var previewed: URL?
    @State private var filter = ""
    @State private var collection = true
    @State private var history = ""

    var previewBinding: Binding<URL?> {
        Binding(get: { previewed }, set: { value in
            guard value != previewed else { return }
            history += "binding -> \(value?.lastPathComponent ?? "nil")\n"
            previewed = value
        })
    }
    var body: some View {
        VStack(alignment: .leading) {
            TextField("Search (Space must type)", text: $filter)
            Toggle("Browse all fixture files", isOn: $collection)
            Table(files, selection: $selected) {
                TableColumn("Name", value: \.name)
            }
            .focused($tableFocused)
            .simultaneousGesture(TapGesture().onEnded { tableFocused = true })
            .onKeyPress(.space, phases: .down) { event in
                guard event.modifiers.isEmpty else { return .ignored }
                previewed = previewed == nil ? selected : nil
                return .handled
            }
            HStack {
                Button("Preview") { previewed = selected ?? files[0].url }
                Button("Dismiss") { previewed = nil }
                Button("Select Second") { selected = files[1].url }
            }
            HStack {
                Button("Preview then select second") {
                    previewed = files[0].url
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        selected = files[1].url
                    }
                }
                Button("Preview then dismiss") {
                    previewed = files[0].url
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        previewed = nil
                    }
                }
            }
            Text("Selected: \(selected?.lastPathComponent ?? "nil")")
            Text("Previewed: \(previewed?.lastPathComponent ?? "nil")")
            Text(history).font(.system(.caption, design: .monospaced))
                .frame(height: 100, alignment: .topLeading)
        }
        .padding().frame(width: 500, height: 500)
        .quickLookPreview(previewBinding, in: collection ? files.map(\.url) : [previewed].compactMap { $0 })
        .onChange(of: selected) { _, value in
            if previewed != nil { previewed = value }
        }
    }
}
