import Alamofire
import Foundation
import Synchronization
import Testing
@testable import HelioKit

struct RequestAuthorizationTests {
  private func account(_ name: String) -> RedditCredential {
    RedditCredential(apiAppID: "placeholder-client-id", accessToken: "placeholder-\(name)-access-token", refreshToken: "placeholder-\(name)-grant", expiration: 3600, lastRefresh: Date())
  }

  @Test func aRetryUsesTheOriginallySelectedAccount() async {
    let selected = Mutex(account("first"))
    let second = account("second")
    let headers = Mutex<[String?]>([])
    let api = RedditAPI(currentAccount: { selected.withLock { $0 } })
    let result: Result<String, AFError> = await api._doRequest { requestHeaders in
      let count = headers.withLock { values in
        values.append(requestHeaders["Authorization"])
        return values.count
      }
      if count == 1 {
        selected.withLock { $0 = second }
        return .failure(.responseValidationFailed(reason: .unacceptableStatusCode(code: 503)))
      }
      return .success("ok")
    }
    #expect((try? result.get()) == "ok")
    let observed1 = headers.withLock { $0 }
    #expect(observed1 == ["Bearer placeholder-first-access-token", "Bearer placeholder-first-access-token"])
  }

  @Test func absentSelectionIsResolvedOnceAndNeverFallsBackLater() async {
    let reads = Mutex(0)
    let requests = Mutex(0)
    let later = account("later")
    let api = RedditAPI(currentAccount: {
      let count = reads.withLock { $0 += 1
        return $0
      }
      return count == 1 ? nil : later
    })
    let result: Result<String, AFError> = await api._doRequest { _ in
      requests.withLock { $0 += 1 }
      return .success("unexpected")
    }
    if case .success = result {
      Issue.record("No authorization unexpectedly reached request dispatch")
    }
    let observed2 = reads.withLock { $0 }
    #expect(observed2 == 1)
    let observed3 = requests.withLock { $0 }
    #expect(observed3 == 0)
  }

  @Test func publicRequestsDoNotResolveOrSendAnAccount() async {
    let reads = Mutex(0)
    let requests = Mutex(0)
    let credential = account("unused")
    let api = RedditAPI(currentAccount: { reads.withLock { $0 += 1 }
      return credential
    })
    let result: Result<String, AFError> = await api._doRequest(authenticated: false) { headers in
      #expect(headers["Authorization"] == nil)
      requests.withLock { $0 += 1 }
      return .success("ok")
    }
    #expect((try? result.get()) == "ok")
    let observed4 = reads.withLock { $0 }
    #expect(observed4 == 0)
    let observed5 = requests.withLock { $0 }
    #expect(observed5 == 1)
  }

  private actor Gate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
      if started {
        return
      }
      started = true
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        waiters.forEach { $0.resume() }
        waiters = []
      }
    }

    func waitUntilStarted() async {
      if started {
        return
      }
      await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
      continuation?.resume()
    }
  }

  @Test func cancellationBeforeHeadersPreventsRequestDispatch() async {
    let gate = Gate()
    let credential = account("first")
    let requests = Mutex(0)
    let api = RedditAPI(currentAccount: { await gate.hold()
      return credential
    })
    let task = Task {
      let result: Result<String, AFError> = await api._doRequest { _ in
        requests.withLock { $0 += 1 }
        return .success("unexpected")
      }
      return result
    }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.release()
    _ = await task.value
    let observed6 = requests.withLock { $0 }
    #expect(observed6 == 0)
  }

  @Test func cancellationDoesNotRetryACompletedFailure() async {
    let gate = Gate()
    let credential = account("first")
    let requests = Mutex(0)
    let api = RedditAPI(currentAccount: { credential })
    let task = Task {
      let result: Result<String, AFError> = await api._doRequest { _ in
        requests.withLock { $0 += 1 }
        await gate.hold()
        return .failure(.responseValidationFailed(reason: .unacceptableStatusCode(code: 503)))
      }
      return result
    }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.release()
    _ = await task.value
    let observed7 = requests.withLock { $0 }
    #expect(observed7 == 1)
  }
}
