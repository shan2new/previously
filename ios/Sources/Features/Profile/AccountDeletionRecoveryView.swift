import SwiftUI

/// An unanswered deletion is a distinct state. No ordinary account requests run underneath it.
struct AccountDeletionRecoveryView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(AppModel.self) private var appModel
    @State private var checking = false
    @State private var message = "Your deletion request didn’t get an answer. Your changes are paused until we can confirm what happened."

    var body: some View {
        VStack(spacing: ThemeSpace.x4) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.largeTitle)
            Text("Confirming deletion").type(ThemeType.displayL)
                .qaIdentifier("qa.deletion.recovery")
            Text(message).multilineTextAlignment(.center).type(ThemeType.body)
            Button(checking ? "Checking…" : "Check status") { check() }
                .buttonStyle(.borderedProminent).disabled(checking)
                .qaIdentifier("qa.deletion.check")
            Button("Sign out") {
                Task { _ = await auth.signOut() }
            }.disabled(checking)
                .qaIdentifier("qa.deletion.signout")
            if let url = AppConfig.supportURL { Link("Contact support", destination: url) }
        }
        .padding(ThemeSpace.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.canvas)
    }

    private func check() {
        checking = true
        let owner = appModel.currentAccountID
        let epoch = appModel.accountEpoch
        Task {
            defer { checking = false }
            do {
                let state = try await AccountDeletion.status(token: {
                    guard owner == auth.accountID, epoch == appModel.accountEpoch else { return nil }
                    let token = await auth.currentToken()
                    return owner == auth.accountID && epoch == appModel.accountEpoch ? token : nil
                })
                guard owner == auth.accountID, epoch == appModel.accountEpoch else { return }
                if state.status == .active {
                    // The authenticated status endpoint checked a durable ledger without upsert.
                    // Resume only after that authoritative answer, never from a timeout.
                    appModel.abortErasure()
                    appModel.start(accountID: auth.accountID)
                } else {
                    AccountDeletion.markAccepted(accountID: appModel.currentAccountID)
                    AccountDeletionNotice.record(state)
                    ProfileSnapshot.clear()
                    appModel.teardown()
                    await auth.accountErased()
                }
            } catch {
                guard owner == auth.accountID, epoch == appModel.accountEpoch else { return }
                message = (error as? LocalizedError)?.errorDescription ?? "We still couldn’t confirm the deletion. Please try again or contact support."
            }
        }
    }
}
