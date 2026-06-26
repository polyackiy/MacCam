import Foundation
import os

/// Centralized unified-logging handles. Use instead of `NSLog` so messages are
/// categorized and visible in Console.app under the app's subsystem.
enum Log {
    private static let subsystem = "com.maccam.app"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let system = Logger(subsystem: subsystem, category: "system")
}
