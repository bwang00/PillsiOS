import XCTest
import SwiftUI
@testable import Pills

/// Covers the Settings surface: persistent privacy-policy and support links
/// plus the visible app version. These were previously only reachable inside
/// the one-time AI consent sheet.
@MainActor
final class SettingsViewTests: XCTestCase {

    // MARK: - AppInfo model

    func testAppInfo_exposesPrivacyAndSupportURLs() {
        XCTAssertEqual(AppInfo.privacyURL.absoluteString, "https://pills.blueping.xyz/privacy")
        XCTAssertEqual(AppInfo.supportURL.absoluteString, "https://pills.blueping.xyz/support")
    }

    func testAppInfo_versionDisplayMatchesBundle() {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        XCTAssertNotNil(short)
        XCTAssertNotNil(build)
        XCTAssertEqual(AppInfo.versionDisplay, "\(short!) (\(build!))")
    }

    // MARK: - Rendering

    func testSettingsView_rendersWithoutCrash() {
        let controller = UIHostingController(rootView: SettingsView())
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.view)
    }
}
