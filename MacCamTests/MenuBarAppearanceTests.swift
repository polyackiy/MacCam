import XCTest
import AppKit
@testable import MacCam

final class MenuBarAppearanceTests: XCTestCase {
    func testAllDiscreetSymbolsResolve() {
        for icon in DiscreetIcon.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil),
                "SF Symbol '\(icon.symbolName)' for \(icon.label) must exist on this OS")
        }
    }

    func testStyleHasNormalAndDiscreet() {
        XCTAssertEqual(Set(MenuBarStyle.allCases.map(\.rawValue)), ["normal", "discreet"])
    }

    func testDiscreetIconsArePersistableRoundTrip() {
        for icon in DiscreetIcon.allCases {
            XCTAssertEqual(DiscreetIcon(rawValue: icon.rawValue), icon)
        }
    }
}
