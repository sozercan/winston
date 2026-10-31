//
//  RedditAPI.swift
//  Helio
//
//  Created by Igor Marcossi on 24/06/23.
//

import Alamofire
import AuthenticationServices
import Combine
import Defaults
import Foundation
import KeychainAccess
import SwiftUI

@Observable
class RedditAPI {
  static let shared = RedditAPI()
  static let redditApiURLBase = "https://oauth.reddit.com"
  static let redditWWWApiURLBase = "https://www.reddit.com"
  static let appURLScheme = "helioapp"
  /// Reddit only accepts https redirects for web-app keys (the ones with a secret). This page
  /// forwards the query to `helioapp://auth-success`, where `authorize` picks it up.
  static let appRedirectURI: String = "https://sozercan.github.io/helio/auth-success"

  private let currentAccount: @Sendable () async -> RedditCredential?
  private let session: Session

  init(session: Session = AF, currentAccount: @escaping @Sendable () async -> RedditCredential? = {
    await MainActor.run { RedditCredentialsManager.shared.selectedCredential }
  }) {
    self.session = session
    self.currentAccount = currentAccount
  }

  /// Resolve selection once when both the endpoint and dispatch depend on the account.
  func captureAccount() async -> RedditCredential? {
    await currentAccount()
  }

  /// Compatibility read-through; the API layer no longer owns or publishes account state.
  @MainActor var me: User? {
    RedditCredentialsManager.profile.user
  }

  /// This is a replacement for getRequestHeader. We need to replace every instance of the former by this one
  func fetchRequestHeaders(
    force: Bool = false,
    includeAuth: Bool = true,
    altCredential: RedditCredential? = nil,
    saveToken: Bool = true,
    rejectedToken: String? = nil,
  ) async -> HTTPHeaders? {
    var headers: HTTPHeaders = [
      "User-Agent": RedditCredential.defaultUserAgent(),
    ]
    if includeAuth {
      var credential = altCredential
      if credential == nil {
        credential = await currentAccount()
      }
      if
        let selectedCredential = credential,
        let accessToken = await selectedCredential.getUpToDateToken(forceRenew: force, saveToken: saveToken, rejectedToken: rejectedToken)
      {
        headers["Authorization"] = "Bearer \(accessToken.token)"
        headers["User-Agent"] = selectedCredential.userAgent
      } else {
        return nil
      }
    }

    HTTPCookieStorage.shared.cookies?.forEach(HTTPCookieStorage.shared.deleteCookie)

    return headers
  }

  private let reqAttempts = 2

  private let reqModifier: Session.RequestModifier = { urlReq in
    urlReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
  }

  func doRequest<D: Decodable>(
    _ url: String,
    authenticated: Bool = true,
    method: HTTPMethod,
    params: (some Encodable)? = nil,
    paramsLocation: URLEncodedFormParameterEncoder.Destination = .httpBody,
    decodable: D.Type,
    altCredential: RedditCredential? = nil,
    attempt: Int = 0,
    saveToken: Bool = true,
  ) async -> Result<D, AFError> {
    await self._doRequest(authenticated: authenticated, altCredential: altCredential, saveToken: saveToken) { headers in
      let req = session.request(url, method: method, parameters: params, encoder: URLEncodedFormParameterEncoder(destination: paramsLocation), headers: headers, requestModifier: reqModifier).validate()
      return await req.serializingDecodable(decodable).response.result
    }
  }

  func doRequest<D: Decodable>(
    _ url: String,
    authenticated: Bool = true,
    method: HTTPMethod,
    decodable: D.Type,
    altCredential: RedditCredential? = nil,
    attempt: Int = 0,
    saveToken: Bool = true,
  ) async -> Result<D, AFError> {
    await self._doRequest(authenticated: authenticated, altCredential: altCredential, saveToken: saveToken) { headers in
      let req = session.request(url, method: method, parameters: ["raw_json": 1], headers: headers, requestModifier: reqModifier).validate()
      return await req.serializingDecodable(decodable).response.result
    }
  }

  func doRequest(
    _ url: String,
    authenticated: Bool = true,
    method: HTTPMethod,
    params: some Encodable,
    paramsLocation: URLEncodedFormParameterEncoder.Destination = .httpBody,
    altCredential: RedditCredential? = nil,
    attempt: Int = 0,
    saveToken: Bool = true,
  ) async -> Result<String, AFError> {
    await self._doRequest(authenticated: authenticated, altCredential: altCredential, saveToken: saveToken) { headers in
      let req = session.request(url, method: method, parameters: params, encoder: URLEncodedFormParameterEncoder(destination: paramsLocation), headers: headers, requestModifier: reqModifier).validate()
      return await req.serializingString().result
    }
  }

  func doRequest(
    _ url: String,
    authenticated: Bool = true,
    method: HTTPMethod,
    paramsLocation: URLEncodedFormParameterEncoder.Destination = .httpBody,
    altCredential: RedditCredential? = nil,
    attempt: Int = 0,
    saveToken: Bool = true,
  ) async -> Result<String, AFError> {
    await self._doRequest(authenticated: authenticated, altCredential: altCredential, saveToken: saveToken) { headers in
      let req = session.request(url, method: method, parameters: ["raw_json": 1], headers: headers).validate()
      return await req.serializingString().result
    }
  }

  /// `renewedToken`: this request already renewed its token after a 401, which it does once.
  func _doRequest<D: Decodable>(
    attempt: Int = 0,
    forceAuth: Bool = false,
    authenticated: Bool = true,
    altCredential: RedditCredential? = nil,
    saveToken: Bool = true,
    rejectedToken: String? = nil,
    renewedToken: Bool = false,
    req: (HTTPHeaders) async -> Result<D, AFError>,
  ) async -> Result<D, AFError> {
    guard !Task.isCancelled else { return .failure(.explicitlyCancelled) }
    // Resolve selection exactly once. Retries and token renewal must remain on this account,
    // and an absent account must not become a deferred "use whoever is selected later".
    var credential = altCredential
    if authenticated, credential == nil {
      credential = await currentAccount()
    }
    guard !Task.isCancelled else { return .failure(.explicitlyCancelled) }
    guard !authenticated || credential != nil, let headers = await fetchRequestHeaders(force: forceAuth, includeAuth: authenticated, altCredential: credential, saveToken: saveToken, rejectedToken: rejectedToken) else { return .failure(.serverTrustEvaluationFailed(reason: .noPublicKeysFound)) }
    guard !Task.isCancelled else { return .failure(.explicitlyCancelled) }

    let result = await req(headers)
    guard case let .failure(error) = result, !Task.isCancelled else { return result }
    // A 401 means the token expired or was revoked early: renew it once.
    if authenticated, !renewedToken, error.responseCode == 401 {
      let rejected = headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) }
      return await self._doRequest(attempt: attempt, forceAuth: true, authenticated: authenticated, altCredential: credential, saveToken: saveToken,
                                   rejectedToken: rejected, renewedToken: true, req: req)
    }
    if attempt < Self.maxRetries, Self.isTransient(error) {
      try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
      // Keeps the rejected token: a credential snapshot (`altCredential`) still holds it.
      return await self._doRequest(attempt: attempt + 1, authenticated: authenticated, altCredential: credential, saveToken: saveToken,
                                   rejectedToken: rejectedToken, renewedToken: renewedToken, req: req)
    }
    return result
  }

  static let maxRetries = 2

  /// Whether sending the same request again can succeed: a dropped connection or one of
  /// Reddit's intermittent 5xx. A 4xx (other than 401), a 429 or an undecodable body fails the
  /// same way every time, and each retry still counts against the rate limit.
  static func isTransient(_ error: AFError) -> Bool {
    if let code = error.responseCode {
      return (500 ... 599).contains(code)
    }
    guard case let .sessionTaskFailed(underlying) = error, let urlError = underlying as? URLError else { return false }
    switch urlError.code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
      return true
    default:
      return false
    }
  }

  func injectFirstAccessTokenInto(_ credential: inout RedditCredential, authCode: String) async -> Bool {
    if !credential.apiAppID.isEmpty {
      let headers = await fetchRequestHeaders(includeAuth: false)
      var code = authCode
      if code.hasSuffix("#_") {
        code = "\(code.dropLast(2))"
      }
      let payload = GetAccessTokenPayload(code: code)
      let response = await AF.request(
        "\(RedditAPI.redditWWWApiURLBase)/api/v1/access_token",
        method: .post,
        parameters: payload,
        encoder: URLEncodedFormParameterEncoder(destination: .httpBody),
        headers: headers,
      )
      .authenticate(username: credential.apiAppID, password: credential.apiAppSecret, persistence: .none)
      .serializingDecodable(GetAccessTokenResponse.self).response
      switch response.result {
      case let .success(data):
        let newAcessToken = RedditCredential.AccessToken(token: data.access_token, expiration: data.expires_in, lastRefresh: Date())
        credential.refreshToken = data.refresh_token
        credential.accessToken = newAcessToken
        if let meData = await self.fetchMe(altCredential: credential, saveToken: false) {
          credential.userName = meData.name
          if let avatar = (meData.subreddit?.icon_img ?? meData.icon_img ?? meData.snoovatar_img), let rootAvatar = rootURL(avatar)?.absoluteString {
            credential.profilePicture = rootAvatar
          }
          return true
        }
        return true
      case let .failure(error):
        print(error)
        return false
      }
    }
    return false
  }

  enum AuthorizationResult { case code(String), cancelled, failed }

  /// Runs Reddit's OAuth consent page in an in-app browser session and returns the
  /// authorization code once the redirect page forwards to `helioapp://auth-success`.
  @MainActor
  func authorize(appID: String, using session: WebAuthenticationSession) async -> AuthorizationResult {
    let state = UUID().uuidString
    do {
      let callbackURL = try await session.authenticate(
        using: getAuthorizationCodeURL(appID, state: state),
        callbackURLScheme: Self.appURLScheme,
        preferredBrowserSession: .shared,
      )
      guard let code = Self.authCode(from: callbackURL, state: state) else { return .failed }
      return .code(code)
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      return .cancelled
    } catch {
      return .failed
    }
  }

  static func authCode(from url: URL, state: String) -> String? {
    guard
      url.scheme == appURLScheme,
      url.host == "auth-success",
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      query.first(where: { $0.name == "state" })?.value == state,
      let code = query.first(where: { $0.name == "code" })?.value
    else { return nil }
    return code
  }

  func getAuthorizationCodeURL(_ appID: String, state: String) -> URL {
    let response_type = "code"
    let redirect_uri: String = RedditAPI.appRedirectURI
    let duration = "permanent"
    let scope = "identity,edit,flair,history,modconfig,modflair,modlog,modposts,modwiki,mysubreddits,privatemessages,read,report,save,submit,subscribe,vote,wikiedit,wikiread"

    return URL(string: "https://www.reddit.com/api/v1/authorize.compact?client_id=\(appID.trimmingCharacters(in: .whitespaces))&response_type=\(response_type)&state=\(state)&redirect_uri=\(redirect_uri)&duration=\(duration)&scope=\(scope)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
  }

  struct RefreshAccessTokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let scope: String
  }

  struct GetAccessTokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let refresh_token: String
    let scope: String
    let expires_in: Int
  }

  struct RefreshAccessTokenPayload: Encodable {
    let grant_type = "refresh_token"
    let refresh_token: String
  }

  struct GetAccessTokenPayload: Encodable {
    let grant_type = "authorization_code"
    let code: String
    let redirect_uri = RedditAPI.appRedirectURI
  }
}

struct ListingChild<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let kind: String?
  var data: T?
}

struct Listing<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let kind: String?
  var data: ListingData<T>?
}

struct ListingData<T: Codable & Hashable>: Codable, Defaults.Serializable, Hashable {
  let after: String?
  let dist: Int?
  let modhash: String?
  let geo_filter: String?
  var children: [ListingChild<T>]?
}

enum Either<A: Codable & Hashable, B: Codable & Hashable>: Codable, Hashable {
  case first(A)
  case second(B)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    do {
      let firstType = try container.decode(A.self)
      self = .first(firstType)
    } catch let firstError {
      do {
        let secondType = try container.decode(B.self)
        self = .second(secondType)
      } catch let secondError {
        let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Type mismatch for both types.", underlyingError: Swift.DecodingError.typeMismatch(Any.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "First type error: \(firstError). Second type error: \(secondError)")))
        throw DecodingError.dataCorrupted(context)
      }
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .first(value):
      try container.encode(value)
    case let .second(value):
      try container.encode(value)
    }
  }
}
