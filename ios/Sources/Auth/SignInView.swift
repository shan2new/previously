import SwiftUI
import ClerkKit
import ClerkKitUI

// First run (spec board 07): the brand, one action. Nothing to read, nothing to configure.
// The developer sign-in exists only in debug builds without a Clerk key.
//
// A compact brand signature sits above the viewing room. The launch retains its display-scale
// identity; credential forms keep their focused layout.
struct SignInView: View {
    /// The moment after signing in, while the account is being looked at (`FirstRunHold`): the
    /// same room and the same mark, the action gone — so nothing on screen moves until the app,
    /// or first run, arrives.
    var holding = false

    @Environment(AuthManager.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showClerkAuth = false
    @State private var clerkAuthView: AuthView?
    @AppStorage(AccountDeletionNotice.key) private var deletionNotice = ""
    /// `-devSignInId <clerkId>` launch argument (DEBUG, like `-recapDemo`): pre-fills the field so
    /// a scripted simulator run can sign in without typing into the device.
    @State private var devId = UserDefaults.standard.string(forKey: "devSignInId") ?? "demo-user"

    private var isAX: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        ZStack {
            ThemeColor.canvas.ignoresSafeArea()
            if AppConfig.isClerkConfigured {
                welcomeBackdrop
            }

            GeometryReader { geo in
                identity
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.32)
            }
            .ignoresSafeArea()
            if !holding {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if !deletionNotice.isEmpty {
                        Text(deletionNotice).type(ThemeType.caption)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, ThemeSpace.x4)
                            .accessibilityIdentifier("account.deletion.notice")
                    }
                    action
                }
                .padding(.horizontal, ThemeSpace.x6)
                .padding(.bottom, ThemeSpace.x10)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(spacing: ThemeSpace.x3) {
            PreviouslyMark(width: 56, lit: true)
                .accessibilityHidden(true)
            BrandWord(style: ThemeType.brandWordmark)
        }
        .frame(maxWidth: .infinity)
    }

    private var welcomeBackdrop: some View {
        GeometryReader { geo in
            Image("login-cozy-backdrop-v3")
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay {
                    LinearGradient(stops: [
                        .init(color: ThemeColor.canvas.opacity(0.42), location: 0),
                        .init(color: ThemeColor.canvas.opacity(0.48), location: 0.42),
                        .init(color: ThemeColor.canvas.opacity(0.12), location: 0.62),
                        .init(color: ThemeColor.canvas.opacity(0.18), location: 0.80),
                        .init(color: ThemeColor.canvas.opacity(0.76), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .overlay { ThemeColor.canvas.opacity(isAX ? 0.20 : 0) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Action

    /// Whether the developer bypass may be offered at all.
    ///
    /// Two gates, both required. `#if DEBUG` keeps the panel out of any build that can reach the
    /// App Store — a raw text field and the string "the backend must allow DEV_AUTH_BYPASS outside
    /// production" as the first screen of a submitted app is an automatic rejection and a one-star
    /// screenshot. `isLocalBackend` keeps it out of a debug build that has been pointed at a real
    /// host, because a `dev:` bearer must never be SENT toward production even if the server there
    /// would refuse it.
    private var devSignInAvailable: Bool {
        #if DEBUG
        return !AppConfig.isClerkConfigured && AppConfig.isLocalBackend
        #else
        return false
        #endif
    }

    private var action: some View {
        VStack(spacing: ThemeSpace.x3) {
            if AppConfig.isClerkConfigured {
                Button("Sign in", action: presentClerkAuth)
                    .buttonStyle(PrimaryButtonStyle2())
            } else if devSignInAvailable {
                #if DEBUG
                DevSignInCard(devId: $devId) { auth.signInDev(clerkId: devId) }
                #endif
            } else {
                // Fails CLOSED: no key, no field, no bypass, and nothing a reviewer could mistake
                // for a way in. The condition is a build misconfiguration, so it is stated as one
                // rather than dressed up as a temporary outage the user could wait out.
                Text("Sign-in isn\u{2019}t available in this build.")
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if let error = auth.lastError {
                InlineNotice(error)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: auth.lastError)
        .sheet(isPresented: $showClerkAuth, onDismiss: { clerkAuthView = nil }) {
            clerkAuthView
                .clerkAppIconView {
                    PreviouslyMark(width: 36, lit: true)
                        .padding(.bottom, ThemeSpace.x6)
                        .accessibilityHidden(true)
                }
                .environment(Clerk.shared)
        }
        #if DEBUG
        // Capture the actual public credential sheet without starting an authentication attempt.
        .onAppear {
            if AppConfig.isClerkConfigured,
               UserDefaults.standard.bool(forKey: "signInCaptureSheet") {
                presentClerkAuth()
            }
        }
        #endif
    }

    private func presentClerkAuth() {
        guard !showClerkAuth, clerkAuthView == nil else { return }
        // AuthView initializes observable SDK state. Construct it outside body tracking and
        // retain it for this presentation so sheet reevaluation cannot repeat that setup.
        let manager = auth
        let presented = $showClerkAuth
        clerkAuthView = AuthView(onAuthComplete: {
            manager.refreshClerkSignInState()
            presented.wrappedValue = false
        })
        showClerkAuth = true
    }
}

#if DEBUG
private struct DevSignInCard: View {
    @Binding var devId: String
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            // `-devSignInAuto 1`: a scripted simulator run signs in on appear with the seeded id.
            Color.clear.frame(height: 0)
                .onAppear {
                    if UserDefaults.standard.bool(forKey: "devSignInAuto"), !devId.isEmpty { onContinue() }
                }
            SectionLabel(text: "Developer sign-in")
            Text("No Clerk key configured. Sign in with a dev user id (the backend must allow DEV_AUTH_BYPASS outside production).")
                .type(ThemeType.metadata)
                .foregroundStyle(ThemeColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("dev user id", text: $devId)
                .qaIdentifier("qa.signin.dev.field")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .type(ThemeType.body)
                .foregroundStyle(ThemeColor.textPrimary)
                .tint(ThemeColor.accent)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(ThemeColor.surfaceFloating,
                            in: RoundedRectangle(cornerRadius: ThemeRadius.compactControl, style: .continuous))
                // `strokeBorder`, not `stroke`: a control may carry a full-perimeter edge, but a
                // centred 1-pt line straddles the shape and smears outside it.
                .overlay(RoundedRectangle(cornerRadius: ThemeRadius.compactControl, style: .continuous)
                    .strokeBorder(ThemeColor.stroke, lineWidth: 1))
                .padding(.top, ThemeSpace.x1)
            Button("Continue", action: onContinue)
                .qaIdentifier("qa.signin.dev.submit")
                .buttonStyle(PrimaryButtonStyle2())
                .padding(.top, ThemeSpace.x1)
        }
        .padding(ThemeSpace.x4)
        // A card is visible because it is LIGHTER and lit along its top edge, not because it has
        // a grey line drawn round it.
        .surface(.raised, radius: ThemeRadius.card)
    }
}
#endif
