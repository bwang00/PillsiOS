import XCTest
import SwiftUI
import SwiftData
@testable import Pills

@MainActor
final class ButterflyHugViewTests: XCTestCase {
    func test_view_instantiatesAndRendersWithoutCrash() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Guide.self, Session.self, configurations: config)
        let guide = Guide(
            id: UUID().uuidString, slug: "grounding-butterfly-hug", category: "grounding",
            title: "蝴蝶拥抱", summary: "", sortOrder: 9, isActive: true,
            configJSON: #"{"mode":"bilateral_tap","tap_interval":1.0}"#)
        container.mainContext.insert(guide)

        let hosting = UIHostingController(
            rootView: ButterflyHugView(guide: guide)
                .modelContainer(container))
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)
    }
}
