import Foundation

final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private var files: [CloudFile] = []
    private var currentElement = ""
    private var currentText = ""

    private var currentHref: String = ""
    private var currentDisplayName: String?
    private var currentContentLength: Int64 = 0
    private var currentLastModified: Date?
    private var isCurrentCollection = false
    private var insideResourceType = false

    private var targetBasePath: String = ""

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return df
    }()

    func parse(xmlData: Data, basePath: String) throws -> [CloudFile] {
        files = []
        targetBasePath = normalizePath(basePath)

        let parser = XMLParser(data: xmlData)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            if let error = parser.parserError {
                throw error
            }
            throw QuarkError.invalidResponse("无法解析 WebDAV XML 响应")
        }
        return files
    }

    private func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.hasPrefix("/") { p = "/" + p }
        if p.hasSuffix("/") && p.count > 1 { p = String(p.dropLast()) }
        return p
    }

    // MARK: - XMLParserDelegate
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let tag = elementName.lowercased()
        currentElement = tag
        currentText = ""

        if tag == "response" {
            currentHref = ""
            currentDisplayName = nil
            currentContentLength = 0
            currentLastModified = nil
            isCurrentCollection = false
            insideResourceType = false
        } else if tag == "resourcetype" {
            insideResourceType = true
        } else if insideResourceType && tag == "collection" {
            isCurrentCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if tag == "href" {
            currentHref = trimmed.removingPercentEncoding ?? trimmed
        } else if tag == "displayname" {
            if !trimmed.isEmpty { currentDisplayName = trimmed }
        } else if tag == "getcontentlength" {
            currentContentLength = Int64(trimmed) ?? 0
        } else if tag == "getlastmodified" {
            currentLastModified = Self.dateFormatter.date(from: trimmed)
        } else if tag == "resourcetype" {
            insideResourceType = false
        } else if tag == "response" {
            finishCurrentResponse()
        }
    }

    private func finishCurrentResponse() {
        guard !currentHref.isEmpty else { return }
        let normalizedHref = normalizePath(currentHref)

        // Exclude the requested folder itself
        if normalizedHref == targetBasePath || normalizedHref.isEmpty {
            return
        }

        // Determine item name
        let name: String
        if let currentDisplayName, !currentDisplayName.isEmpty {
            name = currentDisplayName
        } else {
            let components = normalizedHref.split(separator: "/")
            name = components.last.map(String.init) ?? normalizedHref
        }

        let ext = isCurrentCollection ? "" : (name as NSString).pathExtension.lowercased()

        let file = CloudFile(
            fileId: currentHref,
            parentId: targetBasePath,
            name: name,
            size: currentContentLength,
            fileExtension: ext,
            modifiedAt: currentLastModified,
            isDirectory: isCurrentCollection
        )
        files.append(file)
    }
}
