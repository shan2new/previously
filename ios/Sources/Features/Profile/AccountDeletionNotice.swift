import Foundation

@MainActor
enum AccountDeletionNotice {
    static let key = "previously.deletion.notice"
    static let appleManualInstructions = "To disconnect Apple sign-in, open Settings → your name → Sign in with Apple → Previously, then follow the option to stop using Sign in with Apple."
    static func message(for receipt: AccountDeletion.Receipt) -> String {
        var notice = receipt.status == .pending
            ? "Deletion requested. Your tracking data is removed; sign-in data deletion will finish automatically."
            : "Your account and tracking data have been deleted."
        if receipt.appleRevocation == .manual_required { notice += " " + appleManualInstructions }
        return notice
    }
    static func record(_ receipt: AccountDeletion.Receipt) {
        UserDefaults.standard.set(message(for: receipt), forKey: key)
    }
}
