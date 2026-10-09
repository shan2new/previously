import XCTest

/// Exercises the actual production request/receipt decoder with an in-process transport.
/// Synthetic proof strings never leave this test process and are not written to disk.
@MainActor
final class AccountDeletionRequestTests: XCTestCase {
    func testFreshAppleProofUsesDefinedBodyAndManualReceipt() async throws {
        let transport = DeletionRequestProtocol.session(status: 200,
            body: #"{"deleted":true,"status":"complete","appleRevocation":"manual_required"}"#)
        defer { transport.session.invalidateAndCancel() }
        let proof = AppleDeletionAuthorization.Proof(identityToken: "synthetic-identity-token", authorizationCode: "synthetic-one-use-code")
        let receipt = try await AccountDeletion.deleteAccount(baseURL: URL(string: "https://fixture.invalid")!,
            session: transport.session, apple: proof, token: { "synthetic-clerk-token" })
        let request = try XCTUnwrap(transport.capture.request)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        XCTAssertEqual(Set(body.keys), ["apple"])
        XCTAssertEqual(body["apple"], ["identityToken": proof.identityToken, "authorizationCode": proof.authorizationCode])
        XCTAssertEqual(receipt.status, .complete)
        XCTAssertEqual(receipt.appleRevocation, .manual_required)
        XCTAssertTrue(AccountDeletionNotice.message(for: receipt).contains("stop using Sign in with Apple"))
    }

    func testNoProofKeepsEmptyBodyAndHonestPendingReceipt() async throws {
        let transport = DeletionRequestProtocol.session(status: 202,
            body: #"{"deleted":false,"status":"pending","appleRevocation":"not_applicable"}"#)
        defer { transport.session.invalidateAndCancel() }
        let receipt = try await AccountDeletion.deleteAccount(baseURL: URL(string: "https://fixture.invalid")!,
            session: transport.session, token: { "synthetic-clerk-token" })
        XCTAssertNil(transport.capture.request?.httpBody)
        XCTAssertEqual(receipt.status, .pending)
        XCTAssertEqual(receipt.appleRevocation, .not_applicable)
        XCTAssertTrue(AccountDeletionNotice.message(for: receipt).contains("will finish automatically"))
        XCTAssertFalse(AccountDeletionNotice.message(for: receipt).contains("have been deleted"))
    }

    func testCanonicalStatusRetainsManualInstructionsAndUnknownReceiptFailsClosed() async throws {
        let complete = DeletionRequestProtocol.session(status: 200,
            body: #"{"deleted":true,"status":"complete","appleRevocation":"manual_required"}"#)
        defer { complete.session.invalidateAndCancel() }
        let receipt = try await AccountDeletion.status(baseURL: URL(string: "https://fixture.invalid")!,
            session: complete.session, token: { "synthetic-clerk-token" })
        XCTAssertEqual(complete.capture.request?.httpMethod, "GET")
        XCTAssertEqual(complete.capture.request?.url?.path, "/me/deletion")
        XCTAssertNil(complete.capture.request?.httpBody)
        XCTAssertTrue(AccountDeletionNotice.message(for: receipt).contains("stop using Sign in with Apple"))
        let unknown = DeletionRequestProtocol.session(status: 200,
            body: #"{"deleted":true,"status":"complete","appleRevocation":"unrecognized"}"#)
        defer { unknown.session.invalidateAndCancel() }
        do {
            _ = try await AccountDeletion.status(baseURL: URL(string: "https://fixture.invalid")!,
                session: unknown.session, token: { "synthetic-clerk-token" })
            XCTFail("An undefined revocation receipt must not clear a deletion hold.")
        } catch { XCTAssertEqual(error as? AccountDeletion.Failure, .unreachable) }
    }
}

private final class DeletionRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: URLRequest?
    var request: URLRequest? { lock.withLock { captured } }
    func record(_ request: URLRequest) {
        var value = request
        // URLSession exposes uploaded bytes as an InputStream to URLProtocol. Read those actual
        // synthetic bytes instead of mistaking a nil httpBody for a missing production body.
        if value.httpBody == nil, let stream = value.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while data.count < 16_384 {
                let read = stream.read(&buffer, maxLength: min(buffer.count, 16_384 - data.count))
                guard read > 0 else { break }
                data.append(contentsOf: buffer.prefix(read))
            }
            value.httpBody = data
        }
        lock.withLock { captured = value }
    }
}

private final class DeletionRequestProtocol: URLProtocol, @unchecked Sendable {
    private struct Response: Sendable { let status: Int; let body: Data; let capture: DeletionRequestCapture }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response: Response?
    static func session(status: Int, body: String) -> (session: URLSession, capture: DeletionRequestCapture) {
        let capture = DeletionRequestCapture()
        lock.withLock { response = Response(status: status, body: Data(body.utf8), capture: capture) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionRequestProtocol.self]
        return (URLSession(configuration: configuration), capture)
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.lock.withLock({ Self.response }), let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        response.capture.record(request)
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
