// ModelContainerFactory.swift - Opens the app's SwiftData store.

import Foundation
import SwiftData

/// Builds the app's `ModelContainer`.
enum ModelContainerFactory {

    /// Store file name (SwiftData's default). Part of the on-disk contract —
    /// renaming it looks like a fresh install.
    static let storeName = "default"

    /// Location of the store, for backups and diagnostics.
    static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "\(storeName).store")
    }

    /// Build the container for the whole app.
    ///
    /// - Parameter inMemory: use a throwaway store. Previews and tests only.
    @MainActor
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let configuration = ModelConfiguration(
            storeName,
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: LNReaderSchemaMigrationPlan.self,
            configurations: configuration
        )
    }
}
