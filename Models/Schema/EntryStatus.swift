// EntryStatus.swift - Publication status shared by novels and manga.

import Foundation

/// Publication status of an entry.
///
/// Raw values match Yokai/Mihon's `SManga` status constants so they survive a
/// `.tachibk` backup round-trip unchanged. Treat the numbers as an on-disk
/// format: append new cases, never renumber.
enum EntryStatus: Int, Codable, CaseIterable, Sendable, Hashable {
    case unknown = 0
    case ongoing = 1
    case completed = 2
    case licensed = 3
    case publishingFinished = 4
    case cancelled = 5
    case onHiatus = 6

    /// Name shown in entry details.
    var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .ongoing: "Ongoing"
        case .completed: "Completed"
        case .licensed: "Licensed"
        case .publishingFinished: "Publishing finished"
        case .cancelled: "Cancelled"
        case .onHiatus: "On hiatus"
        }
    }

    /// SF Symbol shown next to the status.
    var iconName: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .ongoing: "clock.arrow.circlepath"
        case .completed: "checkmark.circle.fill"
        case .licensed: "lock.fill"
        case .publishingFinished: "flag.checkered"
        case .cancelled: "xmark.circle.fill"
        case .onHiatus: "pause.circle.fill"
        }
    }

    /// The v1 status names, which is what other sync clients still parse.
    var legacyRawValue: String {
        switch self {
        case .unknown: "Unknown"
        case .ongoing: "Ongoing"
        case .completed: "Completed"
        case .licensed: "Licensed"
        case .publishingFinished: "Publishing Finished"
        case .cancelled: "Cancelled"
        case .onHiatus: "On Hiatus"
        }
    }

    /// Best-effort parse of the loose status strings sources return.
    ///
    /// LN plugins hand back free text ("Ongoing", "COMPLETED", "hiatus", …)
    /// while Mihon sources use the numeric constants directly.
    static func parse(_ raw: String?) -> EntryStatus {
        guard let raw else { return .unknown }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "unknown", "n/a", "-": return .unknown
        case "ongoing", "on going", "publishing", "releasing", "in progress": return .ongoing
        case "completed", "complete", "finished": return .completed
        case "licensed": return .licensed
        case "publishing finished", "publishing_finished": return .publishingFinished
        case "cancelled", "canceled", "dropped", "discontinued": return .cancelled
        case "on hiatus", "hiatus", "on hold", "paused": return .onHiatus
        default:
            // Numeric strings come from the Mihon side of the bridge.
            if let value = Int(normalized), let status = EntryStatus(rawValue: value) {
                return status
            }
            return .unknown
        }
    }
}
