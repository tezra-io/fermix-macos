import Foundation
import os

/// The app's logging namespace.
///
/// One subsystem, one category per area, so a diagnostic can be filtered in
/// Console without reading every line the process writes. Log lines are
/// operator diagnostics, never product copy: nothing here is shown in the UI,
/// and nothing user-visible is written as a Swift literal anywhere else.
public enum AppLog {
    public enum Category: String {
        case app
        case voice
        case service
        case lifecycle
        case agent
    }

    private static let subsystem = "ai.fermix.app"

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
