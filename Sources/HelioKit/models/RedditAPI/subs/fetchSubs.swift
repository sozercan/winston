//
//  fetchSubs.swift
//  Helio
//
//  Created by Igor Marcossi on 28/06/23.
//

import Alamofire
import CoreData
import Defaults
import Foundation
import SwiftUI

func cleanSubs(_ subs: [ListingChild<SubredditData>]) -> [ListingChild<SubredditData>] {
  subs.compactMap { y in
    var x = y
    x.data?.description = ""
    x.data?.description_html = ""
    x.data?.public_description = ""
    x.data?.public_description_html = ""
    x.data?.submit_text_html = ""
    x.data?.submit_text = ""
    return x
  }
}

extension RedditAPI {
  /// `account`: whose subscriptions; the selected account when nil.
  func fetchAllSubs(after: String? = nil, accumulatedSubs: [ListingChild<SubredditData>]? = nil, account: RedditCredential? = nil) async -> [ListingChild<SubredditData>]? {
    // Base case: If 'after' is nil and some subs are already accumulated, simply return them.
    if let after, after.isEmpty, let accumulatedSubs {
      return accumulatedSubs
    }

    guard account != nil || Defaults[.GeneralDefSettings].redditCredentialSelectedID != nil else { return [] }

    let params = FetchSubsPayload(limit: 100, after: after)

    switch await self.doRequest("\(RedditAPI.redditApiURLBase)/subreddits/mine/subscriber.json", method: .get, params: params, paramsLocation: .queryString, decodable: Listing<SubredditData>.self, altCredential: account) {
    case let .success(data):
      var newAccumulatedSubs = accumulatedSubs ?? []
      if let fetchedSubs = data.data?.children {
        newAccumulatedSubs += fetchedSubs.filter { $0.data?.subreddit_type != "user" }
      }

      if let dataAfter = data.data?.after, !dataAfter.isEmpty {
        // Recursive call with the new 'after' value and the updated accumulated subs.
        return await fetchAllSubs(after: dataAfter, accumulatedSubs: newAccumulatedSubs, account: account)
      } else {
        // All subs fetched, return the accumulated result
        return newAccumulatedSubs
      }
    case let .failure(error):
      print(error)
      // A partial list would make the sync drop every subscription on the pages that failed.
      return nil
    }
  }

  /// Whether the subscriptions were saved.
  @MainActor
  @discardableResult
  func updateSubsInCoreData(
    with subs: [ListingChild<SubredditData>],
    account: RedditCredential? = nil,
    credentialsManager: RedditCredentialsManager = .shared,
    context: NSManagedObjectContext? = nil,
  ) async -> Bool {
    guard
      let credential = account ?? credentialsManager.selectedCredential,
      let authorization = credential.authorizationID,
      credentialsManager.containsAuthorization(authorization)
    else { return false }
    let credentialID = credential.id
    let context = context ?? PersistenceController.shared.container.newBackgroundContext()

    // Keep grant membership and persistence in one main-actor turn: no replacement can
    // slip between the check and the save while the context is queued.
    return context.performAndWait {
      let fetchRequest = NSFetchRequest<CachedSub>(entityName: "CachedSub")
      fetchRequest.predicate = NSPredicate(format: "helioCredentialID == %@", credentialID as CVarArg)
      do {
        let results = try context.fetch(fetchRequest)

        // Deduplicate existing records (CloudKit can re-sync duplicates)
        var seenUUIDs: [String: CachedSub] = [:]
        for cachedSub in results {
          let uuid = cachedSub.uuid ?? ""
          if let existing = seenUUIDs[uuid] {
            // Keep the first, delete duplicates
            context.delete(cachedSub)
          } else {
            seenUUIDs[uuid] = cachedSub
          }
        }
        let dedupedResults = Array(seenUUIDs.values)

        for sub in subs.compactMap(\.data) {
          if let existingSub = dedupedResults.first(where: { $0.uuid == sub.name }) {
            existingSub.update(data: sub, credentialID: credentialID)
          } else {
            let newSub = CachedSub(context: context)
            newSub.update(data: sub, credentialID: credentialID)
          }
        }

        // Delete CachedSubs not present in the fetched subs
        let currentSubsSet = Set(subs.compactMap { $0.data?.name })
        for cachedSub in dedupedResults {
          if !currentSubsSet.contains(cachedSub.uuid ?? "") {
            context.delete(cachedSub)
          }
        }

        // Save changes
        try withAnimation {
          try context.save()
        }
        return true
      } catch {
        print("Failed to fetch or save CachedSubs: \(error)")
        return false
      }
    }
  }

  @discardableResult
  func fetchSubsAndSyncCoreData(account: RedditCredential? = nil) async -> Bool {
    guard let credential = await MainActor.run(body: { account ?? RedditCredentialsManager.shared.selectedCredential }), let fetchedSubs = await fetchAllSubs(account: credential) else { return false }
    return await updateSubsInCoreData(with: fetchedSubs, account: credential)
  }

  //  func fetchSubs(after: String? = nil) async -> [ListingChild<SubredditData>]? {
  //    guard let currentCredentialID = Defaults[.GeneralDefSettings].redditCredentialSelectedID else { return [] }
  //
  //    var params = FetchSubsPayload(limit: 100)
  //
  //    if let after = after {
  //      params.after = after
  //    }
  //    switch await self.doRequest("\(RedditAPI.redditApiURLBase)/subreddits/mine/subscriber.json", method: .get, params: params, paramsLocation: .queryString, decodable: Listing<SubredditData>.self)  {
  //    case .success(let data):
  //      var finalSubs: [ListingChild<SubredditData>] = []
  //      if let dataAfter = data.data?.after, !dataAfter.isEmpty, let extraFetchedSubs = await fetchSubs(after: dataAfter) {
  //        finalSubs += extraFetchedSubs
  //      }
  //      if let fetchedSubs = data.data?.children {
  //        finalSubs += fetchedSubs
  //      }
  //      if after != nil {
  //        return finalSubs
  //      }
  //
  //      finalSubs = finalSubs.filter { $0.data?.subreddit_type != "user" }
  ////      print("aosmao", finalSubs.map { ($0.data?.name, $0.data?.display_name) })
  //      let context = PersistenceController.shared.container.viewContext
  //
  //      let fetchRequest = NSFetchRequest<CachedSub>(entityName: "CachedSub")
  //      fetchRequest.predicate = NSPredicate(format: "helioCredentialID == %@", currentCredentialID as CVarArg)
  //      let results = (context.performAndWait { try? context.fetch(fetchRequest) }) ?? []
  //      results.forEach { cachedSub in
  //        context.performAndWait {
  //          if !finalSubs.contains(where: { listingChild in
  //            cachedSub.uuid == listingChild.data?.name
  //          }) {
  //            context.delete(cachedSub)
  //          }
  //        }
  //      }
  //
  //      await context.perform(schedule: .enqueued) {
  //        cleanSubs(finalSubs).compactMap { $0.data }.forEach { x in
  //          if let found = results.first(where: { $0.uuid == x.name }) {
  //            found.update(data: x, credentialID: currentCredentialID)
  //          } else {
  //            _ = CachedSub(data: x, context: context, credentialID: currentCredentialID)
  //          }
  //        }
  //      }
  //
  //      await context.perform(schedule: .enqueued) {
  //        try? context.save()
  //      }
  //      return nil
  //    case .failure(let error):
  //      print(error)
  //      return nil
  //    }
  //  }

  struct FetchSubsPayload: Codable {
    var limit: Int
    var after: String?
    //    var show = "all"
    var count = 0
    var raw_json = 1
  }
}
