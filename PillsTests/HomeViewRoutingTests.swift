import XCTest
import SwiftData
@testable import Pills

@MainActor
final class HomeViewRoutingTests: XCTestCase {

    func test_butterflyGuide_isRoutedToButterflyHug() {
        let guide = Guide(
            id: UUID().uuidString, slug: "grounding-butterfly-hug", category: "grounding",
            title: "蝴蝶拥抱", summary: "", sortOrder: 9, isActive: true,
            configJSON: #"{"mode":"bilateral_tap","tap_interval":1.0}"#)
        XCTAssertTrue(guide.isButterflyHug)
        XCTAssertTrue(HomeView.showsButterflyHug(for: guide))
    }

    func test_breathingGuide_isNotRoutedToButterflyHug() {
        let guide = Guide(
            id: UUID().uuidString, slug: "breathing-478", category: "breathing",
            title: "4-7-8", summary: "", sortOrder: 1, isActive: true,
            configJSON: #"{"phases":[{"name":"吸气","duration":4}]}"#)
        XCTAssertFalse(HomeView.showsButterflyHug(for: guide))
    }
}
