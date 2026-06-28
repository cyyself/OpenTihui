//
//  DefaultChatSettingsView.swift
//  openTihui
//
//  Edits the app-wide default generation settings used for new (non-shortcut)
//  chats and the keyboard's generic "Generate in app". Shortcuts keep their own.
//

import SwiftUI

struct DefaultChatSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            GenConfigEditor(config: $settings.defaultConfig)
        }
        .navigationTitle("Default Generation Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
