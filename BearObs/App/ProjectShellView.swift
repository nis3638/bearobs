import SwiftUI

#if SWIFT_PACKAGE
    import BearObsLibrary
#endif

struct ProjectShellView: View {
    private let libraryModel: LibraryFeatureModel
    private let tagsModel: TagsFeatureModel
    private let searchModel: SearchFeatureModel
    private let readerSource: ReaderDataSource

    init(
        libraryModel: LibraryFeatureModel = LibraryFeatureModel(source: .empty),
        tagsModel: TagsFeatureModel = TagsFeatureModel(source: .empty),
        searchModel: SearchFeatureModel = SearchFeatureModel(source: .empty),
        readerSource: ReaderDataSource = .unavailable
    ) {
        self.libraryModel = libraryModel
        self.tagsModel = tagsModel
        self.searchModel = searchModel
        self.readerSource = readerSource
    }

    var body: some View {
        TabView {
            Tab("笔记", systemImage: "doc.text") {
                LibraryView(model: libraryModel, readerSource: readerSource)
            }
            Tab("标签", systemImage: "number") {
                TagsView(model: tagsModel, readerSource: readerSource)
            }
            Tab("搜索", systemImage: "magnifyingglass") {
                SearchView(model: searchModel, readerSource: readerSource)
            }
        }
    }
}
