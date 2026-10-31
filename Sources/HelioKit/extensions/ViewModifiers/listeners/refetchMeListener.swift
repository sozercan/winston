//
//  refetchMeListener.swift
//  Helio
//
//  Created by Igor Marcossi on 13/12/23.
//

import Defaults
import SwiftUI

struct RefetchMeListenerModifier: ViewModifier {
  @Default(.GeneralDefSettings) private var generalDefSettings
  func body(content: Content) -> some View {
    content
      .onChange(of: generalDefSettings.redditCredentialSelectedID) {
        RedditCredentialsManager.shared.updateMe()
      }
  }
}

extension View {
  func refetchMeListener() -> some View {
    self.modifier(RefetchMeListenerModifier())
  }
}
