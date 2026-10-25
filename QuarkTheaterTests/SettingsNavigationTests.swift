import XCTest
@testable import QuarkTheater

final class SettingsNavigationTests: XCTestCase {
    func testAllSettingsCategoriesArePresentAndUnique() {
        let categories = SettingsCategory.allCases
        XCTAssertEqual(categories.count, 6)
        XCTAssertEqual(Set(categories).count, 6)
        XCTAssertEqual(categories, [.sources, .playback, .scraper, .dataCache, .diagnostics, .about])
    }

    func testCategoryMetadataIsNotEmpty() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.title.isEmpty, "Category \(category.rawValue) title must not be empty")
            XCTAssertFalse(category.subtitle.isEmpty, "Category \(category.rawValue) subtitle must not be empty")
            XCTAssertFalse(category.icon.isEmpty, "Category \(category.rawValue) icon must not be empty")
        }
    }

    func testSettingsFocusReducerConsumesBackOnlyWhenInDetail() {
        XCTAssertTrue(SettingsFocusReducer.shouldConsumeBack(selectedCategory: .playback))
        XCTAssertTrue(SettingsFocusReducer.shouldConsumeBack(selectedCategory: .sources))
        XCTAssertTrue(SettingsFocusReducer.shouldConsumeBack(selectedCategory: .diagnostics))
        XCTAssertFalse(SettingsFocusReducer.shouldConsumeBack(selectedCategory: nil))
    }

    func testSettingsFocusReducerResetsSelectedCategoryToNilOnBack() {
        for category in SettingsCategory.allCases {
            XCTAssertNil(SettingsFocusReducer.categoryAfterBack(selectedCategory: category))
        }
        XCTAssertNil(SettingsFocusReducer.categoryAfterBack(selectedCategory: nil))
    }

    func testSettingsFocusReducerRestoresFocusToExitedCategory() {
        for category in SettingsCategory.allCases {
            let restored = SettingsFocusReducer.restoredFocusTarget(afterExiting: category)
            XCTAssertEqual(restored, category, "Exiting \(category) must restore focus back to \(category)")
        }
    }

    func testLegacySettingsKeysPreservation() {
        let defaults = UserDefaults.standard
        let originalLanguage = defaults.string(forKey: "scraperLanguage")
        let originalAutoPlay = defaults.object(forKey: "autoPlayNextEpisode") as? Bool
        let originalSeek = defaults.object(forKey: PlayerSeekPreference.key)

        defer {
            defaults.setValue(originalLanguage, forKey: "scraperLanguage")
            if let originalAutoPlay {
                defaults.set(originalAutoPlay, forKey: "autoPlayNextEpisode")
            } else {
                defaults.removeObject(forKey: "autoPlayNextEpisode")
            }
            if let originalSeek {
                defaults.setValue(originalSeek, forKey: PlayerSeekPreference.key)
            } else {
                defaults.removeObject(forKey: PlayerSeekPreference.key)
            }
        }

        defaults.set("en-US", forKey: "scraperLanguage")
        defaults.set(false, forKey: "autoPlayNextEpisode")
        defaults.set(15, forKey: PlayerSeekPreference.key)

        XCTAssertEqual(defaults.string(forKey: "scraperLanguage"), "en-US")
        XCTAssertEqual(defaults.bool(forKey: "autoPlayNextEpisode"), false)
        XCTAssertEqual(PlayerSeekPreference.current, 15)
    }
}
