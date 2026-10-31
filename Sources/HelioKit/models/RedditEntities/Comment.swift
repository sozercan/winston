//
//  Comment.swift
//  Helio
//
//  Created by Igor Marcossi on 28/06/23.
//

import CoreData
import Defaults
import Foundation
import NukeUI
import SwiftUI

typealias Comment = GenericRedditEntity<CommentData, CommentHelioData>

enum RandomErr: Error {
  case oops
}

enum CommentParentElement {
  case post(Binding<[Comment]>)
  case comment(Comment)
}

extension Comment {
  static var prefix = "t1"
  var selfPrefix: String {
    Self.prefix
  }

  convenience init(data: T, kind: String? = nil, parent: [GenericRedditEntity<T, B>]? = nil) {
    self.init(data: data, typePrefix: "\(Comment.prefix)_")
    if let parent {
      self.parentHelio = parent
    }
    self.setupHelioData()
    self.kind = kind

    if let replies = self.data?.replies {
      switch replies {
      case .first:
        break
      case let .second(listing):
        self.childrenHelio = listing.data?.children?.compactMap { x in
          if let innerData = x.data {
            return Comment(data: innerData, kind: x.kind, parent: self.childrenHelio)
          }
          return nil
        } ?? []
      }
    }
  }

  /// Loads a comment known only by id (a link to it inside a post).
  func fetchItself() {
    let fullname = fullname
    Task(priority: .utility) {
      if let data = await RedditInfoLoader.shared.comment(fullname) {
        await MainActor.run {
          withAnimation {
            self.data = data
            if self.helioData == nil {
              self.setupHelioData()
            }
          }
        }
      }
    }
  }

  func setupHelioData() {
    self.helioData = .init()
//    guard let helioData = self.helioData, let data = self.data else { return }
//    let theme = InMemoryTheme.shared.currentTheme.comments.theme
//    let cs: ColorScheme = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
  }

  convenience init(message: Message) throws {
    if let message = message.data {
      var commentData = CommentData(id: message.id)
      commentData.subreddit_id = nil
      commentData.subreddit = message.subreddit
      commentData.likes = nil
      commentData.replies = .first("")
      commentData.saved = false
      commentData.archived = false
      commentData.count = nil
      commentData.author = message.author
      commentData.created_utc = message.created_utc
      commentData.send_replies = false
      commentData.parent_id = message.parent_id
      commentData.score = nil
      commentData.author_fullname = message.author_fullname
      commentData.author_flair_text = message.author_flair_text
      commentData.approved_by = nil
      commentData.mod_note = nil
      commentData.collapsed = false
      commentData.body = message.body
      commentData.top_awarded_type = nil
      commentData.name = message.name
      commentData.is_submitter = nil
      commentData.downs = nil
      commentData.children = nil
      commentData.body_html = message.body_html
      commentData.permalink = nil
      commentData.created = message.created
      commentData.link_id = nil
      commentData.link_title = message.link_title
      commentData.subreddit_name_prefixed = message.subreddit_name_prefixed
      commentData.depth = nil
      commentData.author_flair_background_color = nil
      commentData.collapsed_because_crowd_control = nil
      commentData.mod_reports = nil
      commentData.num_reports = nil
      commentData.ups = nil
      self.init(data: commentData, typePrefix: "\(Comment.prefix)_")
      self.helioData = .init()
    } else {
      throw RandomErr.oops
    }
  }

  static func initMultiple(datas: [ListingChild<T>], parent: [GenericRedditEntity<T, B>]? = nil) -> [Comment] {
    let comments = datas.compactMap { x in
      x.data.map { Comment(data: $0, kind: x.kind, parent: parent) }
    }
    func walk(_ comments: [Comment], _ body: (Comment) -> Void) {
      for comment in comments {
        body(comment)
        walk(comment.childrenHelio, body)
      }
    }
    var ids: [String] = []
    walk(comments) { ids.append($0.id) }
    // toggleCollapsed stores the entity id, which has the kind appended (e.g. "abct1").
    let context = PersistenceController.shared.primaryBGContext
    let fetchRequest = NSFetchRequest<CollapsedComment>(entityName: "CollapsedComment")
    fetchRequest.predicate = NSPredicate(format: "commentID IN %@", ids)
    let collapsedIDs = context.performAndWait { Set(((try? context.fetch(fetchRequest)) ?? []).compactMap(\.commentID)) }
    // Keep Reddit's own collapsed flag (low score, crowd control) unless the user collapsed it.
    if !collapsedIDs.isEmpty {
      walk(comments) {
        if collapsedIDs.contains($0.id) {
          $0.data?.collapsed = true
        }
      }
    }
    return comments
  }

  /// Collapses or expands the comment (toggles when `collapsed` is nil) and stores the result.
  /// The record follows the new state: Reddit can collapse a comment that has no record.
  func toggleCollapsed(_ collapsed: Bool? = nil, optimistic: Bool = false) {
    let newState = collapsed ?? !(data?.collapsed ?? false)
    if optimistic, data?.collapsed != newState {
      data?.collapsed = newState
    }

    let context = PersistenceController.shared.primaryBGContext

    context.performAndWait {
      let fetchRequest = NSFetchRequest<CollapsedComment>(entityName: "CollapsedComment")
      fetchRequest.predicate = NSPredicate(format: "commentID == %@", id as CVarArg)

      do {
        let results = try context.fetch(fetchRequest)

        if newState, results.isEmpty {
          let newCollapsedComment = CollapsedComment(context: context)
          newCollapsedComment.commentID = id
          try context.save()
        } else if !newState, !results.isEmpty {
          results.forEach(context.delete)
          try context.save()
        }

        if !optimistic {
          data?.collapsed = newState
        }
      } catch {
        context.rollback()
        print("Error fetching or updating data in Core Data: \(error)")
      }
    }
  }

  func loadChildren(parent: CommentParentElement, postFullname: String, avatarSize: Double, post: Post?) async {
    if let kind, kind == "more", let data, let count = data.count, let parent_id = data.parent_id, let childrenIDS = data.children {
      let actualID = id
      //      if actualID.hasSuffix("-more") {
      //        actualID.removeLast(5)
      //      }

      let childrensLimit = 25

      if let children = await RedditAPI.shared.fetchMoreReplies(comments: count > 0 ? Array(childrenIDS.prefix(childrensLimit)) : [String(parent_id.dropFirst(3))], moreID: actualID, postFullname: postFullname, dropFirst: count == 0) {
        let parentID = data.parent_id ?? ""
        //        switch parent {
        //        case .comment(let comment):
        //          if let name = comment.data?.parent_id ?? comment.data?.name {
        //              parentID = name
        //          }
        //        case .post(_):
        //          if let postID = children[0].data?.link_id {
        //            parentID = postID
        //          }
        //        }

        let loadedComments: [Comment] = nestComments(children, parentID: parentID)

        Task(priority: .utility) { [loadedComments] in
          await RedditAPI.shared.updateCommentsWithAvatar(comments: loadedComments, avatarSize: avatarSize)
          await post?.saveMoreComments(comments: loadedComments)
        }

        await MainActor.run { [loadedComments] in
          switch parent {
          case let .comment(comment):
            if let index = comment.childrenHelio.firstIndex(where: { $0.id == id }) {
              withAnimation {
                if (self.data?.children?.count ?? 0) <= 25 {
                  comment.childrenHelio.remove(at: index)
                } else {
                  self.data?.children?.removeFirst(childrensLimit)
                  if let _ = self.data?.count {
                    self.data?.count! -= children.count
                  }
                }
                comment.childrenHelio.insert(contentsOf: loadedComments, at: index)
              }
            }
          case let .post(postArr):
            if let index = postArr.wrappedValue.firstIndex(where: { $0.id == id }) {
              withAnimation {
                if (self.data?.children?.count ?? 0) <= 25 {
                  postArr.wrappedValue.remove(at: index)
                } else {
                  self.data?.children?.removeFirst(childrensLimit)
                  if let _ = self.data?.count {
                    self.data?.count! -= children.count
                  }
                }
                postArr.wrappedValue.insert(contentsOf: loadedComments, at: index)
              }
            }
          }
        }
      }
    }
  }

  func reply(_ text: String) async -> Bool {
    if let fullname = data?.name {
      let result = await RedditAPI.shared.newReply(text, fullname) ?? false
      if result, let data {
        var newComment = CommentData(id: UUID().uuidString)
        newComment.subreddit_id = data.subreddit_id
        newComment.subreddit = data.subreddit
        newComment.likes = true
        newComment.saved = false
        newComment.archived = false
        newComment.count = 0
        let author = await MainActor.run { RedditAPI.shared.me?.data }
        newComment.author = author?.name ?? ""
        newComment.created_utc = nil
        newComment.send_replies = nil
        newComment.parent_id = id
        newComment.score = nil
        newComment.author_fullname = "t2_\(author?.id ?? "")"
        newComment.approved_by = nil
        newComment.mod_note = nil
        newComment.collapsed = nil
        newComment.body = text
        newComment.top_awarded_type = nil
        newComment.name = nil
        newComment.is_submitter = nil
        newComment.downs = 0
        newComment.children = nil
        newComment.body_html = nil
        newComment.permalink = nil
        newComment.created = Double(Int(Date().timeIntervalSince1970))
        newComment.link_id = data.link_id
        newComment.link_title = data.link_title
        newComment.subreddit_name_prefixed = data.subreddit_name_prefixed
        newComment.depth = (data.depth ?? 0) + 1
        newComment.author_flair_background_color = nil
        newComment.collapsed_because_crowd_control = nil
        newComment.mod_reports = nil
        newComment.num_reports = nil
        newComment.ups = 1
        await MainActor.run { [newComment] in
          withAnimation {
            childrenHelio.append(Comment(data: newComment))
          }
        }
      }
      return result
    }
    return false
  }

  func saveToggle() async -> Bool {
    if let data, let fullname = data.name {
      let prev = data.saved ?? false
      await MainActor.run {
        withAnimation {
          self.data?.saved = !prev
        }
      }
      let success = await RedditAPI.shared.save(!prev, id: fullname)
      if !(success ?? false) {
        await MainActor.run {
          withAnimation {
            self.data?.saved = prev
          }
        }
        return false
      }
      return true
    }
    return false
  }

  func vote(action: RedditAPI.VoteAction) async -> Bool? {
    let oldLikes = data?.likes
    let oldUps = data?.ups ?? 0
    var newAction = action
    newAction = action.boolVersion() == oldLikes ? .none : action
    await MainActor.run { [newAction] in
      withAnimation {
        data?.likes = newAction.boolVersion()
        data?.ups = oldUps + (action.boolVersion() == oldLikes ? oldLikes == nil ? 0 : -(Int(action.rawValue) ?? 0) : (Int(action.rawValue) ?? 1) * (oldLikes == nil ? 1 : 2))
      }
    }
    let result = await RedditAPI.shared.vote(newAction, id: "\(typePrefix ?? "")\(id.dropLast(2))")
    if result == nil || !result! {
      await MainActor.run { [oldLikes] in
        withAnimation {
          data?.likes = oldLikes
          data?.ups = oldUps
        }
      }
    }
    return result
  }

  func edit(_ newBody: String) async -> Bool? {
    if let data, let name = data.name {
      //      let oldBody = data.body
      //      await MainActor.run {
      //        withAnimation {
      //          self.data?.body = newBody
      //        }
      //      }
      let result = await RedditAPI.shared.edit(fullname: name, newText: newBody)
      if result ?? false {
        await MainActor.run {
          withAnimation {
            self.data?.body = newBody
          }
        }
      }
      //      if result == nil || !result! {
      //        await MainActor.run {
      //          withAnimation {
      //            self.data?.body = oldBody
      //          }
      //        }
      //      }
      return result
    }
    return nil
  }

  func del() async -> Bool? {
    if let name = data?.name {
      let result = await RedditAPI.shared.delete(fullname: name)
      if result ?? false, let parentHelio = self.parentHelio {
        let newParent = parentHelio.filter { $0.id != id }
        await MainActor.run {
          withAnimation {
            self.parentHelio = newParent
          }
        }
      }
      return result
    }
    return nil
  }
}

@Observable
class CommentHelioData: Hashable {
  static func == (lhs: CommentHelioData, rhs: CommentHelioData) -> Bool {
    lhs.avatarImageRequest?.url == rhs.avatarImageRequest?.url
  }

  //  var permaURL: URL? = nil
  //  @Published var extractedMedia: MediaExtractedType? = nil
  //  var subreddit: Subreddit?
  //  @Published var mediaImageRequest: [ImageRequest] = []
  var avatarImageRequest: ImageRequest?
  var commentBodySize: CGSize = .zero
  var bodyAttr: NSAttributedString?

  func hash(into hasher: inout Hasher) {
    hasher.combine(avatarImageRequest?.description)
    hasher.combine(commentBodySize)
  }
}

struct CommentData: GenericRedditEntityDataType {
  init(id: String) {
    self.id = id
  }

  var subreddit_id: String?
  ///  let approved_at_utc: Int?
  ///  let author_is_blocked: Bool?
  ///  let comment_type: String?
  ///  let awarders: [String]?
  ///  let mod_reason_by: String?
  ///  let banned_by: String?
  ///  let author_flair_type: String?
  ///  let total_awards_received: Int?
  var subreddit: String?
  //  let author_flair_template_id: String?
  var likes: Bool?
  var replies: Either<String, Listing<CommentData>>?
  //  let user_reports: [String]?
  var saved: Bool?
  var id: String
  //  let banned_at_utc: String?
  //  let mod_reason_title: String?
  //  let gilded: Int?
  var archived: Bool?
  //  let collapsed_reason_code: String?
  //  let no_follow: Bool?
  var count: Int?
  var author: String?
  //  let can_mod_post: Bool?
  var created_utc: Double?
  var send_replies: Bool?
  var parent_id: String?
  var score: Int?
  var author_fullname: String?
  var approved_by: String?
  var mod_note: String?
  //  let all_awardings: [String]?
  var collapsed: Bool?
  var body: String?
  //  let edited: Bool?
  var top_awarded_type: String?
  //  let author_flair_css_class: String?
  var name: String?
  var is_submitter: Bool?
  var downs: Int?
  //  let author_flair_richtext: [String]?
  //  let author_patreon_flair: Bool?
  var children: [String]?
  var body_html: String?
  //  let removal_reason: String?
  //  let collapsed_reason: String?
  //  let distinguished: String?
  //  let associated_award: String?
  //  let stickied: Bool?
  //  let author_premium: Bool?
  //  let can_gild: Bool?
  //  let gildings: [String: String]?
  //  let unrepliable_reason: String?
  //  let author_flair_text_color: String?
  /// Reddit hides scores on new comments in some subreddits.
  var score_hidden: Bool?
  var permalink: String?
  //  let subreddit_type: String?
  //  let locked: Bool?
  //  let report_reasons: String?
  var created: Double?
  var author_flair_text: String?
  //  let treatment_tags: [String]?
  var link_id: String?
  var link_title: String?
  var subreddit_name_prefixed: String?
  //  let controversiality: Int?
  var depth: Int?
  var author_flair_background_color: String?
  var collapsed_because_crowd_control: String?
  var mod_reports: [String]?
  var num_reports: Int?
  var ups: Int?
  var helioSelecting: Bool? = false

  var badgeKit: BadgeKit {
    BadgeKit(
      numComments: 0,
      ups: ups ?? 0,
      saved: saved ?? false,
      author: author ?? "",
      authorFullname: author_fullname ?? "",
      userFlair: author_flair_text ?? "",
      created: created ?? 0,
    )
  }

  var votesKit: VotesKit {
    VotesKit(ups: ups ?? 0, ratio: 0, likes: likes, id: id)
  }
}

// Encode AttributedString manually
// func encode(to encoder: Encoder) throws {
//   var container = encoder.container(keyedBy: CodingKeys.self)
//
//   // ...encode all other properties...
//
//   if let helioBodyAttr = helioBodyAttr {
//       try container.encode(helioBodyAttr.markdownRepresentation, forKey: .helioBodyAttr)
//   }
// }

struct Gildings: Codable {}

struct CommentSort: Codable, Identifiable {
  var icon: String
  var value: String
  var id: String {
    value
  }
}

enum CommentSortOption: Codable, CaseIterable, Identifiable, Defaults.Serializable {
  var id: String {
    self.rawVal.id
  }

  case confidence
  case new
  case top
  case controversial
  case old
  case random
  case qa
  case live

  var rawVal: SubListingSort {
    switch self {
    case .confidence:
      SubListingSort(icon: "flame", value: "confidence")
    case .new:
      SubListingSort(icon: "newspaper", value: "new")
    case .top:
      SubListingSort(icon: "trophy", value: "top")
    case .controversial:
      SubListingSort(icon: "figure.fencing", value: "controversial")
    case .old:
      SubListingSort(icon: "clock.arrow.circlepath", value: "old")
    case .random:
      SubListingSort(icon: "dice", value: "random")
    case .qa:
      SubListingSort(icon: "bubble.left.and.bubble.right", value: "qa")
    case .live:
      SubListingSort(icon: "dot.radiowaves.left.and.right", value: "live")
    }
  }
}
