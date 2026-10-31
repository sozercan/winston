import Foundation
import Testing
@testable import HelioKit

@MainActor
struct SelectedAccountProfileTests {
  private func credential(_ token: String = "placeholder-refresh-token") -> RedditCredential {
    RedditCredential(apiAppID: "placeholder-client-id", refreshToken: token)
  }

  private func user(_ name: String) throws -> UserData {
    let json = try JSONSerialization.data(withJSONObject: ["id": name, "name": name])
    return try JSONDecoder().decode(UserData.self, from: json)
  }

  private final class Fetch {
    var accounts: [RedditCredential] = []
    private var responses: [CheckedContinuation<UserData?, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func call(_ account: RedditCredential) async -> UserData? {
      await withCheckedContinuation { continuation in
        accounts.append(account)
        responses.append(continuation)
        let ready = waiters.filter { accounts.count >= $0.0 }
        waiters.removeAll { accounts.count >= $0.0 }
        ready.forEach { $0.1.resume() }
      }
    }

    func waitForCalls(_ count: Int) async {
      if accounts.count >= count {
        return
      }
      await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with user: UserData?) {
      responses[index].resume(returning: user)
    }
  }

  @Test(arguments: [false, true]) func lateResultsCannotReplaceTheSelectedProfile(fails: Bool) async throws {
    var selected: RedditCredential? = credential("placeholder-first-token")
    let fetch = Fetch()
    let profile = SelectedAccountProfile(currentAccount: { selected }, fetch: fetch.call)
    let first = try #require(profile.reload())
    await fetch.waitForCalls(1)
    selected = credential("placeholder-second-token")
    let second = try #require(profile.reload())
    await fetch.waitForCalls(2)
    try fetch.complete(1, with: user("placeholder-second-user"))
    await second.value
    try fetch.complete(0, with: fails ? nil : user("placeholder-first-user"))
    await first.value
    #expect(profile.user?.data?.name == "placeholder-second-user")
    #expect(profile.state == .ready)
  }

  @Test(arguments: [false, true]) func logoutRejectsBothLateSuccessAndFailure(fails: Bool) async throws {
    var selected: RedditCredential? = credential()
    let fetch = Fetch()
    let profile = SelectedAccountProfile(currentAccount: { selected }, fetch: fetch.call)
    let task = try #require(profile.reload())
    await fetch.waitForCalls(1)
    selected = nil
    #expect(profile.reload() == nil)
    try fetch.complete(0, with: fails ? nil : user("placeholder-user"))
    await task.value
    #expect(profile.user == nil)
    #expect(profile.state == .signedOut)
  }

  @Test func reauthorizationUnderTheSameIDInvalidatesTheOldProfile() async throws {
    var selected: RedditCredential? = credential("placeholder-old-authorization")
    let fetch = Fetch()
    let profile = SelectedAccountProfile(currentAccount: { selected }, fetch: fetch.call)
    let first = try #require(profile.reload())
    await fetch.waitForCalls(1)
    selected?.refreshToken = "placeholder-new-authorization"
    let second = try #require(profile.reload())
    await fetch.waitForCalls(2)
    #expect(fetch.accounts[0].id == fetch.accounts[1].id)
    try fetch.complete(0, with: user("placeholder-old-user"))
    await first.value
    #expect(profile.user == nil)
    #expect(profile.state == .loading)
    try fetch.complete(1, with: user("placeholder-new-user"))
    await second.value
    #expect(profile.user?.data?.name == "placeholder-new-user")
  }

  @Test func simultaneousRefreshesShareTheSelectedRequest() async throws {
    let selected = credential()
    let fetch = Fetch()
    let profile = SelectedAccountProfile(currentAccount: { selected }, fetch: fetch.call)
    let first = try #require(profile.reload())
    await fetch.waitForCalls(1)
    let second = try #require(profile.reload())
    #expect(fetch.accounts.count == 1)
    try fetch.complete(0, with: user("placeholder-user"))
    await first.value
    await second.value
    #expect(profile.state == .ready)
  }

  @Test func missingAuthorizationDoesNotFetch() {
    let fetch = Fetch()
    let selected = RedditCredential(apiAppID: "placeholder-client-id")
    let profile = SelectedAccountProfile(currentAccount: { selected }, fetch: fetch.call)
    #expect(profile.reload() == nil)
    #expect(fetch.accounts.isEmpty)
    #expect(profile.state == .signedOut)
  }

  @Test func failedProfileCanBeRetried() async throws {
    let selected = credential()
    let fetch = Fetch()
    let profile = SelectedAccountProfile(currentAccount: { selected }, fetch: fetch.call)
    let first = try #require(profile.reload())
    await fetch.waitForCalls(1)
    fetch.complete(0, with: nil)
    await first.value
    #expect(profile.state == .error)
    let second = try #require(profile.reload())
    await fetch.waitForCalls(2)
    try fetch.complete(1, with: user("placeholder-user"))
    await second.value
    #expect(profile.state == .ready)
  }

  @Test func switchingClearsThePublishedUserBeforeTheNextFetch() async throws {
    var selected: RedditCredential? = credential("placeholder-first-authorization")
    let fetch = Fetch()
    let profile = SelectedAccountProfile(currentAccount: { selected }, fetch: fetch.call)
    let first = try #require(profile.reload())
    await fetch.waitForCalls(1)
    try fetch.complete(0, with: user("placeholder-first-user"))
    await first.value
    #expect(profile.user?.data?.name == "placeholder-first-user")
    selected = credential("placeholder-second-authorization")
    let second = try #require(profile.reload())
    #expect(profile.user == nil)
    #expect(profile.state == .loading)
    await fetch.waitForCalls(2)
    try fetch.complete(1, with: user("placeholder-second-user"))
    await second.value
  }
}
