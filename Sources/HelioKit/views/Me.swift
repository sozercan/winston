//
//  Me.swift
//  Helio
//
//  Created by Igor Marcossi on 24/06/23.
//

import Defaults
import SwiftUI

struct Me: View {
  @State var router: Router

  init(router: Router) {
    self._router = .init(initialValue: router)
  }

  @State private var loading = true
  var body: some View {
    NavigationStack(path: $router.fullPath) {
      Group {
        if let user = RedditAPI.shared.me {
          UserView(user: user)
            .id("me-user-view-\(user.id)")

        } else if RedditCredentialsManager.profile.state == .error {
          ContentUnavailableView {
            Label("Unable to load profile", systemImage: "person.crop.circle.badge.exclamationmark")
          } actions: {
            Button("Retry") { Task { await RedditCredentialsManager.profile.refresh() } }
          }
        } else {
          ProgressView()
            .progressViewStyle(.circular)
            .frame(maxWidth: .infinity, minHeight: .screenH - 200)
            .onAppear {
              Task(priority: .userInitiated) {
                await RedditCredentialsManager.profile.refresh()
              }
            }
        }
      }
      .toolbar {
        if RedditCredentialsManager.shared.validCredentials.count > 1 {
          ToolbarItem(placement: .topBarLeading) { AccountSwitcherMenu() }
        }
      }
      .attachViewControllerToRouter(tabID: .me)
      .injectInTabDestinations()
    }
//    .swipeAnywhere()
  }
}

/// Switches between the signed-in Reddit accounts.
struct AccountSwitcherMenu: View {
  var body: some View {
    let manager = RedditCredentialsManager.shared
    Menu {
      Picker("Account", selection: Binding(
        get: { manager.selectedCredential?.id },
        set: {
          if let id = $0 {
            Defaults[.GeneralDefSettings].redditCredentialSelectedID = id
          }
        },
      )) {
        ForEach(manager.validCredentials) { cred in
          Text(cred.userName ?? "Account").tag(Optional(cred.id))
        }
      }
    } label: {
      Label("Switch Account", systemImage: "person.2.circle")
    }
  }
}

// struct Me_Previews: PreviewProvider {
//  static var previews: some View {
//    Me()
//  }
// }
