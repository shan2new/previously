import SwiftUI
import UIKit
import ClerkKit

@main
struct PreviouslyApp: App {
    /// The orientation gate (`OrientationGate`): portrait everywhere but the system video player.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var auth: AuthManager
    @State private var appModel: AppModel

    init() {
        #if PREVIOUSLY_QA
        QARuntime.prepare()
        #endif
        SplashTrace.mark("app-init")
        #if DEBUG
        // A regex that fails to compile fails loudly, not silently (review i3).
        assert(CatalogPerson(source: .tmdb, externalId: 0, name: "n", role: "A 'B' C", image: nil).displayRole == "A C")
        #endif
        Self.applyBrandFont()
        AppAppearance.install()
        PerfProbe.start()
        // Configure Clerk synchronously so Clerk.shared is valid before the view hierarchy builds.
        if AppConfig.isClerkConfigured {
            Clerk.configure(publishableKey: AppConfig.clerkPublishableKey)
        }
        let auth = AuthManager()
        #if PREVIOUSLY_QA
        QARuntime.bootstrap(auth)
        #endif
        let model = AppModel(api: APIClient(tokenProvider: auth))
        // A rejected session is auth's problem, not the loader's: the model hands the 401 back
        // here rather than rendering it as "the server couldn't be reached".
        model.onSessionExpired = { [weak auth] in auth?.sessionExpired() }
        // Delegates must be installed before launch completes, or an alert arriving while the
        // app is open is dropped without ever being presented.
        EpisodeNotifications.shared.registerForegroundPresenter()
        // A show goes through `pendingOpen` (its handler is unchanged); a post or a thread — a
        // feed reminder — through the typed `pendingRoute`.
        EpisodeNotifications.shared.onOpen = { [weak model] route in
            if case .show(let id) = route { model?.pendingOpen = id } else { model?.pendingRoute = route }
        }
        #if DEBUG
        // `-openDetail <franchiseId>` (DEBUG, like `-openTab`): land on a show page for a capture,
        // through the same route a tapped episode alert takes.
        if let id = UserDefaults.standard.string(forKey: "openDetail"), !id.isEmpty { model.pendingOpen = id }
        #endif
        _auth = State(initialValue: auth)
        _appModel = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .environment(auth)
                .environment(appModel)
                .preferredColorScheme(.dark)
                // Amber is not an action colour (`ThemeColor.interactive`): system chrome — back
                // chevrons, alert buttons, the search field's Cancel and caret — draws in ink.
                // The tab bar re-tints itself amber (a selected tab is STATE), see `MainTabView`.
                .tint(ThemeColor.interactive)
                // Outfit as the inherited default so any text not already using `.scaledFont`
                // (and SwiftUI TextField input) still renders in the brand typeface, scaled.
                .font(.custom("Outfit-Regular", size: 17, relativeTo: .body))
                // Scale text for accessibility, but cap before the densest grids break.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .task { await auth.bootstrap() }
                // The Next up widget's tap: previously://show/<franchiseId>, through the route a
                // tapped episode alert takes.
                .onOpenURL { url in
                    guard url.scheme == "previously", url.host == "show",
                          let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return }
                    appModel.pendingOpen = id
                }
        }
    }

    // The tab bar's item titles are drawn by UIKit, so the SwiftUI default font doesn't reach
    // them — set Outfit on the appearance proxy (font only, leaving the selection tint intact).
    private static func applyBrandFont() {
        let normal = AppFont.uiFont(size: 10, weight: .medium, relativeTo: .caption2)
        let selected = AppFont.uiFont(size: 10, weight: .semibold, relativeTo: .caption2)
        let normalAttributes: [NSAttributedString.Key: Any] = [.font: normal]
        let selectedAttributes: [NSAttributedString.Key: Any] = [.font: selected]

        UITabBarItem.appearance().setTitleTextAttributes(normalAttributes, for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes(selectedAttributes, for: .selected)

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        applyBrandFont(to: appearance.stackedLayoutAppearance,
                       normal: normalAttributes,
                       selected: selectedAttributes)
        applyBrandFont(to: appearance.inlineLayoutAppearance,
                       normal: normalAttributes,
                       selected: selectedAttributes)
        applyBrandFont(to: appearance.compactInlineLayoutAppearance,
                       normal: normalAttributes,
                       selected: selectedAttributes)

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        // Navigation bar titles are NOT set here: SwiftUI ignores UIKit's bar appearances for its
        // own bars, so each screen draws its title in Outfit (`brandNavigationTitle`).
    }

    private static func applyBrandFont(to itemAppearance: UITabBarItemAppearance,
                                       normal: [NSAttributedString.Key: Any],
                                       selected: [NSAttributedString.Key: Any]) {
        itemAppearance.normal.titleTextAttributes.merge(normal) { _, new in new }
        itemAppearance.selected.titleTextAttributes.merge(selected) { _, new in new }
    }

    // Inject Clerk.shared only when a key is configured — accessing Clerk.shared without
    // calling configure() first triggers an assertion failure.
    @ViewBuilder
    private var rootContent: some View {
        if AppConfig.isClerkConfigured {
            RootView().environment(Clerk.shared)
        } else {
            RootView()
        }
    }
}
