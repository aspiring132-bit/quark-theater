import Foundation

enum FolderBindingValidationResult: Equatable {
    case valid
    case duplicate
    case childOfExisting(parent: String)
    case parentOfExisting(child: String)

    var errorMessage: String? {
        switch self {
        case .valid:
            return nil
        case .duplicate:
            return "该目录已在绑定列表中，请勿重复添加。"
        case .childOfExisting(let parent):
            return "上级目录 [\(parent)] 已绑定，扫描会自动覆盖本目录，无需重复绑定。"
        case .parentOfExisting(let child):
            return "下级子目录 [\(child)] 已绑定，绑定当前上级目录会造成嵌套重复扫描，请先解绑下级目录。"
        }
    }
}

enum FolderBindingValidator {
    static func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.hasSuffix("/") && p.count > 1 {
            p = String(p.dropLast())
        }
        return p
    }

    static func isDuplicate(newPath: String, existingPaths: [String]) -> Bool {
        let norm = normalizePath(newPath)
        return existingPaths.map(normalizePath).contains(norm)
    }

    static func hasOverlap(newPath: String, existingPaths: [String]) -> Bool {
        validate(newPath: newPath, existingPaths: existingPaths) != .valid
    }

    static func validate(newPath: String, existingPaths: [String]) -> FolderBindingValidationResult {
        let normNew = normalizePath(newPath)
        let normExisting = existingPaths.map(normalizePath)

        for existing in normExisting {
            if normNew == existing {
                return .duplicate
            }

            // If existing is root "/", everything non-root is a child of existing
            if existing == "/" {
                return .childOfExisting(parent: "/")
            }

            // If new is root "/", it is parent of all existing
            if normNew == "/" {
                return .parentOfExisting(child: existing)
            }

            // Check if normNew is a descendant of existing (e.g. /Media/Movies/Action is child of /Media/Movies)
            let existingWithSlash = existing + "/"
            if normNew.hasPrefix(existingWithSlash) {
                return .childOfExisting(parent: existing)
            }

            // Check if existing is a descendant of normNew (e.g. /Media is parent of /Media/Movies)
            let newWithSlash = normNew + "/"
            if existing.hasPrefix(newWithSlash) {
                return .parentOfExisting(child: existing)
            }
        }

        return .valid
    }
}
