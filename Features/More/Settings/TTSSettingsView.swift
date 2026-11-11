import SwiftUI

struct TTSSettingsView: View {
    @AppStorage("tts.enabled") private var enabled = true
    @AppStorage("tts.voice") private var defaultVoice = "breeze-warm"
    @ObservedObject private var library = TTSOfflineLibrary.shared
    @State private var selected: Set<String> = []
    @State private var showStorage = false
    var body: some View {
        Form {
            Section { Toggle("Enable narration", isOn: $enabled); NarrationComputePicker() }
            Section {
                NarrationVoicePicker(selected: $selected)
            } header: { Text("Default narrator") }
            Section {
                if let engine = library.engineState, engine.needsAttention {
                    Label(engine.message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
                NavigationLink("Manage downloaded audio") {
                    List {
                        ForEach(library.records.filter { !$0.isPreview }) { record in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(record.rendition.bookTitle).font(.headline)
                                    Text(record.rendition.title).font(.caption)
                                    Text("\(library.voices.first { $0.id == record.rendition.voiceId }?.name ?? record.manifest?.voiceName ?? record.rendition.voiceId) · \(record.isAvailable ? "Available offline" : record.state)").font(.caption).foregroundStyle(.secondary)
                                }
                                if let message = record.error { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AppTheme.warning).accessibilityLabel(message) }
                                Spacer()
                                Button(role: .destructive) { Task { await library.delete(record.id) } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Delete audio")
                            }
                        }
                    }.navigationTitle("Audio storage")
                }
                Button("Refresh voices and download previews") { Task { await library.refreshVoices() } }
            } footer: {
                if let error = library.errorMessage { Text(error) }
            }
        }
        .settingsScreen("Narration")
        .task { selected = [library.migratedDefaultVoice]; await library.refreshVoices(); await library.refresh() }
        .onChange(of: selected) { oldValue, newValue in
            if let added = newValue.subtracting(oldValue).first { defaultVoice = added; selected = [added] }
            else if newValue.isEmpty { selected = [defaultVoice] }
        }
    }
}
