import AuthenticationServices
import UIKit

/// A fresh Apple credential is used only for the confirmed deletion request. It is never
/// cached, written to the tracking journal, or included in an error message.
@MainActor
final class AppleDeletionAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Proof: Encodable, Sendable {
        let identityToken: String
        let authorizationCode: String
    }

    enum Failure: Error, Equatable { case cancelled, unavailable, accountMismatch }
    private let expectedUserIDs: Set<String>
    private var continuation: CheckedContinuation<Proof, Error>?
    private var controller: ASAuthorizationController?

    private init(expectedUserIDs: Set<String>) { self.expectedUserIDs = expectedUserIDs }

    static func request(expectedUserIDs: Set<String>) async throws -> Proof {
        guard !expectedUserIDs.isEmpty else { throw Failure.unavailable }
        let helper = AppleDeletionAuthorization(expectedUserIDs: expectedUserIDs)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: Failure.cancelled); return }
                helper.continuation = continuation
                let request = ASAuthorizationAppleIDProvider().createRequest()
                // Reauthorize the existing grant; deleting an account needs no new profile fields.
                request.requestedScopes = []
                let controller = ASAuthorizationController(authorizationRequests: [request])
                helper.controller = controller
                controller.delegate = helper
                controller.presentationContextProvider = helper
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor in helper.finish(.failure(Failure.cancelled)) }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(.failure(Failure.unavailable)); return
        }
        guard expectedUserIDs.contains(credential.user) else {
            finish(.failure(Failure.accountMismatch)); return
        }
        guard let tokenData = credential.identityToken, let codeData = credential.authorizationCode,
              let token = String(data: tokenData, encoding: .utf8), !token.isEmpty,
              let code = String(data: codeData, encoding: .utf8), !code.isEmpty else {
            finish(.failure(Failure.unavailable)); return
        }
        finish(.success(Proof(identityToken: token, authorizationCode: code)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        finish(.failure(cancelled ? Failure.cancelled : Failure.unavailable))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func finish(_ result: Result<Proof, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        controller?.delegate = nil
        controller?.presentationContextProvider = nil
        controller = nil
        continuation.resume(with: result)
    }
}
