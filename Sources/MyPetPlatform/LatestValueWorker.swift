import Foundation

/// Executes at most one value at a time and collapses queued updates to the
/// newest value. Pending state is lock-owned; the consumer never races a UI
/// callback that submits or cancels work.
final class LatestValueWorker<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let consume: (Value) -> Void
    private var pending: Value?
    private var running = false

    init(label: String, qos: DispatchQoS = .utility, consume: @escaping (Value) -> Void) {
        self.queue = DispatchQueue(label: label, qos: qos)
        self.consume = consume
    }

    func submit(_ value: Value) {
        lock.lock()
        pending = value
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    func cancelPendingAndWait() {
        lock.lock()
        pending = nil
        lock.unlock()
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            consume(value)
        }
    }
}
