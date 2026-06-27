import XCTest
@testable import MacCam

final class AppLanguageTests: XCTestCase {
    func testExactCodes() {
        XCTAssertEqual(AppLanguage.match("en"), .en)
        XCTAssertEqual(AppLanguage.match("fr"), .fr)
        XCTAssertEqual(AppLanguage.match("pt-BR"), .ptBR)
        XCTAssertEqual(AppLanguage.match("zh-Hans"), .zhHans)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(AppLanguage.match("PT-br"), .ptBR)
        XCTAssertEqual(AppLanguage.match("ZH-HANS"), .zhHans)
    }

    func testRegionAndScriptQualified() {
        XCTAssertEqual(AppLanguage.match("fr-FR"), .fr)
        XCTAssertEqual(AppLanguage.match("en-US"), .en)
        XCTAssertEqual(AppLanguage.match("de-DE"), .de)
        XCTAssertEqual(AppLanguage.match("zh-Hans-CN"), .zhHans)
        XCTAssertEqual(AppLanguage.match("pt-BR"), .ptBR)
    }

    func testUnsupportedReturnsNil() {
        XCTAssertNil(AppLanguage.match("ko"))
        XCTAssertNil(AppLanguage.match("zh-Hant"))   // Traditional — not shipped
        XCTAssertNil(AppLanguage.match("pt-PT"))     // only pt-BR is shipped
        XCTAssertNil(AppLanguage.match("xyz"))
    }

    func testNineLanguagesWithAutonyms() {
        XCTAssertEqual(AppLanguage.allCases.count, 9)
        for language in AppLanguage.allCases {
            XCTAssertFalse(language.autonym.isEmpty, "\(language.rawValue) missing autonym")
        }
    }
}
