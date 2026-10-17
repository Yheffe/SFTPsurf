import Foundation

/// Runs uploads and downloads with a bounded number in flight, reporting state
/// changes back to whoever owns the UI.
public actor TransferQueue {
    public typealias UpdateHandler = @Sendable (TransferItem) -> Void

    private let client: RemoteFileClient
    private let maxConcurrent: Int
    private let onUpdate: UpdateHandler

    private var items: [TransferItem] = []
    /// Ids waiting for a free slot. Kept separate from `items` so that
    /// completing a transfer does not remove it from the displayed list.
    private var pending: [UUID] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var cancelled: Set<UUID> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        client: RemoteFileClient,
        maxConcurrent: Int = 3,
        onUpdate: @escaping UpdateHandler
    ) {
        self.client = client
        self.maxConcurrent = max(1, maxConcurrent)
        self.onUpdate = onUpdate
    }

    // MARK: - Queueing

    public func enqueue(_ requests: [TransferRequest]) {
        for request in requests {
            guard !items.contains(where: { $0.id == request.id }) else { continue }
            let item = TransferItem(request: request)
            items.append(item)
            pending.append(request.id)
            onUpdate(item)
        }
        pump()
    }

    public func enqueue(_ request: TransferRequest) {
        enqueue([request])
    }

    public func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].state.isFinished else { return }

        if let task = running[id] {
            cancelled.insert(id)
            task.cancel()
            return
        }

        // Not started yet: drop it from the schedule and mark it cancelled.
        pending.removeAll { $0 == id }
        items[index].state = .cancelled
        items[index].finishedAt = Date()
        onUpdate(items[index])
        notifyIfIdle()
    }

    public func cancelAll() {
        // Snapshot first: cancelling mutates the schedule.
        for id in pending { cancel(id) }
        for id in running.keys { cancel(id) }
    }

    public func removeFinished() {
        items.removeAll { $0.state.isFinished }
    }

    public func snapshot() -> [TransferItem] {
        items
    }

    public var isIdle: Bool {
        running.isEmpty && pending.isEmpty
    }

    /// True when nothing is queued or in flight.
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    // MARK: - Scheduling

    private func pump() {
        while running.count < maxConcurrent {
            // Skip anything cancelled or already finished before it got a slot.
            while let first = pending.first {
                pending.removeFirst()
                guard let item = items.first(where: { $0.id == first }) else { continue }
                if cancelled.contains(first) || item.state.isFinished { continue }
                start(id: first)
                break
            }
            if pending.isEmpty { break }
        }
        notifyIfIdle()
    }

    private func start(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .running
        items[index].startedAt = Date()
        let item = items[index]
        onUpdate(item)

        let request = item.request
        let task = Task { [client] in
            do {
                switch request.direction {
                case .download:
                    try await client.download(
                        remotePath: request.sourcePath,
                        to: URL(fileURLWithPath: request.destinationPath),
                        progress: self.progressHandler(id: id)
                    )
                case .upload:
                    try await client.upload(
                        localURL: URL(fileURLWithPath: request.sourcePath),
                        to: request.destinationPath,
                        progress: self.progressHandler(id: id)
                    )
                }
                self.finish(id: id, state: Task.isCancelled ? .cancelled : .completed)
            } catch is CancellationError {
                self.finish(id: id, state: .cancelled)
            } catch {
                self.finish(
                    id: id,
                    state: Task.isCancelled ? .cancelled : .failed(Self.describe(error))
                )
            }
        }

        running[id] = task
    }

    /// Progress callbacks arrive on arbitrary threads, so they hop back here.
    private nonisolated func progressHandler(id: UUID) -> TransferProgressHandler {
        { done, total in
            Task { await self.record(id: id, done: done, total: total) }
        }
    }

    private func record(id: UUID, done: Int64, total: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].bytesTransferred = done
        if let startedAt = items[index].startedAt, total > 0 {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 0.2 {
                items[index].bytesPerSecond = Double(done) / elapsed
            }
        }
        // `total` can be corrected mid-flight when the server's size was unknown.
        if items[index].totalBytes == 0, total > 0 {
            items[index].totalBytes = total
        }
        onUpdate(items[index])
    }

    private func finish(id: UUID, state: TransferState) {
        running.removeValue(forKey: id)
        pending.removeAll { $0 == id }
        cancelled.remove(id)

        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = state
            items[index].finishedAt = Date()
            if state == .completed { items[index].bytesPerSecond = 0 }
            onUpdate(items[index])
        }

        pump()
    }

    private func notifyIfIdle() {
        guard isIdle else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private static func describe(_ error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription {
            return described
        }
        return error.localizedDescription
    }
}
