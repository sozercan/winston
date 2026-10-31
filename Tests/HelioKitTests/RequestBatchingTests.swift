import Alamofire
import Foundation
import Synchronization
import Testing
@testable import HelioKit

/// Records the batches a loader sends.
private final class Calls: Sendable {
  private let batches = Mutex<[[String]]>([])

  func record(_ batch: [String]) {
    batches.withLock { $0.append(batch.sorted()) }
  }

  var all: [[String]] {
    batches.withLock { $0 }
  }
}

struct AvatarLoaderTests {
  @Test func coalescesConcurrentLookupsIntoOneRequest() async {
    let calls = Calls()
    let loader = AvatarLoader { ids in
      calls.record(ids)
      return Dictionary(uniqueKeysWithValues: ids.map { ($0, "https://example.com/\($0).png?width=256") })
    }
    async let first = loader.avatarURLs(for: ["t2_a", "t2_b"])
    async let second = loader.avatarURLs(for: ["t2_b", "t2_c"])
    let (a, b) = await (first, second)

    #expect(calls.all == [["t2_a", "t2_b", "t2_c"]])
    #expect(a["t2_a"]?.absoluteString == "https://example.com/t2_a.png")
    #expect(b.keys.sorted() == ["t2_b", "t2_c"])
  }

  @Test func asksOnceForEachAuthor() async {
    let calls = Calls()
    let loader = AvatarLoader { ids in
      calls.record(ids)
      return Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == "t2_none" ? nil : "https://example.com/\($0).png") })
    }
    _ = await loader.avatarURLs(for: ["t2_a", "t2_none"])
    let again = await loader.avatarURLs(for: ["t2_a", "t2_none", "t2_new"])

    #expect(calls.all == [["t2_a", "t2_none"], ["t2_new"]])
    #expect(again.keys.sorted() == ["t2_a", "t2_new"])
  }

  @Test func splitsLargeLookupsIntoBatches() async {
    let calls = Calls()
    let loader = AvatarLoader { ids in
      calls.record(ids)
      return [:]
    }
    _ = await loader.avatarURLs(for: (0 ..< 250).map { "t2_\($0)" })

    #expect(calls.all.map(\.count).sorted() == [50, 100, 100])
  }

  @Test func asksAgainAfterAFailedRequest() async {
    let calls = Calls()
    let loader = AvatarLoader { ids in
      calls.record(ids)
      return calls.all.count == 1 ? nil : ["t2_a": "https://example.com/a.png"]
    }
    #expect(await loader.avatarURLs(for: ["t2_a"]).isEmpty)
    #expect(await loader.avatarURLs(for: ["t2_a"])["t2_a"] != nil)
    #expect(calls.all.count == 2)
  }
}

struct RedditInfoLoaderTests {
  private func post(_ id: String) -> PostData? {
    guard var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(postSampleData))) as? [String: Any] else { return nil }
    json["id"] = id
    json["name"] = "t3_\(id)"
    return try? JSONDecoder().decode(PostData.self, from: JSONSerialization.data(withJSONObject: json))
  }

  private func subreddit(_ name: String) -> SubredditData? {
    let json: [String: Any] = ["id": "2qh1f", "name": "t5_2qh1f", "display_name": name, "public_description": "", "url": "/r/\(name)/"]
    return try? JSONDecoder().decode(SubredditData.self, from: JSONSerialization.data(withJSONObject: json))
  }

  @Test func batchesPostsAndSubredditsAndCachesThem() async {
    let calls = Calls()
    let account = RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-refresh-token")
    let loader = RedditInfoLoader(currentAccount: { account }, authorizationIsCurrent: { _ in true }, fetch: { fullnames, names, _ in
      calls.record(fullnames + names.map { "sr:\($0)" })
      var things = fullnames.compactMap { self.post(String($0.dropFirst(3))).map(RedditInfoLoader.Thing.post) }
      if names.contains("apple"), let apple = self.subreddit("apple") {
        things.append(.subreddit(apple))
      }
      return things
    })
    async let a = loader.post("t3_a")
    async let b = loader.post("t3_b")
    async let sub = loader.subreddit(named: "Apple")
    let (postA, postB, apple) = await (a, b, sub)
    let again = await loader.post("t3_a")

    #expect(postA?.id == "a")
    #expect(postB?.id == "b")
    #expect(apple?.display_name == "apple")
    #expect(again?.id == "a")
    #expect(calls.all.sorted { $0.count > $1.count } == [["t3_a", "t3_b"], ["sr:apple"]])
  }

  /// Results carry the account's votes and saves, and only some accounts see private subreddits.
  @Test func keepsEachAccountsResultsApart() async {
    let calls = Calls()
    let first = RedditCredential(apiAppID: "first", refreshToken: "placeholder-first-grant"), second = RedditCredential(apiAppID: "second", refreshToken: "placeholder-second-grant")
    let selected = Mutex(first)
    let loader = RedditInfoLoader(currentAccount: { selected.withLock { $0 } }, authorizationIsCurrent: { _ in true }, fetch: { fullnames, _, account in
      calls.record(fullnames.map { "\(account.apiAppID):\($0)" })
      return fullnames.compactMap { self.post(String($0.dropFirst(3))).map(RedditInfoLoader.Thing.post) }
    })
    _ = await loader.post("t3_a")
    selected.withLock { $0 = second }
    _ = await loader.post("t3_a")
    selected.withLock { $0 = first }
    _ = await loader.post("t3_a")

    #expect(calls.all == [["first:t3_a"], ["second:t3_a"]])
  }
}

struct LinkMetadataLoaderTests {
  @Test func downloadsEachPageOnce() async throws {
    let calls = Calls()
    let loader = LinkMetadataLoader { url in
      calls.record([url.absoluteString])
      try? await Task.sleep(for: .milliseconds(20))
      return .init(title: "Title", description: nil, image: nil, url: nil)
    }
    let url = try #require(URL(string: "https://example.com/article"))
    async let first = loader.metadata(for: url)
    async let second = loader.metadata(for: url)
    _ = await (first, second)
    let third = await loader.metadata(for: url)

    #expect(third?.title == "Title")
    #expect(calls.all.count == 1)
  }
}

struct AccessTokenRefresherTests {
  private func token(_ value: String, age: TimeInterval = 0) -> RedditCredential.AccessToken {
    .init(token: value, expiration: 3600, lastRefresh: Date().addingTimeInterval(-age))
  }

  @Test func concurrentRefreshesShareOneRequest() async throws {
    let authorization = try #require(RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-refresh-token").authorizationID)
    let calls = Calls()
    let refresher = AccessTokenRefresher()
    let refresh: @Sendable () async -> AccessTokenRefresher.Outcome = {
      calls.record(["refresh"])
      try? await Task.sleep(for: .milliseconds(20))
      return .token(self.token("new"))
    }
    async let a = refresher.refresh(for: authorization, forceRenew: false, refresh: refresh)
    async let b = refresher.refresh(for: authorization, forceRenew: false, refresh: refresh)
    let (first, second) = await (a, b)
    // Asked again before the credential stored the new token.
    let third = await refresher.refresh(for: authorization, forceRenew: false, refresh: refresh)

    #expect(first.accessToken?.token == "new" && second.accessToken?.token == "new" && third.accessToken?.token == "new")
    #expect(calls.all.count == 1)
  }

  @Test func forcedRenewalReplacesTheRejectedToken() async throws {
    let authorization = try #require(RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-refresh-token").authorizationID)
    let calls = Calls()
    let refresher = AccessTokenRefresher()
    _ = await refresher.refresh(for: authorization, forceRenew: false) {
      calls.record(["first"])
      return .token(self.token("revoked"))
    }
    let renewed = await refresher.refresh(for: authorization, forceRenew: true, rejected: "revoked") {
      calls.record(["second"])
      return .token(self.token("new"))
    }

    #expect(renewed.accessToken?.token == "new")
    #expect(calls.all.count == 2)
  }

  /// A retry after a renewal (401, renewed, 503) gets the renewed token, not the rejected one a
  /// credential snapshot still holds, and doesn't renew again.
  @Test func retryAfterRenewalReusesTheRenewedToken() async throws {
    let authorization = try #require(RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-refresh-token").authorizationID)
    let calls = Calls()
    let refresher = AccessTokenRefresher()
    _ = await refresher.refresh(for: authorization, forceRenew: true, rejected: "revoked") {
      calls.record(["renew"])
      return .token(self.token("renewed"))
    }
    let retry = await refresher.refresh(for: authorization, forceRenew: false, rejected: "revoked") {
      calls.record(["again"])
      return .token(self.token("other"))
    }

    #expect(retry.accessToken?.token == "renewed")
    #expect(calls.all.count == 1)
  }

  @Test func neverReusesTheRejectedToken() async throws {
    let authorization = try #require(RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-refresh-token").authorizationID)
    let calls = Calls()
    let refresher = AccessTokenRefresher()
    _ = await refresher.refresh(for: authorization, forceRenew: false) {
      calls.record(["first"])
      return .token(self.token("revoked"))
    }
    let next = await refresher.refresh(for: authorization, forceRenew: false, rejected: "revoked") {
      calls.record(["second"])
      return .token(self.token("new"))
    }

    #expect(next.accessToken?.token == "new")
    #expect(calls.all.count == 2)
  }

  @Test func forcedRenewalReusesATokenNewerThanTheRejectedOne() async throws {
    let authorization = try #require(RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-refresh-token").authorizationID)
    let calls = Calls()
    let refresher = AccessTokenRefresher()
    _ = await refresher.refresh(for: authorization, forceRenew: false) {
      calls.record(["first"])
      return .token(self.token("new"))
    }
    let reused = await refresher.refresh(for: authorization, forceRenew: true, rejected: "expired") {
      calls.record(["second"])
      return .token(self.token("newer"))
    }

    #expect(reused.accessToken?.token == "new")
    #expect(calls.all.count == 1)
  }

  @Test func duplicateCredentialRecordsShareTheirOAuthGrant() async throws {
    let first = RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-shared-grant")
    var duplicate = first
    duplicate.id = UUID()
    let firstID = try #require(first.authorizationID), duplicateID = try #require(duplicate.authorizationID)
    #expect(firstID != duplicateID)
    let calls = Calls()
    let refresher = AccessTokenRefresher()
    _ = await refresher.refresh(for: firstID, forceRenew: false) {
      calls.record(["refresh"])
      return .token(self.token("placeholder-shared-token"))
    }
    let shared = await refresher.refresh(for: duplicateID, forceRenew: false) {
      calls.record(["unexpected"])
      return .failed
    }
    #expect(shared.accessToken?.token == "placeholder-shared-token")
    #expect(calls.all.count == 1)
  }

  @Test func differentClientsNeverShareARefreshTokenCache() async throws {
    let first = RedditCredential(apiAppID: "placeholder-first-client", refreshToken: "placeholder-shared-grant")
    var replacement = first
    replacement.apiAppID = "placeholder-second-client"
    replacement.refreshToken = "placeholder-shared-grant"
    let firstID = try #require(first.authorizationID), replacementID = try #require(replacement.authorizationID)
    let calls = Calls()
    let refresher = AccessTokenRefresher()
    _ = await refresher.refresh(for: firstID, forceRenew: false) {
      calls.record(["first"])
      return .token(self.token("placeholder-first-token"))
    }
    let result = await refresher.refresh(for: replacementID, forceRenew: false) {
      calls.record(["second"])
      return .token(self.token("placeholder-second-token"))
    }
    #expect(result.accessToken?.token == "placeholder-second-token")
    #expect(calls.all.count == 2)
  }

  @Test(arguments: [AccessTokenRefresher.Outcome.rejected, .failed])
  func failedRefreshOutcomesAreNotCached(failure: AccessTokenRefresher.Outcome) async throws {
    let authorization = try #require(RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-grant").authorizationID)
    let calls = Calls()
    let refresher = AccessTokenRefresher()
    _ = await refresher.refresh(for: authorization, forceRenew: false) {
      calls.record(["failure"])
      return failure
    }
    let result = await refresher.refresh(for: authorization, forceRenew: false) {
      calls.record(["success"])
      return .token(self.token("placeholder-retry-token"))
    }
    #expect(result.accessToken?.token == "placeholder-retry-token")
    #expect(calls.all.count == 2)
  }

  private actor RefreshGate {
    private var started = false
    private var continuation: CheckedContinuation<AccessTokenRefresher.Outcome, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func request() async -> AccessTokenRefresher.Outcome {
      started = true
      return await withCheckedContinuation { continuation in
        self.continuation = continuation
        waiters.forEach { $0.resume() }
        waiters = []
      }
    }

    func waitForRequest() async {
      if started {
        return
      }
      await withCheckedContinuation { waiters.append($0) }
    }

    func complete(_ outcome: AccessTokenRefresher.Outcome) {
      continuation?.resume(returning: outcome)
    }
  }

  @Test func cancellingOneWaiterDoesNotCancelTheSharedRefresh() async throws {
    let authorization = try #require(RedditCredential(apiAppID: "placeholder-client-id", refreshToken: "placeholder-grant").authorizationID)
    let calls = Calls()
    let gate = RefreshGate()
    let refresher = AccessTokenRefresher()
    let first = Task {
      await refresher.refresh(for: authorization, forceRenew: false) {
        calls.record(["refresh"])
        return await gate.request()
      }
    }
    await gate.waitForRequest()
    first.cancel()
    let second = Task {
      await refresher.refresh(for: authorization, forceRenew: false) {
        calls.record(["unexpected"])
        return .failed
      }
    }
    await gate.complete(.token(token("placeholder-shared-token")))
    let firstResult = await first.value, secondResult = await second.value
    #expect(firstResult.accessToken?.token == "placeholder-shared-token")
    #expect(secondResult.accessToken?.token == "placeholder-shared-token")
    #expect(calls.all.count == 1)
  }
}

struct RetryPolicyTests {
  @Test func retriesOnlyFailuresThatCanSucceedLater() {
    func status(_ code: Int) -> AFError {
      .responseValidationFailed(reason: .unacceptableStatusCode(code: code))
    }
    #expect(RedditAPI.isTransient(status(503)))
    #expect(RedditAPI.isTransient(.sessionTaskFailed(error: URLError(.networkConnectionLost))))
    #expect(!RedditAPI.isTransient(status(404)))
    #expect(!RedditAPI.isTransient(status(403)))
    #expect(!RedditAPI.isTransient(status(429)))
    #expect(!RedditAPI.isTransient(.responseSerializationFailed(reason: .inputDataNilOrZeroLength)))
    #expect(!RedditAPI.isTransient(.explicitlyCancelled))
  }
}
