import Darwin
import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

enum LocalVaultEnumerationError: Error, Equatable, Sendable {
    case invalidRoot
    case unavailableRoot
    case rootIsSymbolicLink
    case rootIsNotDirectory
    case unreadableDirectory
    case unreadableEntry
    case invalidEntryPath
}

struct LocalVaultEnumerator {
    private static let excludedDirectoryNames: Set<String> = [
        ".bearobs",
        ".obsidian",
        ".trash",
    ]

    func enumerateMarkdown(
        at root: URL,
        visit: (VaultPath) throws -> Void
    ) throws {
        let descriptor = try openRoot(root)
        defer { _ = Darwin.close(descriptor) }
        try enumerateDirectory(descriptor, components: [], visit: visit)
    }

    private func openRoot(_ root: URL) throws -> Int32 {
        guard root.isFileURL else {
            throw LocalVaultEnumerationError.invalidRoot
        }
        var information = stat()
        guard lstat(root.path, &information) == 0 else {
            throw LocalVaultEnumerationError.unavailableRoot
        }
        guard fileType(of: information) != S_IFLNK else {
            throw LocalVaultEnumerationError.rootIsSymbolicLink
        }
        guard fileType(of: information) == S_IFDIR else {
            throw LocalVaultEnumerationError.rootIsNotDirectory
        }
        let descriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw LocalVaultEnumerationError.unavailableRoot
        }
        return descriptor
    }

    private func enumerateDirectory(
        _ descriptor: Int32,
        components: [String],
        visit: (VaultPath) throws -> Void
    ) throws {
        for name in try entryNames(in: descriptor) {
            try Task.checkCancellation()
            let entryComponents = components + [name]
            switch try classify(name, in: descriptor, components: entryComponents) {
            case .ignored:
                continue
            case .directory:
                try enumerateChildDirectory(
                    named: name,
                    in: descriptor,
                    components: entryComponents,
                    visit: visit
                )
            case .markdown(let path):
                try visit(path)
            }
        }
    }

    private func enumerateChildDirectory(
        named name: String,
        in parent: Int32,
        components: [String],
        visit: (VaultPath) throws -> Void
    ) throws {
        let child = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
            throw LocalVaultEnumerationError.unreadableDirectory
        }
        defer { _ = Darwin.close(child) }
        try enumerateDirectory(child, components: components, visit: visit)
    }

    private func entryNames(in descriptor: Int32) throws -> [String] {
        let duplicate = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0 else {
            throw LocalVaultEnumerationError.unreadableDirectory
        }
        guard let directory = fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw LocalVaultEnumerationError.unreadableDirectory
        }
        defer { _ = closedir(directory) }

        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw LocalVaultEnumerationError.unreadableDirectory
                }
                return names.sorted { canonicalName($0) < canonicalName($1) }
            }
            guard let name = decodedName(entry) else {
                throw LocalVaultEnumerationError.invalidEntryPath
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
    }

    private func decodedName(_ entry: UnsafeMutablePointer<dirent>) -> String? {
        withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(validatingCString: $0)
            }
        }
    }

    private func classify(
        _ name: String,
        in directory: Int32,
        components: [String]
    ) throws -> EntryKind {
        var information = stat()
        guard
            fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0
        else {
            throw LocalVaultEnumerationError.unreadableEntry
        }
        switch fileType(of: information) {
        case S_IFLNK:
            return .ignored
        case S_IFDIR:
            return Self.excludedDirectoryNames.contains(name.lowercased())
                ? .ignored : .directory
        case S_IFREG where URL(fileURLWithPath: name).pathExtension.lowercased() == "md":
            return try markdownPath(components)
        default:
            return .ignored
        }
    }

    private func markdownPath(_ components: [String]) throws -> EntryKind {
        do {
            return .markdown(
                try VaultPath(
                    decodedRelativePath: components.joined(separator: "/")
                )
            )
        } catch {
            throw LocalVaultEnumerationError.invalidEntryPath
        }
    }

    private func fileType(of information: stat) -> mode_t {
        information.st_mode & S_IFMT
    }

    private func canonicalName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }
}

extension LocalVaultEnumerator {
    private enum EntryKind {
        case ignored
        case directory
        case markdown(VaultPath)
    }
}
