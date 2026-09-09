import Foundation

let listenerDelegate = AgentListener()
listenerDelegate.engine.start()

let listener = NSXPCListener(machServiceName: MixXPC.machService)
listener.delegate = listenerDelegate
listener.resume()

RunLoop.main.run()
