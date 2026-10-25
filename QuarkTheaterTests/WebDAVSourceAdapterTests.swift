import XCTest
@testable import QuarkTheater

@MainActor
final class WebDAVSourceAdapterTests: XCTestCase {
    let samplePropfindXML = """
    <?xml version="1.0" encoding="utf-8" ?>
    <D:multistatus xmlns:D="DAV:">
        <D:response>
            <D:href>/dav/media/</D:href>
            <D:propstat>
                <D:prop>
                    <D:resourcetype><D:collection/></D:resourcetype>
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
        </D:response>
        <D:response>
            <D:href>/dav/media/Inception.2010.1080p.mkv</D:href>
            <D:propstat>
                <D:prop>
                    <D:displayname>Inception.2010.1080p.mkv</D:displayname>
                    <D:getcontentlength>3221225472</D:getcontentlength>
                    <D:getlastmodified>Sun, 20 Oct 2024 12:00:00 GMT</D:getlastmodified>
                    <D:resourcetype/>
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
        </D:response>
        <D:response>
            <D:href>/dav/media/Movies/</D:href>
            <D:propstat>
                <D:prop>
                    <D:displayname>Movies</D:displayname>
                    <D:resourcetype><D:collection/></D:resourcetype>
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
        </D:response>
    </D:multistatus>
    """

    func testParsePropfindXML() throws {
        let parser = WebDAVXMLParser()
        let items = try parser.parse(xmlData: Data(samplePropfindXML.utf8), basePath: "/dav/media/")

        XCTAssertEqual(items.count, 2, "Root folder itself should be excluded from listing")

        let video = try XCTUnwrap(items.first(where: { !$0.isDirectory }))
        XCTAssertEqual(video.name, "Inception.2010.1080p.mkv")
        XCTAssertEqual(video.size, 3221225472)
        XCTAssertTrue(video.isVideo)
        XCTAssertEqual(video.fileExtension, "mkv")

        let folder = try XCTUnwrap(items.first(where: { $0.isDirectory }))
        XCTAssertEqual(folder.name, "Movies")
        XCTAssertTrue(folder.isDirectory)
        XCTAssertFalse(folder.isVideo)
    }

    func testHTTPSSecurityCheck() {
        XCTAssertFalse(WebDAVSourceAdapter.isPlaintextHTTP(url: "https://nas.local:5005/dav"))
        XCTAssertTrue(WebDAVSourceAdapter.isPlaintextHTTP(url: "http://192.168.1.10:8080/dav"))
    }

    func testBasicAuthHeaderGeneration() {
        let header = WebDAVSourceAdapter.makeBasicAuthHeader(username: "admin", password: "password123")
        XCTAssertNotNil(header)
        XCTAssertTrue(header?.starts(with: "Basic ") == true)

        let base64 = String(header!.dropFirst("Basic ".count))
        let decodedData = Data(base64Encoded: base64)
        XCTAssertNotNil(decodedData)
        let credentials = String(data: decodedData!, encoding: .utf8)
        XCTAssertEqual(credentials, "admin:password123")
    }
}
