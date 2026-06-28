//
//  IconPicker.swift
//  openTihui
//
//  Horizontal SF Symbol picker reused by the shortcut editor and chat settings.
//

import SwiftUI

struct IconPicker: View {
    @Binding var icon: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Shortcut.iconChoices, id: \.self) { name in
                    Image(systemName: name)
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .background(icon == name ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(icon == name ? Color.accentColor : Color.primary)
                        .onTapGesture { icon = name }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
