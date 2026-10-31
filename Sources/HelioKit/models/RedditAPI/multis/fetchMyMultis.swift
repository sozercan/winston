//
//  fetchMyMultis.swift
//  Helio
//
//  Created by Igor Marcossi on 20/08/23.
//

import Alamofire
@preconcurrency import CoreData
import Defaults
import Foundation
import os
import SwiftUI

extension RedditAPI {
  /// `account`: whose multis; the selected account when nil.
  func fetchMyMultis(account: RedditCredential? = nil) async -> Bool {
    guard let credential = await MainActor.run(body: { account ?? RedditCredentialsManager.shared.selectedCredential }) else { return false }

    let params = FetchMyMultisPayload()

    switch await self.doRequest("\(RedditAPI.redditApiURLBase)/api/multi/mine", method: .get, params: params, paramsLocation: .queryString, decodable: [MultiContainerResponse].self, altCredential: credential) {
    case let .success(data):
      return await updateMultisInCoreData(with: data, account: credential)
    case let .failure(error):
      print(error)
      return false
    }
  }

  @MainActor
  func updateMultisInCoreData(
    with data: [MultiContainerResponse],
    account: RedditCredential,
    credentialsManager: RedditCredentialsManager = .shared,
    context: NSManagedObjectContext? = nil,
  ) async -> Bool {
    guard let authorization = account.authorizationID, credentialsManager.containsAuthorization(authorization) else { return false }
    let currentCredentialID = account.id
    let context = context ?? PersistenceController.shared.container.newBackgroundContext()

    // No suspension between grant membership and persistence; account replacement is
    // serialized on the main actor with this context transaction.
    return context.performAndWait {
      let multisFetchRequest = NSFetchRequest<CachedMulti>(entityName: "CachedMulti")
      multisFetchRequest.predicate = NSPredicate(format: "helioCredentialID == %@", currentCredentialID as CVarArg)

      do {
        let existingMultis = try context.fetch(multisFetchRequest)
        let fetchedMultiIds = Set(data.compactMap { $0.data?.id })

        // Update or insert new multis
        for multiDataContainer in data {
          guard let multiData = multiDataContainer.data else { continue }

          if let existingMulti = existingMultis.first(where: { $0.uuid == multiData.id }) {
            existingMulti.update(multiData, credentialID: currentCredentialID)
          } else {
            _ = CachedMulti(data: multiData, context: context, credentialID: currentCredentialID)
          }
        }

        // Remove multis not found in fetched data
        for cachedMulti in existingMultis where !fetchedMultiIds.contains(cachedMulti.uuid ?? "") {
          context.delete(cachedMulti)
        }

        try withAnimation {
          try context.save()
        }
        return true
      } catch {
        Logger(subsystem: "com.sertacozercan.helio", category: "AccountListSync")
          .error("Failed to fetch or update multis: \(error.localizedDescription)")
        return false
      }
    }
  }

  //  func fetchMyMultis() async -> Bool? {
  //    guard let currentCredentialID = RedditCredentialsManager.shared.selectedCredential?.id else { return nil }
  //
  //    let params = FetchMyMultisPayload()
  //
  //    switch await self.doRequest("\(RedditAPI.redditApiURLBase)/api/multi/mine", method: .get, params: params, paramsLocation: .queryString, decodable: [MultiContainerResponse].self) {
  //    case .success(let data):
  //      let context = PersistenceController.shared.container.newBackgroundContext()
  //
  //      let multisFetchRequest = NSFetchRequest<CachedMulti>(entityName: "CachedMulti")
  //      multisFetchRequest.predicate = NSPredicate(format: "helioCredentialID == %@", currentCredentialID as CVarArg)
  //      let multisResults = (context.performAndWait { try? context.fetch(multisFetchRequest) }) ?? []
  //
  //      data.forEach { c in
  //        if let data = c.data {
  //          return context.performAndWait {
  //            if let found = multisResults.first(where: { $0.uuid == data.id }) {
  //              found.update(data, credentialID: currentCredentialID)
  //            } else {
  //              _ = CachedMulti(data: data, context: context, credentialID: currentCredentialID)
  //            }
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

  struct FetchMyMultisPayload: Codable {
    var expand_srs = true
    var raw_json = 1
  }

  struct MultiContainerResponse: Codable {
    let kind: String?
    var data: MultiData?
  }
}
