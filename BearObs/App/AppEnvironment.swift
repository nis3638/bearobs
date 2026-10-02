import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsLibrary
    import BearObsLocalVault
    import BearObsUserState
#endif

enum AppEnvironmentError: Error, Sendable {
    case applicationSupportUnavailable
    case unavailable
    case vaultNotSelected
    case invalidSelectedVault
}

@MainActor
struct AppEnvironment {
    let libraryModel: LibraryFeatureModel
    let tagsModel: TagsFeatureModel
    let searchModel: SearchFeatureModel
    let recentModel: SearchFeatureModel
    let favoritesModel: FavoritesFeatureModel
    let readerSource: ReaderDataSource
    let editorSource: EditorDataSource?
    let vaultID: UUID?
    let vaultURL: URL?
    private let vaultScope: VaultScope?

    static func live() throws -> AppEnvironment {
        let directories = try AppDirectories.makeLive()
        let selectionStore = try VaultSelectionStore(directory: directories.root)
        guard let selection = try selectionStore.load() else {
            throw AppEnvironmentError.vaultNotSelected
        }

        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try selection.resolve()
        } catch {
            throw AppEnvironmentError.invalidSelectedVault
        }
        let currentSelection: VaultSelection
        if resolved.isStale {
            let refreshed = try VaultSelection.make(for: resolved.url)
            currentSelection = VaultSelection(
                id: selection.id,
                bookmarkData: refreshed.bookmarkData
            )
            try selectionStore.save(currentSelection)
        } else {
            currentSelection = selection
        }
        return try make(
            root: resolved.url,
            selection: currentSelection,
            directories: directories
        )
    }

    static func make(
        root: URL,
        selection: VaultSelection,
        directories: AppDirectories
    ) throws -> AppEnvironment {
        let scope = VaultScope(url: root)
        let metadata = try directories.metadata(for: selection.id)
        let repository = try SQLiteIndexRepository(
            path: metadata.appendingPathComponent("index.sqlite").path
        )
        let scanner = try IncrementalIndexScanner(
            root: root,
            repository: repository
        )
        let indexReadiness = IndexReadiness(scanner: scanner)
        let vault = try LocalVaultStore(root: root)
        let userState = try FileUserStateStore(metadataDirectory: metadata)

        let librarySource = LibraryDataSource(
            load: {
                try await indexReadiness.ensureReady()
                return try await repository.libraryNotes()
            },
            refresh: {
                try await indexReadiness.refresh()
            }
        )
        let tagSource = TagLibraryDataSource(
            loadTags: {
                try await indexReadiness.ensureReady()
                return try await repository.libraryTags()
            },
            loadNotes: { tag in
                try await indexReadiness.ensureReady()
                return try await repository.libraryNotes(taggedWith: tag)
            }
        )
        let searchSource = SearchDataSource { query in
            try await indexReadiness.ensureReady()
            return try await repository.search(query)
        }
        let favoriteSource = FavoriteDataSource(
            loadNotes: {
                try await indexReadiness.ensureReady()
                return try await repository.libraryNotes()
            },
            loadFavoritePaths: { try await userState.favoritePaths() },
            setFavorite: { path, isFavorite in
                try await userState.setFavorite(path, isFavorite: isFavorite)
            }
        )
        let favoritesModel = FavoritesFeatureModel(source: favoriteSource)
        let libraryModel = LibraryFeatureModel(source: librarySource)
        let tagsModel = TagsFeatureModel(source: tagSource)
        let searchModel = SearchFeatureModel(source: searchSource)
        let recentModel = SearchFeatureModel(source: searchSource)
        // Recorded platform seam (REQ-004 §7, ADR-010): the iOS app is
        // read-only and never receives an editing source, so its reader is
        // constructed with `editorSource == nil` and the editing UI stays
        // compiled out (see ReaderView / ReaderInlineEditor).
        #if os(macOS)
            let editorSource: EditorDataSource? = EditorDataSource.localVault(vault) { path in
                try await indexReadiness.refresh(path)
                async let library: Void = libraryModel.load()
                async let tags: Void = tagsModel.load()
                async let favorites: Void = favoritesModel.reload()
                async let recent: Void = recentModel.search("")
                let query = await searchModel.query
                async let search: Void = searchModel.search(query)
                _ = await (library, tags, favorites, recent, search)
            }
        #else
            let editorSource: EditorDataSource? = nil
        #endif

        return AppEnvironment(
            libraryModel: libraryModel,
            tagsModel: tagsModel,
            searchModel: searchModel,
            recentModel: recentModel,
            favoritesModel: favoritesModel,
            readerSource: .localVault(
                vault,
                wikiLinks: .index(repository)
            ),
            editorSource: editorSource,
            vaultID: selection.id,
            vaultURL: root,
            vaultScope: scope
        )
    }

    static let unavailable = AppEnvironment(
        libraryModel: LibraryFeatureModel(
            source: LibraryDataSource(
                load: { throw AppEnvironmentError.unavailable },
                refresh: { throw AppEnvironmentError.unavailable }
            )
        ),
        tagsModel: TagsFeatureModel(
            source: TagLibraryDataSource(
                loadTags: { throw AppEnvironmentError.unavailable },
                loadNotes: { _ in throw AppEnvironmentError.unavailable }
            )
        ),
        searchModel: SearchFeatureModel(
            source: SearchDataSource { _ in throw AppEnvironmentError.unavailable }
        ),
        recentModel: SearchFeatureModel(
            source: SearchDataSource { _ in throw AppEnvironmentError.unavailable }
        ),
        favoritesModel: FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { throw AppEnvironmentError.unavailable },
                loadFavoritePaths: { throw AppEnvironmentError.unavailable },
                setFavorite: { _, _ in throw AppEnvironmentError.unavailable }
            )
        ),
        readerSource: .unavailable,
        editorSource: nil,
        vaultID: nil,
        vaultURL: nil,
        vaultScope: nil
    )
}

@MainActor
@Observable
final class AppWorkspaceModel {
    private(set) var environment: AppEnvironment
    private(set) var vaultURL: URL?
    private(set) var errorMessage: String?

    private let directories: AppDirectories?
    private let selectionStore: VaultSelectionStore?

    init() {
        let directories = try? AppDirectories.makeLive()
        self.directories = directories
        self.selectionStore = directories.flatMap { try? VaultSelectionStore(directory: $0.root) }
        if let environment = try? AppEnvironment.live() {
            self.environment = environment
            vaultURL = environment.vaultURL
        } else {
            environment = .unavailable
            vaultURL = nil
        }
        if let autoOpenVault {
            openVault(autoOpenVault)
        }
    }

    /// UI 测试通过该环境变量在启动时直接打开测试自建的临时 Vault，
    /// 不驱动打开面板，也不读取开发者机器上一次选择的 Vault（REQ-002 P6）。
    private var autoOpenVault: URL? {
        guard
            let raw = ProcessInfo.processInfo.environment[
                AppDirectories.autoOpenVaultEnvironmentKey
            ],
            !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    func openVault(_ root: URL) {
        errorMessage = nil
        guard let directories, let selectionStore else {
            errorMessage = "无法准备本地数据目录。"
            return
        }
        do {
            let selection = try VaultSelection.make(for: root)
            let nextEnvironment = try AppEnvironment.make(
                root: root,
                selection: selection,
                directories: directories
            )
            try selectionStore.save(selection)
            environment = nextEnvironment
            vaultURL = root
        } catch {
            errorMessage = "无法打开此 Vault，请确认它是可访问的文件夹。"
        }
    }
}

private final class VaultScope {
    let url: URL
    private let hasSecurityScopedAccess: Bool

    init(url: URL) {
        self.url = url
        hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScopedAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

private actor IndexReadiness {
    private let scanner: IncrementalIndexScanner
    private var isReady = false

    init(scanner: IncrementalIndexScanner) {
        self.scanner = scanner
    }

    func ensureReady() async throws {
        guard !isReady else { return }
        _ = try await scanner.scan()
        isReady = true
    }

    func refresh() async throws {
        _ = try await scanner.scan()
        isReady = true
    }

    func refresh(_ path: VaultPath) async throws {
        try await scanner.refresh(path)
        isReady = true
    }
}

struct AppDirectories {
    let root: URL
    let vaults: URL

    /// UI 测试通过该环境变量把全部本地状态重定向到临时目录，
    /// 不读取也不写入开发者机器上真实选择的 Vault。
    static let appSupportOverrideEnvironmentKey = "BEAROBS_APP_SUPPORT_ROOT"
    /// UI 测试通过该环境变量指定启动时直接打开的 Vault 目录。
    static let autoOpenVaultEnvironmentKey = "BEAROBS_AUTOPEN_VAULT"

    static func makeLive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppDirectories {
        let root: URL
        if let override = environment[Self.appSupportOverrideEnvironmentKey], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            guard
                let applicationSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            else {
                throw AppEnvironmentError.applicationSupportUnavailable
            }
            root = applicationSupport.appendingPathComponent("BearObs", isDirectory: true)
        }
        let vaults = root.appendingPathComponent("Vaults", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaults,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return AppDirectories(root: root, vaults: vaults)
    }

    func metadata(for id: UUID) throws -> URL {
        let metadata =
            vaults
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("Metadata", isDirectory: true)
        try FileManager.default.createDirectory(
            at: metadata,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return metadata
    }
}
