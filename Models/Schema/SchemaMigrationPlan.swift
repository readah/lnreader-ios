// SchemaMigrationPlan.swift - Keeps future schema changes migrating properly.

import Foundation
import SwiftData

/// Migration plan for the app store.
///
/// V1 → V2 adds `Chapter.hidden` (default false) and an index, which is a
/// lightweight change. Rows migrated from V1 start unhidden;
/// `LibraryMaintenance.reconcileVisibility` fills the column in once.
///
/// V2 → V3 only adds the `Highlight` table (and its index), so it is
/// lightweight too: existing rows are untouched and the table starts empty.
/// Every future change must add another version plus a stage rather than edit a
/// shipped one.
enum LNReaderSchemaMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
            .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
        ]
    }
}
