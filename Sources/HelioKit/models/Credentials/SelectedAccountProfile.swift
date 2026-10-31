import Foundation

/// Owns the selected account's profile. API calls (including draft authorization) only return data.
@MainActor
@Observable
final class SelectedAccountProfile {
  enum State { case signedOut, loading, ready, error }

  private(set) var user: User?
  private(set) var state: State = .signedOut
  @ObservationIgnored private var requestID: UUID?
  @ObservationIgnored private var authorizationID: RedditCredential.AuthorizationID?
  @ObservationIgnored private var task: Task<Void, Never>?
  private let currentAccount: @MainActor () -> RedditCredential?
  private let fetch: @MainActor (RedditCredential) async -> UserData?

  init(
    currentAccount: @escaping @MainActor () -> RedditCredential? = { RedditCredentialsManager.shared.selectedCredential },
    fetch: @escaping @MainActor (RedditCredential) async -> UserData? = { await RedditAPI.shared.fetchMe(altCredential: $0) },
  ) {
    self.currentAccount = currentAccount
    self.fetch = fetch
  }

  @MainActor
  func refresh() async {
    guard !Task.isCancelled else { return }
    await reload()?.value
  }

  /// Starts synchronously on account changes, clearing the previous account before fetching.
  @MainActor
  @discardableResult
  func reload() -> Task<Void, Never>? {
    guard let account = currentAccount(), let authorization = account.authorizationID else {
      task?.cancel()
      task = nil
      requestID = nil
      authorizationID = nil
      user = nil
      state = .signedOut
      return nil
    }
    if authorizationID == authorization, let task {
      return task
    }
    task?.cancel()
    if authorizationID != authorization {
      user = nil
    }
    authorizationID = authorization
    state = .loading
    let id = UUID()
    requestID = id
    let task = Task {
      defer {
        if self.requestID == id {
          self.task = nil
          self.requestID = nil
        }
      }
      guard self.requestID == id, !Task.isCancelled else { return }
      let data = await self.fetch(account)
      guard self.requestID == id, !Task.isCancelled,
            self.currentAccount()?.authorizationID == authorization else { return }
      self.user = data.map { User(data: $0) }
      self.state = data == nil ? .error : .ready
    }
    self.task = task
    return task
  }
}
