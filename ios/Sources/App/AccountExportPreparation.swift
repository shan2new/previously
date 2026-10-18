import Foundation

/// Destinations may load one shared item repeatedly or concurrently. Keep that item's
/// successful payload consistent while rechecking the captured account on every access.
@MainActor
final class AccountExportPreparation<Value: Sendable> {
    private var cached: Value?
    private var pending: (id: UUID, task: Task<Value, Error>)?

    func value(isCurrent: @escaping @MainActor () -> Bool,
               load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        guard isCurrent() else { throw CancellationError() }
        if let cached { return cached }
        let request: (id: UUID, task: Task<Value, Error>)
        if let pending {
            request = pending
        } else {
            let task = Task { @MainActor in
                guard isCurrent() else { throw CancellationError() }
                let value = try await load()
                guard isCurrent() else { throw CancellationError() }
                return value
            }
            request = (UUID(), task)
            pending = request
        }
        do {
            let value = try await request.task.value
            guard isCurrent() else { throw CancellationError() }
            if pending?.id == request.id {
                cached = value
                pending = nil
            }
            return value
        } catch {
            if pending?.id == request.id { pending = nil }
            throw error
        }
    }
}
