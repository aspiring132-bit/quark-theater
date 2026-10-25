import XCTest
@testable import QuarkTheater

final class FolderBindingLogicTests: XCTestCase {
    func testPathNormalization() {
        XCTAssertEqual(FolderBindingValidator.normalizePath("/Movies/"), "/Movies")
        XCTAssertEqual(FolderBindingValidator.normalizePath("Movies"), "/Movies")
        XCTAssertEqual(FolderBindingValidator.normalizePath("/"), "/")
        XCTAssertEqual(FolderBindingValidator.normalizePath(""), "/")
    }

    func testDetectExactDuplicate() {
        let existing = ["/Movies", "/TVShows"]
        XCTAssertTrue(FolderBindingValidator.isDuplicate(newPath: "/Movies", existingPaths: existing))
        XCTAssertTrue(FolderBindingValidator.isDuplicate(newPath: "/Movies/", existingPaths: existing))
        XCTAssertFalse(FolderBindingValidator.isDuplicate(newPath: "/Anime", existingPaths: existing))
    }

    func testDetectParentChildOverlap() {
        let existing = ["/Media/Movies"]

        // Descendant of existing path
        XCTAssertTrue(FolderBindingValidator.hasOverlap(newPath: "/Media/Movies/Action", existingPaths: existing))

        // Ancestor of existing path
        XCTAssertTrue(FolderBindingValidator.hasOverlap(newPath: "/Media", existingPaths: existing))

        // Exact match
        XCTAssertTrue(FolderBindingValidator.hasOverlap(newPath: "/Media/Movies", existingPaths: existing))

        // Sibling (no overlap)
        XCTAssertFalse(FolderBindingValidator.hasOverlap(newPath: "/Media/TVShows", existingPaths: existing))
        XCTAssertFalse(FolderBindingValidator.hasOverlap(newPath: "/Media/Movies_2024", existingPaths: existing))
    }

    func testValidationFailureReasons() {
        let existing = ["/Movies"]

        let duplicateResult = FolderBindingValidator.validate(newPath: "/Movies", existingPaths: existing)
        XCTAssertEqual(duplicateResult, .duplicate)

        let childResult = FolderBindingValidator.validate(newPath: "/Movies/SciFi", existingPaths: existing)
        if case .childOfExisting(let parent) = childResult {
            XCTAssertEqual(parent, "/Movies")
        } else {
            XCTFail("Expected .childOfExisting")
        }

        let parentResult = FolderBindingValidator.validate(newPath: "/", existingPaths: existing)
        if case .parentOfExisting(let child) = parentResult {
            XCTAssertEqual(child, "/Movies")
        } else {
            XCTFail("Expected .parentOfExisting")
        }

        let validResult = FolderBindingValidator.validate(newPath: "/TV", existingPaths: existing)
        XCTAssertEqual(validResult, .valid)
    }
}
