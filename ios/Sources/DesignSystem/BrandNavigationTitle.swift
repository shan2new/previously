import SwiftUI

extension View {
    /// The navigation bar's title in the app's face (26 Sep: "Why does Library and Schedule still
    /// have SF font in the title?", owner). `.navigationTitle` alone draws in SF whatever UIKit's
    /// appearance says — a bar with `.toolbarBackground(.hidden)` gets an appearance SwiftUI builds
    /// itself, and neither the `titleTextAttributes` nor the default appearances reach it (both were
    /// tried and photographed). So the title is the bar's PRINCIPAL item, in Outfit, its iOS 26 glass
    /// capsule dropped as Detail's docked title drops it; `.navigationTitle` stays for VoiceOver's
    /// screen name and the back button of a page pushed on top. A screen that already fills the
    /// principal slot (Detail, the post page) keeps its own and does not use this.
    func brandNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .type(ThemeType.barTitle)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .accessibilityAddTraits(.isHeader)
                }
                .chromeSharedBackgroundHidden()
            }
    }
}
