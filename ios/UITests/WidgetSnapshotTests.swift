import Foundation
import Testing

/// Runs the production widget byte writer and reader against disposable directories. The delayed
/// loader deliberately ignores cancellation, like the app's deduplicated image pipeline can.
@Suite
@MainActor
struct WidgetSnapshotTests {
    @Test func testSameOwnerRelaunchPreservesItsSnapshotAndArtwork() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let a = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        let picture = Data("a-picture".utf8)
        let filename = try await fixture.store.loadArtwork(name: "show.jpg", owner: a) { picture }
        var item = Self.item("A's show")
        item.poster = filename
        try fixture.store.write(items: [item], owner: a)

        let restarted = NextUpSnapshotStore(directory: fixture.directory)
        let restored = try #require(try restarted.activate(ownerKey: "fixture-a"))
        #expect(restored == a)
        let snapshot = try #require(NextUpSnapshot.read(directory: fixture.directory))
        #expect(snapshot.owner == restored)
        #expect(snapshot.items.first?.title == "A's show")
        #expect(snapshot.items.first?.line == "Season 1 · Episode 4")
        #expect(NextUpSnapshot.artwork(snapshot.items.first?.poster, owner: restored, directory: fixture.directory) == picture)
    }

    @Test func testLogoutPurgesSnapshotAllArtworkAndInvalidatesTimeline() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let a = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        _ = try await fixture.store.loadArtwork(name: "show.jpg", owner: a) { Data("poster".utf8) }
        _ = try await fixture.store.loadArtwork(name: "show-logo.png", owner: a) { Data("logo".utf8) }
        try fixture.store.write(items: [Self.item("A's show")], owner: a)
        try Data("older-unreferenced-art".utf8).write(to: fixture.directory.appendingPathComponent("old.jpg"))
        let beforeClear = fixture.invalidations.count

        fixture.store.clear()

        #expect(fixture.store.current == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
        #expect(!NextUpSnapshot.isCurrent(a, directory: fixture.directory))
        #expect(fixture.invalidations.count > beforeClear)
        #expect(throws: CancellationError.self) { try fixture.store.write(items: [Self.item("late A")], owner: a) }
    }

    @Test func testAccountBOfflineCannotReadAOrAcceptItsStaleSnapshot() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let a = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        try fixture.store.write(items: [Self.item("A's private show")], owner: a)

        let b = try #require(try fixture.store.activate(ownerKey: "fixture-b"))

        #expect(b != a)
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil, "B has not fetched any library; the widget must remain empty.")
        #expect(throws: CancellationError.self) { try fixture.store.write(items: [Self.item("late A")], owner: a) }
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
        try fixture.store.write(items: [Self.item("B's show")], owner: b)
        #expect(NextUpSnapshot.read(directory: fixture.directory)?.items.first?.title == "B's show")
    }

    @Test func testColdAccountSwitchInvalidatesPreviousProcessLeaseBeforeAnyFetch() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let a = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        try fixture.store.write(items: [Self.item("A's show")], owner: a)
        let coldB = NextUpSnapshotStore(directory: fixture.directory)
        let b = try #require(try coldB.activate(ownerKey: "fixture-b"))

        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
        #expect(!fixture.store.matches(a), "Even an older store instance must recheck the on-disk owner.")
        #expect(throws: CancellationError.self) { try fixture.store.write(items: [Self.item("late A")], owner: a) }
        #expect(NextUpSnapshot.isCurrent(b, directory: fixture.directory))
    }

    @Test func testColdSignedOutCleanupNeedsNoPreviouslyActivatedOwner() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let a = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        try fixture.store.write(items: [Self.item("A before interrupted logout")], owner: a)
        let signedOutLaunch = NextUpSnapshotStore(directory: fixture.directory)
        #expect(signedOutLaunch.current == nil)

        signedOutLaunch.clear()

        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
        #expect(throws: CancellationError.self) { try fixture.store.write(items: [Self.item("late A")], owner: a) }
    }

    @Test func testReaderRejectsLegacyOwnerlessAndMismatchedSnapshots() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let file = fixture.directory.appendingPathComponent(NextUpSnapshot.file)
        let legacy = Data(#"{"writtenAt":"2026-10-09T12:00:00Z","items":[{"id":"old","title":"legacy private title","line":"Episode 9","kind":"resume","behind":0,"dateOnly":false}]}"#.utf8)
        try legacy.write(to: file)
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)

        let b = try #require(try fixture.store.activate(ownerKey: "fixture-b"))
        #expect(!FileManager.default.fileExists(atPath: file.path), "Adopting an owner discards old ownerless data.")
        try legacy.write(to: file)
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil, "A valid current manifest must not authorize an ownerless snapshot.")
        let other = NextUpSnapshot.Owner(key: "fixture-a", generation: UUID())
        let wrong = NextUpSnapshot(owner: other, writtenAt: Date(), items: [Self.item("A under B's manifest")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(wrong).write(to: file, options: .atomic)
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
        #expect(NextUpSnapshot.isCurrent(b, directory: fixture.directory))
        #expect(!NextUpSnapshot.isCurrent(other, directory: fixture.directory))
    }

    @Test func testLateArtworkCompletionAfterLogoutCannotRecreateFiles() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let a = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        let gate = ArtworkGate()
        let pending = Task { try await fixture.store.loadArtwork(name: "late.jpg", owner: a) { await gate.load() } }
        await gate.waitUntilRequested()

        fixture.store.clear() // Deliberately do not cancel: the owner fence must stand on its own.
        gate.finish()
        let result = await pending.result

        #expect(Self.wasCancelled(result))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
    }

    @Test func testCancelledArtworkLoaderCannotPublishAfterIgnoringCancellation() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let a = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        let gate = ArtworkGate()
        let pending = Task { try await fixture.store.loadArtwork(name: "late.jpg", owner: a) { await gate.load() } }
        await gate.waitUntilRequested()

        pending.cancel()
        gate.finish()
        let result = await pending.result
        #expect(Self.wasCancelled(result))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(!remaining.contains { $0.hasSuffix(".jpg") })
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
    }

    @Test func testLateAArtworkCannotOverwriteColdBWidget() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let a = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        let gate = ArtworkGate()
        let pending = Task { try await fixture.store.loadArtwork(name: "shared-show.jpg", owner: a) { await gate.load() } }
        await gate.waitUntilRequested()
        let coldB = NextUpSnapshotStore(directory: fixture.directory)
        let b = try #require(try coldB.activate(ownerKey: "fixture-b"))
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
        let bPicture = Data("B's own poster".utf8)
        let bFilename = try await coldB.loadArtwork(name: "shared-show.jpg", owner: b) { bPicture }
        var bItem = Self.item("B's show")
        bItem.poster = bFilename
        try coldB.write(items: [bItem], owner: b)

        gate.finish()
        let result = await pending.result
        #expect(Self.wasCancelled(result))
        let snapshot = try #require(NextUpSnapshot.read(directory: fixture.directory))
        #expect(snapshot.owner == b)
        #expect(snapshot.items.first?.title == "B's show")
        #expect(NextUpSnapshot.artwork(bFilename, owner: b, directory: fixture.directory) == bPicture)
        #expect(NextUpSnapshot.artwork(bFilename, owner: a, directory: fixture.directory) == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(!files.contains { $0.hasPrefix(a.generation.uuidString) })
    }

    @Test func testLogoutAndSameAccountLoginRejectPreviousGeneration() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let oldA = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        try fixture.store.write(items: [Self.item("before logout")], owner: oldA)
        fixture.store.clear()
        let newA = try #require(try fixture.store.activate(ownerKey: "fixture-a"))
        #expect(newA.key == oldA.key)
        #expect(newA.generation != oldA.generation)
        #expect(throws: CancellationError.self) { try fixture.store.write(items: [Self.item("late old session")], owner: oldA) }
        #expect(NextUpSnapshot.read(directory: fixture.directory) == nil)
    }

    private static func item(_ title: String) -> NextUpSnapshot.Item {
        NextUpSnapshot.Item(id: "fixture-show", title: title, line: "Season 1 · Episode 4", kind: .behind, behind: 3)
    }

    private static func wasCancelled(_ result: Result<String, Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }

    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviouslyWidgetTests-" + UUID().uuidString)
        let invalidations: Invalidations
        let store: NextUpSnapshotStore

        init() {
            let invalidations = Invalidations()
            self.invalidations = invalidations
            store = NextUpSnapshotStore(directory: directory) { invalidations.count += 1 }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor private final class Invalidations { var count = 0 }

    @MainActor private final class ArtworkGate {
        private let requested = AsyncStream<Void>.makeStream()
        private var completion: CheckedContinuation<Data, Never>?

        func load() async -> Data {
            await withCheckedContinuation { continuation in
                completion = continuation
                requested.continuation.yield(())
            }
        }

        func waitUntilRequested() async {
            var iterator = requested.stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        func finish() {
            completion?.resume(returning: Data("late A artwork".utf8))
            completion = nil
            requested.continuation.finish()
        }
    }
}
