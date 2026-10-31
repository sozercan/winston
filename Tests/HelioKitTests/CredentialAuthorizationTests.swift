import Foundation
import Testing
@testable import HelioKit

struct CredentialAuthorizationTests {
  private func credential() -> RedditCredential {
    RedditCredential(apiAppID: "placeholder-client-id", apiAppSecret: "placeholder-client-secret", refreshToken: "placeholder-refresh-token")
  }

  private func token(_ value: String) -> RedditCredential.AccessToken {
    .init(token: value, expiration: 3600, lastRefresh: Date())
  }

  @Test func tokenRenewalDoesNotChangeAuthorizationIdentity() throws {
    var account = credential()
    let authorization = try #require(account.authorizationID)
    account.accessToken = token("placeholder-new-access-token")
    #expect(account.authorizationID == authorization)
  }

  @Test func tokenUpdatePreservesNewerMetadata() throws {
    var account = credential()
    let authorization = try #require(account.authorizationID)
    account.userAgent = "placeholder-custom-agent"
    account.userName = "placeholder-user"
    account.profilePicture = "https://example.com/avatar.png"
    let updated = account.updateAccessToken(token("placeholder-access-token"), for: authorization)
    #expect(updated)
    #expect(account.userAgent == "placeholder-custom-agent")
    #expect(account.userName == "placeholder-user")
    #expect(account.profilePicture == "https://example.com/avatar.png")
  }

  @Test(arguments: [false, true]) func oldRefreshCannotChangeAReplacedAuthorization(rejected: Bool) throws {
    var account = credential()
    let authorization = try #require(account.authorizationID)
    account.refreshToken = "placeholder-replacement-refresh-token"
    account.accessToken = token("placeholder-replacement-access-token")
    let before = account
    let updated = account.updateAccessToken(rejected ? nil : token("placeholder-stale-access-token"), for: authorization)
    #expect(!updated)
    #expect(account == before)
  }

  @Test func aRemovedAuthorizationCannotBeRestoredByRefresh() throws {
    var account = credential()
    let authorization = try #require(account.authorizationID)
    account.clearIdentity()
    let updated = account.updateAccessToken(token("placeholder-stale-access-token"), for: authorization)
    #expect(!updated)
    #expect(account.authorizationID == nil)
    #expect(account.accessToken == nil)
  }

  @Test func rejectingTheCurrentAuthorizationClearsItsIdentity() throws {
    var account = credential()
    let authorization = try #require(account.authorizationID)
    account.accessToken = token("placeholder-access-token")
    account.userName = "placeholder-user"
    let updated = account.updateAccessToken(nil, for: authorization)
    #expect(updated)
    #expect(account.authorizationID == nil)
    #expect(account.userName == nil)
    #expect(account.accessToken == nil)
  }
}
