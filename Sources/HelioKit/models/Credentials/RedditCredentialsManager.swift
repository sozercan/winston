//
//  RedditCredentialsManager.swift
//  Helio
//
//  Created by Igor Marcossi on 19/11/23.
//

import Alamofire
import Combine
import Defaults
import Foundation
import KeychainAccess
import SwiftUI

@Observable
class RedditCredentialsManager {
  static let shared = RedditCredentialsManager()
  @MainActor static let profile = SelectedAccountProfile()
  @ObservationIgnored private var syncingAccounts: Set<RedditCredential.AuthorizationID> = []
  static func getById(_ credID: UUID) -> RedditCredential? {
    RedditCredentialsManager.shared.credentials.first(where: { $0.id == credID })
  }

  static let keychainEntryDivider = "\\--(*.*)--/"
  static let oldKeychainServiceString = "com.sertacozercan.helio.reddit-credentials"
  static let keychainServiceString = "com.sertacozercan.helio.reddit-multi-credentials"
  static let keychain = Keychain(service: RedditCredentialsManager.keychainServiceString).synchronizable(Defaults[.BehaviorDefSettings].iCloudSyncCredentials)
  private(set) var credentials: [RedditCredential] = []
  var validCredentials: [RedditCredential] {
    credentials.filter { $0.validationStatus == .authorized }
  }

  var cancelables: [Defaults.Observation] = []

  var selectedCredential: RedditCredential? {
    if !credentials.isEmpty {
      let selectedID = Defaults[.GeneralDefSettings].redditCredentialSelectedID
      return credentials.first { $0.id == selectedID } ?? credentials[0]
    }
    return nil
  }

  func syncCredentialsWithKeychain() {
    do {
      let allKeys = try Self.keychain.allKeys()
      for keychainCredID in allKeys {
        if self.credentials.first(where: { $0.id.uuidString == keychainCredID }) == nil {
          try Self.keychain.remove(keychainCredID)
        }
      }
      for cred in self.credentials {
        if let encoded = cred.toStr() {
          try Self.keychain.set(encoded, key: cred.id.uuidString)
        }
      }
    } catch {
      print("Keychain sync error: \(error.localizedDescription)")
    }
  }

  /// An in-memory credential set, without importing or writing the keychain.
  init(credentials: [RedditCredential]) {
    self.credentials = credentials
  }

  @MainActor
  func containsAuthorization(_ authorization: RedditCredential.AuthorizationID) -> Bool {
    credentials.contains { $0.authorizationID == authorization }
  }

  @MainActor
  @discardableResult
  func markSubscriptionsSynced(for credential: RedditCredential, at date: Date = Date()) -> Bool {
    guard let authorization = credential.authorizationID, containsAuthorization(authorization) else { return false }
    let syncKey = "\(credential.id.uuidString)|\(credential.userName ?? "")"
    Defaults[.subsSyncedAt][syncKey] = date
    return true
  }

  init() {
    let okc = Keychain(service: Self.oldKeychainServiceString)
    let kc = Self.keychain

    let oldApiAppID = okc["apiAppID"]
    let oldApiAppSecret = okc["apiAppSecret"]
    let oldRefreshToken = okc["refreshToken"]

    var importedCredential: RedditCredential? = nil
    if oldApiAppID != nil || oldApiAppSecret != nil || oldRefreshToken != nil {
      importedCredential = .init(apiAppID: oldApiAppID ?? "", apiAppSecret: oldApiAppSecret ?? "", refreshToken: oldRefreshToken)
    }

    if let importedCredential {
      credentials.append(importedCredential)
      Defaults[.GeneralDefSettings].redditCredentialSelectedID = importedCredential.id
    }

    try? okc.remove("apiAppID")
    try? okc.remove("apiAppSecret")
    try? okc.remove("refreshToken")
    try? okc.remove("accessToken")

    let keychainKeys = kc.allKeys()

    for key in keychainKeys {
      if let credStr = kc[key], let decodedCred = credStr.toObj(RedditCredential.self) {
        credentials.append(decodedCred)
      }
    }

//    self.cancelables.append(Defaults.observe(.redditCredentialSelectedID) { change in
//      if change.oldValue == change.newValue { return }
//      if let cred = self.credentials.first(where: { $0.id == change.newValue }) {
//        self.updateMe(altCred: cred)
//      }
//      doThisAfter(0) { self.objectWillChange.send() }
//    })

//    if let currCredID = Defaults[.redditCredentialSelectedID], let currCred = self.credentials.first(where: { $0.id == currCredID })  {
//      doThisAfter(0.5) { self.updateMe(altCred: currCred) }
//    }
  }

  deinit { self.cancelables.forEach { obs in obs.invalidate() } }

  /// Launch and account switches sync subscriptions and multis at most this often. Subscribing
  /// in the app updates the local copy, and pulling the subreddit list syncs right away.
  static let subsSyncInterval: TimeInterval = 60 * 60

  @MainActor
  func updateMe() {
    Self.profile.reload()
    guard let credential = selectedCredential, let authorization = credential.authorizationID else { return }
    // A credential signed in to another account is synced again.
    let syncKey = "\(credential.id.uuidString)|\(credential.userName ?? "")"
    if let syncedAt = Defaults[.subsSyncedAt][syncKey], Date().timeIntervalSince(syncedAt) < Self.subsSyncInterval {
      return
    }
    guard syncingAccounts.insert(authorization).inserted else { return }
    Task(priority: .utility) {
      defer { self.syncingAccounts.remove(authorization) }
      // As this account: the selection can change before the task runs.
      async let subsSynced = RedditAPI.shared.fetchSubsAndSyncCoreData(account: credential)
      async let multisSynced = RedditAPI.shared.fetchMyMultis(account: credential)
      if await subsSynced, await multisSynced {
        self.markSubscriptionsSynced(for: credential)
      }
    }
  }

  func saveCred(_ cred: RedditCredential, forceCreate: Bool = true) {
    DispatchQueue.main.async {
      let previousAuthorization = self.selectedCredential?.authorizationID
      if Defaults[.GeneralDefSettings].onboardingState != .dismissed {
        Defaults[.GeneralDefSettings].onboardingState = .dismissed
        Nav.shared.presentingSheetsQueue = Nav.shared.presentingSheetsQueue.filter { $0 != .onboarding }
      }
      if let i = self.credentials.firstIndex(where: { $0.id == cred.id }) {
        self.credentials[i] = cred
      } else if forceCreate {
        self.credentials.append(cred)
      }
      // Auto-select if no credential is currently selected
      if Defaults[.GeneralDefSettings].redditCredentialSelectedID == nil {
        Defaults[.GeneralDefSettings].redditCredentialSelectedID = cred.id
      }
      // Sync immediately on main queue to avoid XPC violations
      self.syncCredentialsWithKeychain()
      if previousAuthorization != self.selectedCredential?.authorizationID {
        self.updateMe()
      }
    }
  }

  /// A refresh only updates the authorization that requested it, preserving newer edits.
  @MainActor
  func updateAccessToken(_ token: RedditCredential.AccessToken?, for authorization: RedditCredential.AuthorizationID) {
    guard let index = credentials.firstIndex(where: { $0.id == authorization.credentialID }) else { return }
    var current = credentials[index]
    guard current.updateAccessToken(token, for: authorization), current != credentials[index] else { return }
    credentials[index] = current
    syncCredentialsWithKeychain()
    if token == nil, selectedCredential?.id == authorization.credentialID {
      Self.profile.reload()
    }
  }

  func deleteCred(_ cred: RedditCredential) {
    DispatchQueue.main.async {
      let previousAuthorization = self.selectedCredential?.authorizationID
      withAnimation {
        self.credentials = self.credentials.filter { $0.id != cred.id }
      }
      // Sync immediately on main queue to avoid XPC violations
      self.syncCredentialsWithKeychain()
      if previousAuthorization != self.selectedCredential?.authorizationID {
        self.updateMe()
      }
    }
  }

  func wipeAllCredentials() {
    DispatchQueue.main.async {
      withAnimation { self.credentials.removeAll() }
      Self.profile.reload()
      // Remove keychain items immediately to avoid XPC violations
      do {
        try Self.keychain.removeAll()
      } catch {
        print("Error wiping keychain: \(error.localizedDescription)")
      }
    }
  }
}
