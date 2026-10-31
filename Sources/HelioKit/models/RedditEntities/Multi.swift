//
//  Multi.swift
//  Helio
//
//  Created by Igor Marcossi on 20/08/23.
//

import Defaults
import Foundation
import UIKit

typealias Multi = GenericRedditEntity<MultiData, AnyHashable>

extension Multi {
  static var prefix = "LabeledMulti"
  var selfPrefix: String {
    Self.prefix
  }

  convenience init(data: T) {
    self.init(data: data, typePrefix: "\(Post.prefix)_")
  }

  convenience init(id: String) {
    self.init(id: id, typePrefix: "\(Post.prefix)_")
  }

  func fetchData() async -> Bool? {
//    if let data = await RedditAPI.shared.fetchMultiInfo(id) {
//
//    }
    nil
  }

  func fetchPosts(sort: SubListingSortOption = .best, after: String? = nil, contentWidth: CGFloat = .screenW, limit: Int = Defaults[.SubredditFeedDefSettings].chunkLoadSize) async -> ([RedditEntityType]?, String?)? {
    if let data, let response = await RedditAPI.shared.fetchMultiPosts(path: data.path, sort: sort, after: after, limit: limit), let data = response.0 {
      return (Post.initMultiple(datas: data.compactMap(\.data), contentWidth: contentWidth).map { .post($0) }, response.1)
    }
    return nil
  }

  func delete() async -> Bool? {
    if let data {
      return await RedditAPI.shared.deleteMulti(data.path)
    }
    return nil
  }
}

struct MultiData: GenericRedditEntityDataType, Defaults.Serializable {
  var can_edit: Bool?
  let display_name, name: String
  var description_html: String?
  var num_subscribers: Int?
  var copied_from: String?
  var icon_url: String?
  var subreddits: [MultiSub]?
  var created_utc: Double?
  var created: Double?
  let visibility: MultiVisibility?
  var over_18: Bool?
  let path: String
  var key_color: String?
  var owner: String?
  var is_subscriber: Bool?
  var is_favorited: Bool?
  var description_md: String?
  var owner_id: String?
  var id: String {
    path
  }

  init(entity: CachedMulti) {
//    self.can_edit = entity.can_edit
    self.display_name = entity.display_name ?? ""
    self.name = entity.name ?? ""
    self.description_html = nil
    self.num_subscribers = nil
    self.copied_from = nil
    self.icon_url = entity.icon_url
    self.subreddits = entity.subsArray.map { x in
      let data = SubredditData(entity: x)
      return MultiSub(name: data.name, data: data)
    }
    self.created_utc = nil
    self.visibility = nil
    self.over_18 = entity.over_18
    self.path = entity.path ?? ""
    self.owner = nil
    self.key_color = entity.key_color
    self.is_subscriber = nil
    self.is_favorited = nil
    self.owner_id = nil
    self.description_md = nil
//    self.id = entity.uuid
  }
}

struct MultiSub: Codable, Hashable, Identifiable {
  let name: String
  var id: String {
    name
  }

  var data: SubredditData?
}

enum MultiVisibility: String, CaseIterable, Codable {
  case priv = "private"
  case pub = "public"
  case hid = "hidden"
}
