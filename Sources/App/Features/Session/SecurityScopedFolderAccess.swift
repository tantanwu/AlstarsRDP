import Foundation
import RDPDomain

enum SharedFolderAccessError: Error, LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(name):
            return String(format: NSLocalizedString("The shared folder “%@” is no longer available. Choose it again in the connection settings.", comment: "shared folder unavailable"), name)
        }
    }
}

final class SecurityScopedFolderAccess {
    let url: URL
    private let didStartAccess: Bool

    init(bookmark: SharedFolderBookmark) throws {
        var isStale = false
        do {
            url = try URL(
                resolvingBookmarkData: bookmark.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SharedFolderAccessError.unavailable(bookmark.displayName)
        }
        var isDirectory: ObjCBool = false
        guard !isStale,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SharedFolderAccessError.unavailable(bookmark.displayName)
        }
        didStartAccess = url.startAccessingSecurityScopedResource()
        guard didStartAccess else {
            throw SharedFolderAccessError.unavailable(bookmark.displayName)
        }
    }

    deinit {
        if didStartAccess { url.stopAccessingSecurityScopedResource() }
    }
}
