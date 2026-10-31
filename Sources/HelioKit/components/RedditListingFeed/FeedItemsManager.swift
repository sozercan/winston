//
//  FeedItemsManager.swift
//  Helio
//
//  Created by Igor Marcossi on 26/01/24.
//

import Defaults
import Nuke
import SwiftUI

@MainActor
@Observable
class FeedItemsManager<S> {
  typealias ItemsFetchFn = @MainActor (_ lastElementId: String?, _ sorting: S?, _ searchQuery: String?, _ flair: String?, _ limit: Int) async -> (entities: [RedditEntityType]?, after: String?)?

  /// `onlyReadPosts`: paging stopped after several pages in a row held only hidden read posts.
  enum DisplayMode: String { case loading, empty, items, endOfFeed, error, onlyReadPosts }

  @ObservationIgnored private var currentTask: Task<Void, Never>?
  @ObservationIgnored private var currentRequestID: UUID?

  /// One immutable query for the whole page chain, including pages hidden as already read.
  private struct Request {
    let sorting: S?
    let searchQuery: String?
    let flair: String?
    let chunkSize: Int
  }

  /// Set once the feed starts loading its first page.
  @ObservationIgnored private(set) var initialLoadStarted = false
  private(set) var displayMode: DisplayMode = .loading
  private(set) var isLoadingMore = false
  @ObservationIgnored private var failedLoadingMore = false
  var loadingPinned = false
  var pinnedPosts: [Post] = []
  private(set) var entities: [RedditEntityType] = [] {
    didSet { indexByID = Dictionary(entities.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }) }
  }

  /// Rows look their position up as they appear; searching `entities` for each was quadratic.
  @ObservationIgnored private var indexByID: [String: Int] = [:]
  private var loadedEntitiesIds: Set<String> = []
  private(set) var lastElementId: String?
  var sorting: S?

  var searchQuery = Debouncer("")
  var selectedFilter: ShallowCachedFilter?

  var chunkSize: Int
  private let fetchFn: ItemsFetchFn
  private let prefetchRange = 2
  /// Whether this feed drops already-read posts when "Hide read posts" is on.
  private let hideReadPosts: Bool
  /// Pages fetched in a row whose posts were all hidden, before giving up.
  private let maxHiddenPagesInARow = 5

  init(sorting: S?, hideReadPosts: Bool = false, fetchFn: @escaping ItemsFetchFn) {
    self.sorting = sorting
    self.hideReadPosts = hideReadPosts
    self.fetchFn = fetchFn
    self.chunkSize = Defaults[.SubredditFeedDefSettings].chunkLoadSize
  }

  func loadIfNeeded() async {
    guard !initialLoadStarted else { return }
    await reload()
  }

  func reload(clearItems: Bool = false) async {
    guard !Task.isCancelled else { return }
    await startFetch(loadingMore: false, clearItems: clearItems)?.value
  }

  func loadMore() async {
    await fetchCaller(loadingMore: true)
  }

  func retry() async {
    await fetchCaller(loadingMore: failedLoadingMore)
  }

  private func fetchCaller(loadingMore: Bool) async {
    // A row task can be cancelled by a refresh before it ever starts running.
    guard !Task.isCancelled else { return }
    await startFetch(loadingMore: loadingMore)?.value
  }

  /// Reserve the request synchronously, so rows appearing together share one page fetch.
  private func startFetch(loadingMore: Bool, clearItems: Bool = false) -> Task<Void, Never>? {
    if loadingMore {
      if let currentTask {
        return currentTask
      }
      guard lastElementId != nil, displayMode == .items || displayMode == .onlyReadPosts || displayMode == .error else { return nil }
    } else {
      currentTask?.cancel()
    }

    initialLoadStarted = true
    isLoadingMore = loadingMore
    if clearItems {
      entities = []
      loadedEntitiesIds = []
      lastElementId = nil
    }
    withAnimation { displayMode = loadingMore ? .items : .loading }
    let requestID = UUID()
    currentRequestID = requestID
    let request = Request(
      sorting: sorting,
      searchQuery: selectedFilter?.type == .custom ? selectedFilter?.text : searchQuery.debounced.isEmpty ? nil : searchQuery.debounced,
      flair: selectedFilter?.type != .custom ? selectedFilter?.text : nil,
      chunkSize: chunkSize,
    )
    let after = loadingMore ? lastElementId : nil
    let task = Task {
      await self.fetchPage(loadingMore: loadingMore, after: after, hiddenPagesInARow: 0, request: request, requestID: requestID)
      // A superseded task must not release a newer request's reservation.
      if self.currentRequestID == requestID {
        self.currentTask = nil
        self.currentRequestID = nil
        self.isLoadingMore = false
      }
    }
    currentTask = task
    return task
  }

  private func fetchPage(loadingMore: Bool, after lastElementId: String?, hiddenPagesInARow: Int, request: Request, requestID: UUID) async {
    guard currentRequestID == requestID, !Task.isCancelled else { return }
    let result = await fetchFn(lastElementId, request.sorting, request.searchQuery, request.flair, request.chunkSize)
    // Cancellation is cooperative: a network callback may still return data or an error.
    guard currentRequestID == requestID, !Task.isCancelled else { return }
    guard let (fetchedEntities, after) = result, let fetchedEntities else {
      failedLoadingMore = loadingMore
      withAnimation { displayMode = .error }
      return
    }

    // Without a cursor, the next fetch would start over from the first page.
    let reachedEnd = fetchedEntities.count < request.chunkSize || after == nil
    let shownEntities = withoutReadPosts(fetchedEntities)
    let onlyReadPosts = shownEntities.isEmpty && !fetchedEntities.isEmpty && !reachedEnd
    let skipPage = onlyReadPosts && hiddenPagesInARow < maxHiddenPagesInARow
    let gaveUp = onlyReadPosts && !skipPage

    if !loadingMore {
      withAnimation {
        displayMode = skipPage ? .items : gaveUp ? .onlyReadPosts : shownEntities.isEmpty ? .empty : reachedEnd ? .endOfFeed : .items
        entities = shownEntities
        self.lastElementId = after
        loadedEntitiesIds = Set(shownEntities.map(\.fullname))
      }
    } else {
      var newLoadedEntitiesIds = loadedEntitiesIds
      var newEntities = entities
      for entity in shownEntities where newLoadedEntitiesIds.insert(entity.fullname).inserted {
        newEntities.append(entity)
      }
      // Don't animate appending: it causes scroll jumps and builds every new row in one frame.
      displayMode = reachedEnd ? .endOfFeed : gaveUp ? .onlyReadPosts : .items
      entities = newEntities
      self.lastElementId = after
      loadedEntitiesIds = newLoadedEntitiesIds
    }

    if skipPage {
      isLoadingMore = true
      await fetchPage(loadingMore: true, after: after, hiddenPagesInARow: hiddenPagesInARow + 1, request: request, requestID: requestID)
    }
  }

  private func withoutReadPosts(_ entities: [RedditEntityType]) -> [RedditEntityType] {
    guard hideReadPosts, CachedDefaults[.PostLinkDefSettings].hideOnRead else { return entities }
    return entities.filter { entity in
      if case let .post(post) = entity {
        return !(post.data?.helioSeen ?? false)
      }
      return true
    }
  }

  /// On the main actor, like the rows calling it: rows appearing together must not each start
  /// loading the next page.
  func elementAppeared(entity: RedditEntityType) {
    guard let index = indexByID[entity.id] else { return }
    if displayMode == .items, !entities.isEmpty, index >= entities.count - 7, currentTask == nil {
      startFetch(loadingMore: true)
    }

    let start = index - prefetchRange < 0 ? 0 : index - prefetchRange
    let end = index + (prefetchRange + 1) > entities.count ? entities.count : index + (prefetchRange + 1)
    let toPrefetch = start < end ? Array(entities[start ..< end]) : []
    let reqs = getImgReqsFrom(toPrefetch)

    Post.prefetcher.startPrefetching(with: reqs)
  }

  func elementDisappeared(entity: RedditEntityType) {
    let reqs = getImgReqsFrom([entity])
    Post.prefetcher.stopPrefetching(with: reqs)
  }

  private func getImgReqsFrom(_ entities: [RedditEntityType]) -> [ImageRequest] {
    entities.reduce([] as [ImageRequest]) { partialResult, entity in
      var newPartial = partialResult
      switch entity {
      case let .post(post):
        if let avatarImgReq = post.helioData?.avatarImageRequest {
          newPartial.append(avatarImgReq)
        }
        if let extractedMedia = post.helioData?.extractedMedia {
          switch extractedMedia {
          case let .comment(comment):
            break
          case let .imgs(imgsExtracted):
            newPartial = newPartial + imgsExtracted.map(\.request)
          case let .link(link):
            if let imgReq = link.imageReq {
              newPartial.append(imgReq)
            }
          case let .video(video):
            break
          case let .yt(video):
            newPartial.append(video.thumbnailRequest)
          case .streamable:
            break
          case .repost:
            break
          case .post:
            break
          case .subreddit:
            break
          case .user:
            break
          }
        }
      default: break
      }
      return newPartial
    }
  }
}
