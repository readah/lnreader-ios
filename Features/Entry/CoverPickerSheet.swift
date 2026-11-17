// CoverPickerSheet.swift
// Change the book view's cover: AniList results, or an image URL.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CoverPickerSheet: View {
    @Environment(\.appDismiss) private var dismiss

    let title: String
    let isNovel: Bool
    let currentCover: String?
    let sourceCover: String?
    /// `nil` puts the source's own cover back.
    let onChoose: (String?) -> Void

    @State private var search: String
    @State private var candidates: [CoverCandidate] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var pastedURL = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var isProcessingCustomCover = false

    init(
        title: String,
        isNovel: Bool,
        currentCover: String?,
        sourceCover: String?,
        onChoose: @escaping (String?) -> Void
    ) {
        self.title = title
        self.isNovel = isNovel
        self.currentCover = currentCover
        self.sourceCover = sourceCover
        self.onChoose = onChoose
        _search = State(initialValue: title)
    }

    private var isCustomCover: Bool { currentCover?.hasPrefix("local://Covers/") == true }
    private var usesSourceCover: Bool { currentCover == sourceCover }

    private var validPastedURL: String? {
        let text = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url.absoluteString
    }

    var body: some View {
        AppNavigationStack {
            List {
                Section("In use") {
                    HStack(spacing: 14) {
                        EntryCoverView(url: currentCover, cornerRadius: 8)
                            .frame(width: 56, height: 80)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(currentCover == nil ? "No cover" : (isCustomCover ? "Custom cover" : (usesSourceCover ? "Source cover" : "Chosen cover")))
                                .font(.subheadline)
                            if !usesSourceCover, sourceCover != nil {
                                Button("Use source cover") { choose(nil) }
                                    .font(.subheadline)
                            }
                        }
                    }
                }

                Section("Custom cover") {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose from Files", systemImage: "folder")
                    }
                    if isProcessingCustomCover {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Saving cover…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    ForEach(candidates) { candidate in
                        Button { choose(candidate.coverURL) } label: {
                            candidateRow(candidate)
                        }
                        .buttonStyle(AppPlainButtonStyle())
                    }
                    if candidates.isEmpty, !isSearching {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView(
                                "No covers found",
                                systemImage: "photo",
                                description: Text("Try a shorter title, or paste an image URL below."))
                        }
                    }
                } header: {
                    HStack {
                        Text("AniList")
                        Spacer()
                        if isSearching { ProgressView() }
                    }
                }

                Section("From a URL") {
                    TextField("https://…", text: $pastedURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use this URL") {
                        if let validPastedURL { choose(validPastedURL) }
                    }
                    .disabled(validPastedURL == nil)
                }
            }
            .scrollContentBackground(.hidden)
                        .appBackdrop()
                        .appSearchable(text: $search, prompt: "Search AniList")
            .appNavigationTitle("Cover")
            .navigationBarTitleDisplayMode(.inline)
            .appToolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard url.startAccessingSecurityScopedResource() else {
                        errorMessage = "Could not access selected file"
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        saveAndChooseCustomCover(data: data)
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .onChange(of: selectedPhoto) { _, newItem in
                guard let newItem else { return }
                Task {
                    isProcessingCustomCover = true
                    defer { isProcessingCustomCover = false }
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            saveAndChooseCustomCover(data: data)
                        }
                    }
                }
            }
            .task(id: search) { await searchAniList() }
        }
    }

    private func saveAndChooseCustomCover(data: Data) {
        guard let uiImage = UIImage(data: data) else {
            errorMessage = "Could not decode chosen image"
            return
        }
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.85) else {
            errorMessage = "Could not process image"
            return
        }
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let coversDir = docDir.appendingPathComponent("Covers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
            let filename = "\(UUID().uuidString).jpg"
            let fileURL = coversDir.appendingPathComponent(filename)
            try jpegData.write(to: fileURL, options: .atomic)
            choose("local://Covers/\(filename)")
        } catch {
            errorMessage = "Could not save custom cover: \(error.localizedDescription)"
        }
    }

    private func candidateRow(_ candidate: CoverCandidate) -> some View {
        HStack(spacing: 12) {
            EntryCoverView(url: candidate.coverURL, cornerRadius: 6)
                .frame(width: 44, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(meta(candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if candidate.coverURL == currentCover {
                AppIcon(systemName: "checkmark", size: 15, relativeTo: .subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }

    private func meta(_ candidate: CoverCandidate) -> String {
        [candidate.format, candidate.year.map(String.init)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func searchAniList() async {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            candidates = []
            errorMessage = nil
            return
        }
        isSearching = true
        errorMessage = nil
        // A short pause keeps a keystroke from spending a request.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        do {
            let found = try await CoverArt.candidates(for: text, isNovel: isNovel)
            guard !Task.isCancelled else { return }
            candidates = found
        } catch {
            guard !Task.isCancelled else { return }
            candidates = []
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func choose(_ url: String?) {
        Haptics.shared.impact(.light)
        onChoose(url)
        dismiss()
    }
}
