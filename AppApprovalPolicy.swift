import Foundation

/// An approved application includes helper apps physically bundled inside it.
/// Resolving paths prevents a symlink from granting access to an outside app.
struct AppApprovalPolicy {
    private let bundleIDs: Set<String>
    private let roots: [String]

    init(approvedPaths: [String], bundleIDs: Set<String>) {
        self.bundleIDs = bundleIDs
        roots = approvedPaths.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    func allows(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        if let bundleIdentifier, bundleIDs.contains(bundleIdentifier) { return true }
        guard let bundleURL, bundleURL.pathExtension.lowercased() == "app" else { return false }
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
