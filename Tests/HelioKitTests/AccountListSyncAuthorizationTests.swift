import CoreData
import Defaults
import Foundation
import Testing
@testable import HelioKit

@MainActor
struct AccountListSyncAuthorizationTests {
  private func credential(_ grant: String = "placeholder-current-grant") -> RedditCredential {
    RedditCredential(apiAppID: "placeholder-client-id", refreshToken: grant, userName: "placeholder-user")
  }

  private func subscriptions(_ entries: [(String, String)]) throws -> [ListingChild<SubredditData>] {
    try entries.map { id, title in
      let json: [String: Any] = ["kind": "t5", "data": ["id": id, "name": "t5_\(id)", "url": "/r/\(id)/", "title": title, "public_description": ""]]
      return try JSONDecoder().decode(ListingChild<SubredditData>.self, from: JSONSerialization.data(withJSONObject: json))
    }
  }

  private func multis(_ entries: [(String, String)]) throws -> [RedditAPI.MultiContainerResponse] {
    try entries.map { id, title in
      let json: [String: Any] = ["kind": "LabeledMulti", "data": ["name": id, "path": "/user/placeholder-user/m/\(id)", "display_name": title, "subreddits": []]]
      return try JSONDecoder().decode(RedditAPI.MultiContainerResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }
  }

  /// Package tests do not have the app bundle's Core Data model. Model just the two
  /// list entities, with the same attributes and relationship as the app model.
  private static let model: NSManagedObjectModel = {
    func entity(_ name: String, type: NSManagedObject.Type, strings: [String], booleans: [String]) -> NSEntityDescription {
      let entity = NSEntityDescription()
      entity.name = name
      entity.managedObjectClassName = NSStringFromClass(type)
      entity.properties = strings.map { attribute($0, type: .stringAttributeType) }
        + booleans.map { attribute($0, type: .booleanAttributeType, defaultValue: false) }
        + [attribute("helioCredentialID", type: .UUIDAttributeType)]
      return entity
    }
    func attribute(_ name: String, type: NSAttributeType, defaultValue: Any? = nil) -> NSAttributeDescription {
      let attribute = NSAttributeDescription()
      attribute.name = name
      attribute.attributeType = type
      attribute.isOptional = true
      attribute.defaultValue = defaultValue
      return attribute
    }
    let sub = entity("CachedSub", type: CachedSub.self, strings: [
      "banner_background_color", "banner_background_image", "banner_img", "community_icon", "display_name", "header_img", "icon_img", "key_color", "name", "primary_color", "title", "url", "user_flair_background_color", "uuid",
    ], booleans: [
      "allow_galleries", "allow_images", "allow_videos", "over18", "restrict_commenting", "user_has_favorited", "user_is_banned", "user_is_moderator", "user_is_subscriber",
    ])
    sub.properties.append(attribute("subscribers", type: .doubleAttributeType, defaultValue: 0))
    let multi = entity("CachedMulti", type: CachedMulti.self, strings: ["display_name", "icon_url", "key_color", "name", "path", "uuid"], booleans: ["over_18"])
    let subreddits = NSRelationshipDescription()
    subreddits.name = "subreddits"
    subreddits.destinationEntity = sub
    subreddits.maxCount = 0
    subreddits.deleteRule = .nullifyDeleteRule
    let membership = NSRelationshipDescription()
    membership.name = "multis"
    membership.destinationEntity = multi
    membership.maxCount = 0
    membership.deleteRule = .nullifyDeleteRule
    membership.inverseRelationship = subreddits
    subreddits.inverseRelationship = membership
    sub.properties.append(membership)
    multi.properties.append(subreddits)
    let model = NSManagedObjectModel()
    model.entities = [sub, multi]
    return model
  }()

  private func context() throws -> NSManagedObjectContext {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Self.model)
    try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return context
  }

  private func savedLists(in context: NSManagedObjectContext, account: RedditCredential) throws -> (subs: [String: String], multis: [String: String]) {
    let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    reader.persistentStoreCoordinator = context.persistentStoreCoordinator
    return try reader.performAndWait {
      let subs = CachedSub.fetchRequest()
      subs.predicate = NSPredicate(format: "helioCredentialID == %@", account.id as CVarArg)
      let multis = CachedMulti.fetchRequest()
      multis.predicate = subs.predicate
      return try (
        Dictionary(uniqueKeysWithValues: reader.fetch(subs).map { ($0.uuid ?? "", $0.title ?? "") }),
        Dictionary(uniqueKeysWithValues: reader.fetch(multis).map { ($0.uuid ?? "", $0.display_name ?? "") }),
      )
    }
  }

  @Test(arguments: [false, true])
  func sameUUIDReauthorizationRejectsStaleSubscriptionWrites(emptyResponse: Bool) async throws {
    let old = credential("placeholder-old-grant")
    var replacement = old
    replacement.refreshToken = "placeholder-replacement-grant"
    let manager = RedditCredentialsManager(credentials: [replacement])
    let context = try context()
    let api = RedditAPI()
    let latest = try subscriptions([("shared", "Replacement title"), ("new", "Replacement only")])
    let seeded = await api.updateSubsInCoreData(with: latest, account: replacement, credentialsManager: manager, context: context)
    #expect(seeded)
    let before = try savedLists(in: context, account: replacement).subs

    // A completed old request arrives after the replacement sync: it would overwrite
    // shared metadata, insert old entries, and delete the replacement-only entry.
    let stale = try subscriptions(emptyResponse ? [] : [("shared", "Stale title"), ("old", "Stale only")])
    let accepted = await api.updateSubsInCoreData(with: stale, account: old, credentialsManager: manager, context: context)
    #expect(!accepted)
    #expect(try savedLists(in: context, account: replacement).subs == before)
    #expect(!context.performAndWait { context.hasChanges })
  }

  @Test(arguments: [false, true])
  func sameUUIDReauthorizationRejectsStaleMultiWrites(emptyResponse: Bool) async throws {
    let old = credential("placeholder-old-grant")
    var replacement = old
    replacement.refreshToken = "placeholder-replacement-grant"
    let manager = RedditCredentialsManager(credentials: [replacement])
    let context = try context()
    let api = RedditAPI()
    let latest = try multis([("shared", "Replacement title"), ("new", "Replacement only")])
    let seeded = await api.updateMultisInCoreData(with: latest, account: replacement, credentialsManager: manager, context: context)
    #expect(seeded)
    let before = try savedLists(in: context, account: replacement).multis
    let stale = try multis(emptyResponse ? [] : [("shared", "Stale title"), ("old", "Stale only")])
    let accepted = await api.updateMultisInCoreData(with: stale, account: old, credentialsManager: manager, context: context)
    #expect(!accepted)
    #expect(try savedLists(in: context, account: replacement).multis == before)
    #expect(!context.performAndWait { context.hasChanges })
  }

  @Test(arguments: [false, true])
  func removedOrRevokedGrantsCannotDeleteLists(revoked: Bool) async throws {
    let old = credential()
    let context = try context()
    let api = RedditAPI()
    let original = RedditCredentialsManager(credentials: [old])
    let subsSeeded = try await api.updateSubsInCoreData(with: subscriptions([("kept", "Kept")]), account: old, credentialsManager: original, context: context)
    let multisSeeded = try await api.updateMultisInCoreData(with: multis([("kept", "Kept")]), account: old, credentialsManager: original, context: context)
    #expect(subsSeeded && multisSeeded)
    var cleared = old
    cleared.clearIdentity()
    let manager = RedditCredentialsManager(credentials: revoked ? [cleared] : [])
    let before = try savedLists(in: context, account: old)
    let subsAccepted = await api.updateSubsInCoreData(with: [], account: old, credentialsManager: manager, context: context)
    let multisAccepted = await api.updateMultisInCoreData(with: [], account: old, credentialsManager: manager, context: context)
    #expect(!subsAccepted && !multisAccepted)
    let after = try savedLists(in: context, account: old)
    #expect(after.subs == before.subs && after.multis == before.multis)
  }

  @Test func aNonselectedCurrentGrantStillUpdatesAndDeletesListsAfterTokenRenewal() async throws {
    let selected = credential("placeholder-selected-grant")
    let captured = credential("placeholder-background-grant")
    var renewed = captured
    renewed.accessToken = .init(token: "placeholder-renewed-access-token", expiration: 3600, lastRefresh: Date())
    let manager = RedditCredentialsManager(credentials: [selected, renewed])
    #expect(manager.selectedCredential?.id == selected.id)
    let context = try context()
    let api = RedditAPI()
    for account in [selected, captured] {
      let subsSeeded = try await api.updateSubsInCoreData(with: subscriptions([("shared", "Before"), ("removed", "Removed")]), account: account, credentialsManager: manager, context: context)
      let multisSeeded = try await api.updateMultisInCoreData(with: multis([("shared", "Before"), ("removed", "Removed")]), account: account, credentialsManager: manager, context: context)
      #expect(subsSeeded && multisSeeded)
    }
    let selectedBefore = try savedLists(in: context, account: selected)
    let subsAccepted = try await api.updateSubsInCoreData(with: subscriptions([("shared", "After"), ("new", "New")]), account: captured, credentialsManager: manager, context: context)
    let multisAccepted = try await api.updateMultisInCoreData(with: multis([("shared", "After"), ("new", "New")]), account: captured, credentialsManager: manager, context: context)
    #expect(subsAccepted && multisAccepted)
    let saved = try savedLists(in: context, account: captured)
    #expect(saved.subs == ["t5_shared": "After", "t5_new": "New"])
    #expect(saved.multis == ["/user/placeholder-user/m/shared": "After", "/user/placeholder-user/m/new": "New"])
    let selectedAfter = try savedLists(in: context, account: selected)
    #expect(selectedAfter.subs == selectedBefore.subs && selectedAfter.multis == selectedBefore.multis)
  }

  @Test func syncCompletionRechecksGrantMembershipBeforeAdvancingTimestamp() {
    let captured = credential("placeholder-old-grant")
    let key = "\(captured.id.uuidString)|\(captured.userName ?? "")"
    defer { Defaults[.subsSyncedAt].removeValue(forKey: key) }
    let original = RedditCredentialsManager(credentials: [captured])
    let previous = Date(timeIntervalSince1970: 1)
    let originalAccepted = original.markSubscriptionsSynced(for: captured, at: previous)
    #expect(originalAccepted)
    var replacement = captured
    replacement.refreshToken = "placeholder-replacement-grant"
    let manager = RedditCredentialsManager(credentials: [replacement])
    // Both requests may have saved successfully before replacement; their later
    // completion must still not mark the replacement grant as freshly synced.
    let staleAccepted = manager.markSubscriptionsSynced(for: captured, at: Date(timeIntervalSince1970: 2))
    #expect(!staleAccepted)
    #expect(Defaults[.subsSyncedAt][key] == previous)
    let removedAccepted = RedditCredentialsManager(credentials: []).markSubscriptionsSynced(for: captured)
    #expect(!removedAccepted)
    #expect(Defaults[.subsSyncedAt][key] == previous)
    let current = Date(timeIntervalSince1970: 3)
    let nonselected = RedditCredentialsManager(credentials: [credential("placeholder-selected-grant"), replacement])
    let currentAccepted = nonselected.markSubscriptionsSynced(for: replacement, at: current)
    #expect(currentAccepted)
    #expect(Defaults[.subsSyncedAt][key] == current)
  }
}
