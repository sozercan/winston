//
//  fetchMe.swift
//  Helio
//
//  Created by Igor Marcossi on 01/07/23.
//

import Alamofire
import Foundation

extension RedditAPI {
  /// Fetches profile data only. Selected-account publication belongs to the credentials manager.
  func fetchMe(altCredential: RedditCredential? = nil, saveToken: Bool = true) async -> UserData? {
    switch await doRequest("\(RedditAPI.redditApiURLBase)/api/v1/me", method: .get, decodable: UserData.self, altCredential: altCredential, saveToken: saveToken) {
    case let .success(data): data
    case .failure: nil
    }
  }
}
