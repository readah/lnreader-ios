// AboutView.swift
// App info, version, and links.

import SwiftUI

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                header
            }

            Section("App") {
                LabeledContent("Version", value: versionString)
                LabeledContent("Build", value: buildString)
                LabeledContent("Bundle ID", value: bundleID)
            }

            Section("Links") {
                Link("LNReader for iOS on GitHub", destination: URL(string: "https://github.com/readah/lnreader-ios")!)
                Link("Report an issue", destination: URL(string: "https://github.com/readah/lnreader-ios/issues")!)
            }

            Section {
                Link("LNReader (Android)", destination: URL(string: "https://github.com/LNReader/lnreader")!)
                Link(
                    "lnreader-plugins",
                    destination: URL(string: "https://github.com/LNReader/lnreader-plugins")!
                )
                Link("Mihon", destination: URL(string: "https://github.com/mihonapp/mihon")!)
                Link(
                    "Keiyoushi extensions",
                    destination: URL(string: "https://github.com/keiyoushi/extensions-source")!
                )
            } header: {
                Text("Credits")
            } footer: {
                Text("Sources are native Swift ports of the upstream projects above; manga sources keep Mihon's source ids. Narration uses Breeze TTS 2.")
            }
        }
        .settingsScreen("About")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.fill")
                .font(.largeTitle)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(Typography.title)

                Text("Native iOS reader for novels and manga")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "LNReader"
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private var buildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }
}
