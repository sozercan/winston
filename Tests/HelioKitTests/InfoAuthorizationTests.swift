import Foundation
import Synchronization
import Testing
@testable import HelioKit

struct InfoAuthorizationTests {
  private func account() -> RedditCredential {
    RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-first-grant")
  }

  private func post(_ id: String = "a", liked: Bool = false) throws -> PostData {
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(postSampleData)) as? [String: Any])
    json["id"] = id
    json["name"] = "t3_\(id)"
    json["likes"] = liked
    return try JSONDecoder().decode(PostData.self, from: JSONSerialization.data(withJSONObject: json))
  }

  @Test func reauthorizationDoesNotReuseThePreviousUsersCachedVotes() async throws {
    let selected = Mutex(account())
    let calls = Mutex(0)
    let old = try post(liked: true), new = try post(liked: false)
    let loader = RedditInfoLoader(currentAccount: { selected.withLock { $0 } }, authorizationIsCurrent: { candidate in
      selected.withLock { $0.authorizationID == candidate.authorizationID }
    }, fetch: { _, _, candidate in
      calls.withLock { $0 += 1 }
      return [.post(candidate.refreshToken == "placeholder-first-grant" ? old : new)]
    })
    let first = await loader.post("t3_a")
    selected.withLock { $0.refreshToken = "placeholder-replacement-grant" }
    let second = await loader.post("t3_a")
    #expect(first?.likes == true)
    #expect(second?.likes == false)
    let observed1 = calls.withLock { $0 }
    #expect(observed1 == 2)
  }

  @Test func accessTokenRenewalKeepsTheSameAuthorizationCache() async throws {
    let selected = Mutex(account())
    let calls = Mutex(0)
    let data = try post()
    let loader = RedditInfoLoader(currentAccount: { selected.withLock { $0 } }, authorizationIsCurrent: { _ in true }, fetch: { _, _, _ in
      calls.withLock { $0 += 1 }
      return [.post(data)]
    })
    _ = await loader.post("t3_a")
    selected.withLock { $0.accessToken = .init(token: "placeholder-new-access-token", expiration: 3600, lastRefresh: Date()) }
    _ = await loader.post("t3_a")
    let observed2 = calls.withLock { $0 }
    #expect(observed2 == 1)
  }

  @Test func noAccountNeverBecomesADeferredSelectedAccount() async throws {
    let selected = Mutex<RedditCredential?>(nil)
    let calls = Mutex(0)
    let data = try post()
    let loader = RedditInfoLoader(currentAccount: { selected.withLock { $0 } }, authorizationIsCurrent: { _ in true }, fetch: { _, _, _ in
      calls.withLock { $0 += 1 }
      return [.post(data)]
    })
    let missing = await loader.post("t3_a")
    #expect(missing == nil)
    let observed3 = calls.withLock { $0 }
    #expect(observed3 == 0)
    selected.withLock { $0 = account() }
    let found = await loader.post("t3_a")
    #expect(found?.id == "a")
    let observed4 = calls.withLock { $0 }
    #expect(observed4 == 1)
  }

  private actor Fetch {
    private var continuations: [CheckedContinuation<[RedditInfoLoader.Thing]?, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int {
      continuations.count
    }

    func call() async -> [RedditInfoLoader.Thing]? {
      await withCheckedContinuation { continuation in
        continuations.append(continuation)
        let ready = waiters.filter { continuations.count >= $0.0 }
        waiters.removeAll { continuations.count >= $0.0 }
        ready.forEach { $0.1.resume() }
      }
    }

    func waitForCalls(_ count: Int) async {
      if continuations.count >= count {
        return
      }
      await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with things: [RedditInfoLoader.Thing]) {
      continuations[index].resume(returning: things)
    }
  }

  @Test func removedAuthorizationCannotPublishOrCacheAnInFlightResult() async throws {
    let credential = account()
    let selected = Mutex<RedditCredential?>(credential)
    let fetch = Fetch()
    let data = try post()
    let loader = RedditInfoLoader(currentAccount: { selected.withLock { $0 } }, authorizationIsCurrent: { candidate in
      selected.withLock { $0?.authorizationID == candidate.authorizationID }
    }, fetch: { _, _, _ in await fetch.call() })
    let first = Task { await loader.post("t3_a") }
    await fetch.waitForCalls(1)
    selected.withLock { $0 = nil }
    await fetch.complete(0, with: [.post(data)])
    let removed = await first.value
    #expect(removed == nil)
    // Restoring the same grant must fetch again: the removed grant's late result wasn't cached.
    selected.withLock { $0 = credential }
    let second = Task { await loader.post("t3_a") }
    await fetch.waitForCalls(2)
    await fetch.complete(1, with: [.post(data)])
    let restored = await second.value
    #expect(restored?.id == "a")
    #expect(await fetch.count == 2)
  }

  private actor CheckGate {
    private var checked = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func check() async {
      if checked {
        return
      }
      checked = true
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        waiters.forEach { $0.resume() }
        waiters = []
      }
    }

    func waitForCheck() async {
      if checked {
        return
      }
      await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
      continuation?.resume()
    }
  }

  @Test func revokedQueuedAuthorizationIsRejectedBeforeNetworkDispatch() async {
    let selected = Mutex<RedditCredential?>(account())
    let gate = CheckGate()
    let calls = Mutex(0)
    let loader = RedditInfoLoader(currentAccount: { selected.withLock { $0 } }, authorizationIsCurrent: { candidate in
      await gate.check()
      return selected.withLock { $0?.authorizationID == candidate.authorizationID }
    }, fetch: { _, _, _ in
      calls.withLock { $0 += 1 }
      return []
    })
    let task = Task { await loader.post("t3_a") }
    await gate.waitForCheck()
    selected.withLock { $0 = nil }
    await gate.release()
    let result = await task.value
    #expect(result == nil)
    let observed5 = calls.withLock { $0 }
    #expect(observed5 == 0)
  }
}
