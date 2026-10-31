import Defaults
import Foundation
import Testing
@testable import HelioKit

@MainActor
@Suite(.serialized)
struct FeedItemsManagerTests {
  /// `PostData`'s ids are constants, so re-key the sample post through its Codable form.
  private func post(_ id: String, read: Bool) -> RedditEntityType {
    var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(postSampleData)) as! [String: Any]
    json["id"] = id
    json["name"] = "t3_\(id)"
    var data = try! JSONDecoder().decode(PostData.self, from: JSONSerialization.data(withJSONObject: json))
    data.helioSeen = read
    let post = Post(id: id)
    post.data = data
    return .post(post)
  }

  private func ids(_ entities: [RedditEntityType]) -> [String] {
    entities.compactMap {
      if case let .post(post) = $0 {
        post.data?.id
      } else {
        nil
      }
    }
  }

  private func makeManager(hideReadPosts: Bool, pages: [String: ([RedditEntityType], String?)]) -> (FeedItemsManager<SubListingSortOption>, () -> [String?]) {
    var requested: [String?] = []
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, hideReadPosts: hideReadPosts) { after, _, _, _, _ in
      requested.append(after)
      let page = pages[after ?? "first"] ?? ([], nil)
      return (page.0, page.1)
    }
    manager.chunkSize = 2
    return (manager, { requested })
  }

  private func withHideOnRead(_ enabled: Bool, _ body: () async -> Void) async {
    let previous = Defaults[.PostLinkDefSettings].hideOnRead
    Defaults[.PostLinkDefSettings].hideOnRead = enabled
    await body()
    Defaults[.PostLinkDefSettings].hideOnRead = previous
  }

  @Test func skipsPagesWhosePostsWereAllRead() async {
    await withHideOnRead(true) {
      let (manager, requested) = makeManager(hideReadPosts: true, pages: [
        "first": ([post("a", read: true), post("b", read: true)], "p2"),
        "p2": ([post("c", read: true), post("d", read: false)], "p3"),
      ])
      await manager.reload()

      #expect(requested() == [nil, "p2"])
      #expect(ids(manager.entities) == ["d"])
      #expect(manager.lastElementId == "p3")
      #expect(manager.displayMode == .items)
    }
  }

  @Test func keepsReadPostsWhenSettingIsOff() async {
    await withHideOnRead(false) {
      let (manager, requested) = makeManager(hideReadPosts: true, pages: [
        "first": ([post("a", read: true), post("b", read: false)], "p2"),
      ])
      await manager.reload()

      #expect(requested() == [nil])
      #expect(ids(manager.entities) == ["a", "b"])
    }
  }

  @Test func keepsReadPostsInFeedsThatDontHideThem() async {
    await withHideOnRead(true) {
      let (manager, _) = makeManager(hideReadPosts: false, pages: [
        "first": ([post("a", read: true), post("b", read: true)], "p2"),
      ])
      await manager.reload()

      #expect(ids(manager.entities) == ["a", "b"])
    }
  }

  @Test func offersToContinueAfterTooManyPagesOfReadPosts() async {
    await withHideOnRead(true) {
      var pages: [String: ([RedditEntityType], String?)] = [:]
      for i in 0 ..< 10 {
        pages[i == 0 ? "first" : "p\(i)"] = ([post("a\(i)", read: true), post("b\(i)", read: true)], "p\(i + 1)")
      }
      let (manager, requested) = makeManager(hideReadPosts: true, pages: pages)
      await manager.reload()

      #expect(requested().count == 6)
      #expect(manager.entities.isEmpty)
      #expect(manager.displayMode == .onlyReadPosts)

      // Continuing resumes from where the scan stopped.
      await manager.loadMore()
      #expect(requested()[6] == "p6")
    }
  }

  @Test func treatsAMissingCursorAsTheEndOfTheFeed() async {
    await withHideOnRead(false) {
      let (manager, _) = makeManager(hideReadPosts: false, pages: [
        "first": ([post("a", read: false), post("b", read: false)], nil),
      ])
      await manager.reload()

      #expect(manager.displayMode == .endOfFeed)
    }
  }

  @Test func showsEmptyFeedWhenEveryPostWasReadAndThereIsNoMore() async {
    await withHideOnRead(true) {
      let (manager, requested) = makeManager(hideReadPosts: true, pages: [
        "first": ([post("a", read: true)], nil),
      ])
      await manager.reload()

      #expect(requested() == [nil])
      #expect(manager.entities.isEmpty)
      #expect(manager.displayMode == .empty)
    }
  }

  @MainActor
  private final class ControlledFetch {
    typealias Page = (entities: [RedditEntityType]?, after: String?)?
    struct Request {
      let after: String?
      let query: String?
      let limit: Int
      let continuation: CheckedContinuation<Page, Never>
    }

    var requests: [Request] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func fetch(_ after: String?, _ sorting: SubListingSortOption?, _ query: String?, _ flair: String?, _ limit: Int) async -> Page {
      await withCheckedContinuation { continuation in
        requests.append(Request(after: after, query: query, limit: limit, continuation: continuation))
        let ready = waiters.filter { requests.count >= $0.count }
        waiters.removeAll { requests.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
      }
    }

    func waitForRequests(_ count: Int) async {
      if requests.count >= count {
        return
      }
      await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with page: Page) {
      requests[index].continuation.resume(returning: page)
    }
  }

  @Test(arguments: [false, true]) func newerRefreshOwnsTheFeedEvenWhenOlderFetchCompletes(fails: Bool) async {
    let fetch = ControlledFetch()
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, fetchFn: fetch.fetch)
    manager.chunkSize = 2
    let old = Task { await manager.reload() }
    await fetch.waitForRequests(1)
    let new = Task { await manager.reload() }
    await fetch.waitForRequests(2)
    fetch.complete(1, with: ([post("new", read: false)], nil))
    await new.value
    fetch.complete(0, with: fails ? nil : ([post("old", read: false)], "old-cursor"))
    await old.value

    #expect(ids(manager.entities) == ["new"])
    #expect(manager.lastElementId == nil)
    #expect(manager.displayMode == .endOfFeed)
  }

  @Test func supersededPageDoesNotAppendOrReleaseTheNewRefresh() async {
    let fetch = ControlledFetch()
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, fetchFn: fetch.fetch)
    manager.chunkSize = 2
    let first = Task { await manager.reload() }
    await fetch.waitForRequests(1)
    fetch.complete(0, with: ([post("a", read: false), post("b", read: false)], "p2"))
    await first.value
    let page = Task { await manager.loadMore() }
    await fetch.waitForRequests(2)
    let refresh = Task { await manager.reload() }
    await fetch.waitForRequests(3)
    fetch.complete(1, with: ([post("stale", read: false)], nil))
    await page.value

    // The stale page's cleanup must not let an appearing row start another request.
    manager.elementAppeared(entity: manager.entities[1])
    #expect(fetch.requests.count == 3)
    #expect(ids(manager.entities) == ["a", "b"])
    fetch.complete(2, with: ([post("fresh", read: false)], nil))
    await refresh.value
    #expect(ids(manager.entities) == ["fresh"])
  }

  @Test func appearingRowsReserveOnlyOnePageRequest() async {
    let fetch = ControlledFetch()
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, fetchFn: fetch.fetch)
    manager.chunkSize = 2
    let first = Task { await manager.reload() }
    await fetch.waitForRequests(1)
    fetch.complete(0, with: ([post("a", read: false), post("b", read: false)], "p2"))
    await first.value
    manager.elementAppeared(entity: manager.entities[0])
    manager.elementAppeared(entity: manager.entities[1])
    await fetch.waitForRequests(2)
    #expect(fetch.requests.count == 2)
    #expect(fetch.requests[1].after == "p2")
    fetch.complete(1, with: ([post("c", read: false)], nil))
    // Join the reserved request rather than sending another one.
    await manager.loadMore()
    #expect(ids(manager.entities) == ["a", "b", "c"])
  }

  @Test func cancelledCallerDoesNotStartARequest() async {
    let fetch = ControlledFetch()
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, fetchFn: fetch.fetch)
    let task = Task { await manager.reload() }
    task.cancel()
    await task.value
    #expect(fetch.requests.isEmpty)
  }

  @Test func hiddenPagesUseOneQuerySnapshot() async {
    await withHideOnRead(true) {
      let fetch = ControlledFetch()
      let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, hideReadPosts: true, fetchFn: fetch.fetch)
      manager.chunkSize = 2
      manager.searchQuery.setNow("original")
      let task = Task { await manager.reload() }
      await fetch.waitForRequests(1)
      manager.searchQuery.setNow("changed")
      fetch.complete(0, with: ([post("a", read: true), post("b", read: true)], "p2"))
      await fetch.waitForRequests(2)
      #expect(fetch.requests.map(\.query) == ["original", "original"])
      #expect(manager.isLoadingMore)
      fetch.complete(1, with: ([post("visible", read: false)], nil))
      await task.value
      #expect(ids(manager.entities) == ["visible"])
    }
  }

  @Test func hiddenPagesKeepTheirLimitUntilTheNextRequestChain() async {
    await withHideOnRead(true) {
      let fetch = ControlledFetch()
      let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, hideReadPosts: true, fetchFn: fetch.fetch)
      manager.chunkSize = 2
      let task = Task { await manager.reload() }
      await fetch.waitForRequests(1)
      manager.chunkSize = 1
      fetch.complete(0, with: ([post("a", read: true), post("b", read: true)], "p2"))
      await fetch.waitForRequests(2)
      #expect(fetch.requests.map(\.limit) == [2, 2])
      fetch.complete(1, with: ([post("c", read: true), post("d", read: true)], "p3"))
      await fetch.waitForRequests(3)
      #expect(fetch.requests.map(\.limit) == [2, 2, 2])
      fetch.complete(2, with: ([post("visible", read: false), post("also-visible", read: false)], "p4"))
      await task.value
      #expect(manager.displayMode == .items)

      let next = Task { await manager.loadMore() }
      await fetch.waitForRequests(4)
      #expect(fetch.requests[3].limit == 1)
      #expect(fetch.requests[3].after == "p4")
      fetch.complete(3, with: ([post("last", read: false)], nil))
      await next.value
      #expect(manager.displayMode == .endOfFeed)
    }
  }

  @Test func repeatedAppearanceLoadsOnlyOnce() async {
    let fetch = ControlledFetch()
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, fetchFn: fetch.fetch)
    let first = Task { await manager.loadIfNeeded() }
    await fetch.waitForRequests(1)
    await manager.loadIfNeeded()
    #expect(fetch.requests.count == 1)
    fetch.complete(0, with: ([], nil))
    await first.value
    await manager.loadIfNeeded()
    #expect(manager.displayMode == .empty)
    #expect(fetch.requests.count == 1)
  }

  @Test func retryRestartsTheFailedFirstPage() async {
    var cursors: [String?] = []
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil) { after, _, _, _, _ in
      cursors.append(after)
      return cursors.count == 1 ? nil : ([self.post("a", read: false)], nil)
    }
    await manager.reload()
    #expect(manager.displayMode == .error)
    await manager.retry()
    #expect(cursors == [nil, nil])
    #expect(manager.displayMode == .endOfFeed)
    #expect(ids(manager.entities) == ["a"])
  }

  @Test func retryResumesTheFailedPageWithoutLosingExistingItems() async {
    var cursors: [String?] = []
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil) { after, _, _, _, _ in
      cursors.append(after)
      if after == nil {
        return ([self.post("a", read: false), self.post("b", read: false)], "p2")
      }
      return cursors.count == 2 ? nil : ([self.post("c", read: false)], nil)
    }
    manager.chunkSize = 2
    await manager.reload()
    await manager.loadMore()
    #expect(manager.displayMode == .error)
    manager.elementAppeared(entity: manager.entities[1])
    #expect(cursors == [nil, "p2"])
    await manager.retry()
    #expect(cursors == [nil, "p2", "p2"])
    #expect(ids(manager.entities) == ["a", "b", "c"])
    #expect(manager.displayMode == .endOfFeed)
  }

  @Test func clearingAFeedClearsItsCursorAndDeduplicationIndex() async {
    let fetch = ControlledFetch()
    let manager = FeedItemsManager<SubListingSortOption>(sorting: nil, fetchFn: fetch.fetch)
    manager.chunkSize = 2
    let first = Task { await manager.reload() }
    await fetch.waitForRequests(1)
    fetch.complete(0, with: ([post("a", read: false), post("b", read: false)], "p2"))
    await first.value
    let reload = Task { await manager.reload(clearItems: true) }
    await fetch.waitForRequests(2)
    #expect(manager.entities.isEmpty)
    #expect(manager.lastElementId == nil)
    #expect(manager.displayMode == .loading)
    #expect(!manager.isLoadingMore)
    fetch.complete(1, with: ([post("a", read: false)], nil))
    await reload.value
    #expect(ids(manager.entities) == ["a"])
  }
}
