import XCTest
@testable import FinderSearch

final class SearchPagingTests: XCTestCase {
    @MainActor func testShowMoreFetchesNextPageAndAppendsWithoutDuplicates() async throws {
        let engine = PagedSearchEngine(total: 5, page: 2)
        let model = SearchModel(engine: engine, searchDebounce: .zero)
        model.query = "agents"
        model.submitSearch()
        try await waitUntil { !model.searching && model.hits.count == 2 }
        XCTAssertEqual(model.moreResultsOffset, 2)

        model.loadMoreResults()
        try await waitUntil { !model.loadingMore && model.hits.count == 4 }
        XCTAssertEqual(model.moreResultsOffset, 4)

        model.loadMoreResults()
        try await waitUntil { !model.loadingMore && model.hits.count == 5 }
        XCTAssertNil(model.moreResultsOffset, "last page has no next offset")
        XCTAssertEqual(Set(model.hits.map(\.path)).count, 5)

        let requests = await engine.requests
        XCTAssertEqual(requests.map(\.offset), [0, 2, 4])
        XCTAssertEqual(requests.first?.limit, SearchModel.searchPageSize)
        XCTAssertEqual(requests.dropFirst().map(\.limit), [SearchModel.morePageSize, SearchModel.morePageSize])
    }

    @MainActor func testNewQueryDropsPendingNextPage() async throws {
        let engine = PagedSearchEngine(total: 5, page: 2)
        let model = SearchModel(engine: engine, searchDebounce: .zero)
        model.query = "agents"
        model.submitSearch()
        try await waitUntil { !model.searching && model.moreResultsOffset == 2 }
        model.query = ""
        XCTAssertNil(model.moreResultsOffset)
    }

    @MainActor func testSortChangeWhilePageLoadsKeepsNewOrder() async throws {
        let engine = PagedSearchEngine(total: 6, page: 3, holdSecondPage: true)
        let model = SearchModel(engine: engine, searchDebounce: .zero)
        model.sort = .name; model.ascending = true
        model.query = "agents"
        model.submitSearch()
        try await waitUntil { !model.searching && model.moreResultsOffset == 3 }
        model.loadMoreResults()
        for _ in 0..<200 {
            if await engine.requests.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.ascending = false
        await engine.releaseHeld()
        try await waitUntil { !model.loadingMore && model.hits.count == 6 && !model.sorting }
        let names = model.sortedHits.map(\.name)
        XCTAssertEqual(names, names.sorted(by: >), "rows follow the sort chosen mid-page")
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not met")
    }
}

/// Answers like the daemon: `offset` pages through `total` hits `limit` (capped
/// at `page`) at a time and says where the next page starts.
private actor PagedSearchEngine: SearchService {
    let total: Int, page: Int, holdSecondPage: Bool
    var requests: [(offset: Int, limit: Int)] = []
    private var held: CheckedContinuation<Void, Never>?
    init(total: Int, page: Int, holdSecondPage: Bool = false) {
        (self.total, self.page, self.holdSecondPage) = (total, page, holdSecondPage)
    }

    func releaseHeld() { held?.resume(); held = nil }

    func request(_ fields: [String: Any]) async throws -> Reply {
        let offset = fields["offset"] as? Int ?? 0, limit = fields["limit"] as? Int ?? 50
        requests.append((offset, limit))
        if holdSecondPage && requests.count == 2 { await withCheckedContinuation { held = $0 } }
        let end = min(total, offset + min(limit, page))
        let hits = (offset..<max(offset, end)).map {
            Hit(path: "/fixture/agents-\($0).md", kind: "file", size: 1, mtime: 1, score: 1)
        }
        return Reply(
            ok: true, error: nil, hits: hits, took_us: 1, entries: nil, full_disk_access: nil,
            next: end < total ? end : nil)
    }
}
