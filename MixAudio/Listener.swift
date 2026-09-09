import Foundation

final class AgentListener: NSObject, NSXPCListenerDelegate {
    let engine = AudioEngine()
    private var connections: [NSXPCConnection] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MixAudioServing.self)
        connection.exportedObject = engine
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.engine.uiDidDisconnect()
            if let connection {
                self?.connections.removeAll { $0 === connection }
            }
        }
        connection.interruptionHandler = { [weak self] in
            self?.engine.uiDidDisconnect()
        }
        connections.append(connection)
        connection.resume()
        return true
    }
}
