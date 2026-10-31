//
//  fetchUserOverview.swift
//  Helio
//
//  Created by Igor Marcossi on 01/07/23.
//

import Alamofire
import Defaults
import Foundation

extension RedditAPI {
  func fetchUserOverview(_ userName: String, _ dataTypeFilter: String? = nil, _ after: String? = nil, limit: Int = Defaults[.SubredditFeedDefSettings].chunkLoadSize) async -> ([Either<PostData, CommentData>]?, String?)? {
    var endpoint: String

    if let dataTypeFilter, !dataTypeFilter.isEmpty {
      if dataTypeFilter.lowercased() == "posts" {
        endpoint = "\(RedditAPI.redditApiURLBase)/user/\(userName)/submitted.json"
      } else if dataTypeFilter.lowercased() == "comments" {
        endpoint = "\(RedditAPI.redditApiURLBase)/user/\(userName)/comments.json"
      } else {
        print("Invalid dataTypeFilter")
        return nil
      }
    } else {
      endpoint = "\(RedditAPI.redditApiURLBase)/user/\(userName)/overview.json"
    }

    var urlComponents = URLComponents(string: endpoint)!

    urlComponents.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
    if let after {
      urlComponents.queryItems?.append(URLQueryItem(name: "after", value: after))
    }

    guard let requestURL = urlComponents.url else {
      print("Error: Unable to create a valid URL")
      return nil
    }

    switch await self.doRequest(requestURL.absoluteString, method: .get, decodable: Listing<Either<PostData, CommentData>>.self) {
    case let .success(data):
      return (data.data?.children?.map(\.data).compactMap(\.self), data.data?.after)
    case let .failure(error):
      print(error)
      return nil
    }
  }
}
