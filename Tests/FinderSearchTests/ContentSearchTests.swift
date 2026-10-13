import XCTest
@testable import FinderSearch

final class ContentSearchTests: XCTestCase {
    /// The reply line the daemon writes for `{"op":"grep",...}` or a query
    /// carrying a content operator, recorded from `fsearch stdio`.
    func testGrepReplyDecodesDaemonShape() throws {
        let json = """
            {"candidates":92,"complete":false,"files":[\
            {"git":"M","matches":[\
            {"after":["","next line"],"before":["prev line",""],"col":148,"line":3,"ranges":[[148,164],[169,185]],"text":"Every time [ROUTING-STRATEGY.md] matters"},\
            {"col":4,"def":true,"line":21,"ranges":[[4,20]],"text":"func apply_dir() {}"}\
            ],"path":"/tmp/docs/ROUTING-ASKS.md"},\
            {"matches":[{"col":0,"line":9,"ranges":[],"text":"plain"}],"path":"/tmp/LOG.md"}\
            ],"id":null,"indexing":3,"next":33,"ok":true,"read":42,"source":"scan","took_us":12326}
            """
        let reply = try JSONDecoder().decode(GrepReply.self, from: Data(json.utf8))
        XCTAssertTrue(reply.ok)
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.took_us, 12326)
        XCTAssertEqual(reply.source, "scan")
        XCTAssertEqual(reply.candidates, 92)
        XCTAssertEqual(reply.read, 42)
        XCTAssertEqual(reply.complete, false)
        XCTAssertEqual(reply.indexing, 3)
        XCTAssertEqual(reply.next, 33)
        let files = try XCTUnwrap(reply.files)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "/tmp/docs/ROUTING-ASKS.md")
        XCTAssertEqual(files[0].name, "ROUTING-ASKS.md")
        let match = files[0].matches[0]
        XCTAssertEqual(match.line, 3)
        XCTAssertEqual(match.col, 148)
        XCTAssertEqual(match.ranges, [[148, 164], [169, 185]])
        XCTAssertEqual(match.before, ["prev line", ""])
        XCTAssertEqual(match.after, ["", "next line"])
        XCTAssertNil(match.def)
        XCTAssertEqual(files[0].matches[1].def, true)
        XCTAssertNil(files[1].matches[0].before)
    }

    @MainActor func testContentOperatorInQueryRoutesToGrep() async throws {
        let engine = ContentSearchEngine()
        let model = SearchModel(engine: engine, searchDebounce: .milliseconds(1))
        model.query = "grep:apply_dir"
        await engine.waitForGreps(1)
        let last = await engine.lastGrep()
        let fields = try XCTUnwrap(last)
        XCTAssertEqual(fields["q"] as? String, "grep:apply_dir")
        XCTAssertNil(fields["op"])
        XCTAssertNil(fields["pattern"])
        XCTAssertTrue(model.isContentSearch)
        for _ in 0..<100 where model.searching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.contentFiles.map(\.path), ["/fixture/a.swift"])
        XCTAssertEqual(model.hits.map(\.path), ["/fixture/a.swift"])
    }

    @MainActor func testContentsModeSendsExplicitGrepRequest() async throws {
        let engine = ContentSearchEngine()
        let model = SearchModel(engine: engine, searchDebounce: .milliseconds(1))
        model.setContentSearch(true)
        model.query = "apply_dir handler"
        await engine.waitForGreps(1)
        let last = await engine.lastGrep()
        let fields = try XCTUnwrap(last)
        // A phrase must stay one pattern; the `q` form would split it.
        XCTAssertEqual(fields["op"] as? String, "grep")
        XCTAssertEqual(fields["pattern"] as? String, "apply_dir handler")
        XCTAssertEqual(fields["mode"] as? String, "literal")
        XCTAssertNil(fields["q"])
        XCTAssertTrue(model.isContentSearch)
    }

    @MainActor func testFolderScopeAppliesToContentSearch() async throws {
        let engine = ContentSearchEngine()
        let model = SearchModel(engine: engine, searchDebounce: .milliseconds(1))
        model.scope = "/tmp/scoped"
        model.query = "grep:apply_dir"
        await engine.waitForGreps(1)
        let last = await engine.lastGrep()
        let fields = try XCTUnwrap(last)
        XCTAssertEqual(fields["in"] as? String, "/tmp/scoped")
    }

    @MainActor func testSelectingNamesStripsOperatorAndRunsNameSearch() async throws {
        let engine = ContentSearchEngine()
        let model = SearchModel(engine: engine, searchDebounce: .milliseconds(1))
        model.query = "report grep:TODO"
        await engine.waitForGreps(1)
        model.setContentSearch(false)
        XCTAssertEqual(model.query, "report TODO")
        XCTAssertFalse(model.isContentSearch)
        await engine.waitForRequests(1)
        let last = await engine.lastName()
        let fields = try XCTUnwrap(last)
        XCTAssertEqual(fields["q"] as? String, "report TODO")
        XCTAssertNil(fields["op"])
    }

    @MainActor func testGrepErrorSurfaces() async throws {
        let engine = ContentSearchEngine(failing: true)
        let model = SearchModel(engine: engine, searchDebounce: .milliseconds(1))
        model.query = "grep:boom"
        await engine.waitForGreps(1)
        for _ in 0..<100 where model.searching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.error, "Search failed")
        XCTAssertTrue(model.contentFiles.isEmpty)
        XCTAssertFalse(model.searching)
    }

    @MainActor func testIsContentQuery() {
        for query in [
            "grep:foo", "report grep:TODO", "regex:fn\\s+\\w+", "sym:apply_dir", "content:x",
            "symbol:x",
        ] {
            XCTAssertTrue(SearchModel.isContentQuery(query), query)
        }
        for query in ["report", "ext:rs kind:dir", "summaries", "symlink"] {
            XCTAssertFalse(SearchModel.isContentQuery(query), query)
        }
    }

    @MainActor func testStrippingContentOperators() {
        XCTAssertEqual(SearchModel.strippingContentOperators("grep:foo"), "foo")
        XCTAssertEqual(SearchModel.strippingContentOperators("report grep:TODO"), "report TODO")
        XCTAssertEqual(
            SearchModel.strippingContentOperators("regex:fn\\s+\\w+ ext:rs"),
            "fn\\s+\\w+ ext:rs")
        XCTAssertEqual(SearchModel.strippingContentOperators("sym:apply_dir"), "apply_dir")
        XCTAssertEqual(
            SearchModel.strippingContentOperators("!grep:foo"), "!foo")
    }
}

private actor ContentSearchEngine: SearchService {
    var nameRequests: [[String: Any]] = []
    var grepRequests: [[String: Any]] = []
    let failing: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitingNames = 0
    private var waitingGreps = 0

    init(failing: Bool = false) { self.failing = failing }

    func request(_ fields: [String: Any]) async throws -> Reply {
        nameRequests.append(fields)
        ping()
        return Reply(
            ok: true, error: nil, hits: [], took_us: 1, entries: nil, full_disk_access: nil)
    }

    func grep(_ fields: [String: Any]) async throws -> GrepReply {
        grepRequests.append(fields)
        ping()
        if failing {
            return GrepReply(
                ok: false, error: nil, files: nil, took_us: nil, source: nil, candidates: nil,
                read: nil, complete: nil, indexing: nil, next: nil)
        }
        return GrepReply(
            ok: true, error: nil,
            files: [
                GrepFile(
                    path: "/fixture/a.swift",
                    matches: [
                        GrepMatch(line: 7, text: "let apply_dir = true", col: 4,
                                  ranges: [[4, 13]]),
                        GrepMatch(line: 9, text: "return apply_dir", col: 10,
                                  ranges: [[10, 19]]),
                    ])
            ],
            took_us: 5, source: "index", candidates: 1, read: 1, complete: true,
            indexing: 0, next: nil)
    }

    func lastGrep() -> [String: Any]? { grepRequests.last }
    func lastName() -> [String: Any]? { nameRequests.last }

    func waitForRequests(_ count: Int) async {
        guard nameRequests.count < count else { return }
        await withCheckedContinuation {
            waiter = $0; waitingNames = count
        }
    }

    func waitForGreps(_ count: Int) async {
        guard grepRequests.count < count else { return }
        await withCheckedContinuation {
            waiter = $0; waitingGreps = count
        }
    }

    private func ping() {
        guard let waiter else { return }
        if nameRequests.count >= waitingNames, grepRequests.count >= waitingGreps {
            self.waiter = nil; waitingNames = 0; waitingGreps = 0
            waiter.resume()
        }
    }
}
