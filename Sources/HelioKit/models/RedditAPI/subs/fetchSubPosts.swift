//
//  fetchSubPosts.swift
//  Helio
//
//  Created by Igor Marcossi on 28/06/23.
//

import Alamofire
import Defaults
import Foundation

extension RedditAPI {
  func fetchSubPosts(_ id: String, limit: Int = Defaults[.SubredditFeedDefSettings].chunkLoadSize, sort: SubListingSortOption = .best, after: String? = nil) async -> ([ListingChild<Either<PostData, CommentData>>]?, String?)? {
    guard let account = await captureAccount(), let subID = buildSubID(id, sort, after, account: account) else { return nil }
    let params = FetchSubPostsPayload(limit: limit, after: after)

    let urlString = "\(RedditAPI.redditApiURLBase)\(subID)".replacingOccurrences(of: " ", with: "%20")

    switch await self.doRequest(urlString, method: .get, params: params, paramsLocation: .queryString, decodable: Listing<Either<PostData, CommentData>>.self, altCredential: account) {
    case let .success(data):
      return (data.data?.children, data.data?.after)
    case let .failure(error):
      print(error)
      return nil
    }
  }

  func fetchSavedPosts(_ id: String, after: String? = nil, searchText: String? = nil) async -> [Either<PostData, CommentData>]? {
    guard let account = await captureAccount(), let subID = buildSubID(id, nil, after, searchText, account: account) else { return nil }
    let limit = Defaults[.SubredditFeedDefSettings].chunkLoadSize
    let params = FetchSubsPayload(limit: limit, after: after)

    let urlString = "\(RedditAPI.redditApiURLBase)\(subID)".replacingOccurrences(of: " ", with: "%20")

    switch await self.doRequest(urlString, method: .get, params: params, paramsLocation: .queryString, decodable: Listing<Either<PostData, CommentData>>.self, altCredential: account) {
    case let .success(data):
      return data.data?.children?.map(\.data).compactMap(\.self)
    case let .failure(error):
      print(error)
      return nil
    }
  }

  private func buildSubID(_ id: String, _ sort: SubListingSortOption?, _ after: String?, _ searchText: String? = nil, account: RedditCredential) -> String? {
    let appendedFileType = ".json"
    var subID = ""

    if id != savedKeyword {
      subID = id == "" ? "/" : id.hasPrefix("/r/") ? id : "/r/\(id)"
    } else if let username = account.userName, !username.isEmpty {
      subID = "/user/\(username)/saved"
    } else {
      return nil
    }

    subID = !subID.hasSuffix("/") ? "\(subID)/" : subID

    if searchText != nil {
      subID += "search\(appendedFileType)"
    } else {
      if let sort {
        switch sort {
        case .best:
          subID += "best\(appendedFileType)"
        case .hot:
          subID += "hot\(appendedFileType)"
        case .new:
          subID += "new\(appendedFileType)"
        case let .top(topSortOption):
          subID += "top\(appendedFileType)"
          subID += buildTopSortQuery(topSortOption)
        case .controversial:
          subID += "controversial\(appendedFileType)"
        }
      }
    }

    if let searchText {
      subID += subID.contains("?") ? "&q=\(searchText)" : "?q=\(searchText)"
      subID += "&restrict_sr=on"

      // Add preferred sort to search url
      subID += "&sort=\(Defaults[.SubredditFeedDefSettings].preferredSearchSort)"
    }

    if let after {
      subID += subID.contains("?") ? "&after=\(after)" : "?after=\(after)"
    }

    return subID
  }

  private func buildTopSortQuery(_ topSortOption: SubListingSortOption.TopListingSortOption) -> String {
    switch topSortOption {
    case .hour:
      "?t=hour"
    case .day:
      "?t=day"
    case .week:
      "?t=week"
    case .month:
      "?t=month"
    case .year:
      "?t=year"
    case .all:
      "?t=all"
    }
  }

  struct FetchSubPostsPayload: Codable {
    var limit: Int
    var after: String?
    var count: Int
    var f: String?
    var raw_json: Int

    init(limit: Int, after: String? = nil, count: Int = 0, flair: String? = nil, raw_json: Int = 1) {
      self.limit = limit
      self.after = after
      self.count = count
      if let flair {
        self.f = "flair_name:\"\(flair)\""
      }
      self.raw_json = raw_json
    }
  }
}
