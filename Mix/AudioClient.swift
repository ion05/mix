import Foundation

final class AudioClient {
    private var connection: NSXPCConnection?

    func proxy() -> MixAudioServing? {
        if connection == nil {
            connect()
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.connection = nil
        } as? MixAudioServing
    }

    func connect() {
        let conn = NSXPCConnection(machServiceName: MixXPC.machService, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: MixAudioServing.self)
        conn.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        conn.resume()
        connection = conn
    }

    func fetchSnapshot() async -> MixerSnapshot? {
        await withTimeout(seconds: 1.5) { continuation in
            guard let proxy = self.proxy() else {
                continuation.resume(returning: nil)
                return
            }
            proxy.fetchSnapshot { data in
                continuation.resume(returning: try? JSONDecoder().decode(MixerSnapshot.self, from: data))
            }
        }
    }

    func apply(_ command: MixCommand) async -> MixerSnapshot? {
        guard let data = try? JSONEncoder().encode(command) else { return nil }
        return await withTimeout(seconds: 1.5) { continuation in
            guard let proxy = self.proxy() else {
                continuation.resume(returning: nil)
                return
            }
            proxy.applyCommand(data) { data in
                continuation.resume(returning: try? JSONDecoder().decode(MixerSnapshot.self, from: data))
            }
        }
    }

    func quitAgent() async {
        await withTimeout(seconds: 1.0) { continuation in
            guard let proxy = self.proxy() else {
                continuation.resume(returning: nil)
                return
            }
            proxy.requestQuit {
                continuation.resume(returning: nil as MixerSnapshot?)
            }
        }
    }

    private func withTimeout(
        seconds: TimeInterval,
        _ body: @escaping (OnceContinuation<MixerSnapshot?>) -> Void
    ) async -> MixerSnapshot? {
        await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            body(once)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.resume(returning: nil)
            }
        }
    }
}

final class OnceContinuation<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
