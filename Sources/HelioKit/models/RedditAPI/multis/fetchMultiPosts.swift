//
//  fetchMultiPosts.swift
//  Helio
//
//  Created by Igor Marcossi on 20/08/23.
//

import Alamofire
import Defaults
import Foundation

extension RedditAPI {
  func fetchMultiPosts(path: String, sort: SubListingSortOption = .best, after: String? = nil, limit: Int = Defaults[.SubredditFeedDefSettings].chunkLoadSize) async -> ([ListingChild<PostData>]?, String?)? {
    let params = FetchSubsPayload(limit: limit, after: after)
    switch await self.doRequest("\(RedditAPI.redditApiURLBase)\(path).json", method: .get, params: params, paramsLocation: .queryString, decodable: Listing<PostData>.self) {
    case let .success(data):
      return (data.data?.children, data.data?.after)
    case let .failure(error):
      print(error)
      return nil
    }
  }
}
