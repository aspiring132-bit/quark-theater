import XCTest
@testable import QuarkTheater

final class SettingsCategoryTests: XCTestCase {
    func testAllCategoriesHaveDistinctIdentities() {
        let set = Set(SettingsCategory.allCases)
        XCTAssertEqual(set.count, 6)
    }

    func testCategoryIconsAreValidSystemImages() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.icon.isEmpty)
        }
    }

    func testCategoryFocusStateTracking() {
        var activeCategory: SettingsCategory? = .playback
        XCTAssertTrue(SettingsFocusReducer.shouldConsumeBack(selectedCategory: activeCategory))

        // Simulate back button press
        let restoreTarget = SettingsFocusReducer.restoredFocusTarget(afterExiting: activeCategory!)
        activeCategory = SettingsFocusReducer.categoryAfterBack(selectedCategory: activeCategory)

        XCTAssertNil(activeCategory)
        XCTAssertEqual(restoreTarget, .playback)
        XCTAssertFalse(SettingsFocusReducer.shouldConsumeBack(selectedCategory: activeCategory))
    }

    func testSourcesCategoryProvidesNoDirectMutation() {
        let category = SettingsCategory.sources
        XCTAssertEqual(category.title, "媒体来源")
        XCTAssertTrue(category.subtitle.contains("网盘管理"))
    }
}
