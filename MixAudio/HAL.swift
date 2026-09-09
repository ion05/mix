import Foundation
import CoreAudio

enum HALError: Error {
    case status(OSStatus, String)
    case missing
}

enum HAL {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func exists(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectHasProperty(object, &addr)
    }

    static func size(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> Int {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard err == noErr else { throw HALError.status(err, "size \(fourCC(selector))") }
        return Int(size)
    }

    static func get<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        guard err == noErr else { throw HALError.status(err, "get \(fourCC(selector))") }
        return pointer.pointee
    }

    static func getArray<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard err == noErr else { throw HALError.status(err, "size \(fourCC(selector))") }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        guard err == noErr else { throw HALError.status(err, "get \(fourCC(selector))") }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    static func getCFString(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard err == noErr else { throw HALError.status(err, "size \(fourCC(selector))") }
        var cf: Unmanaged<CFString>?
        err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cf)
        guard err == noErr, let cf else { throw HALError.status(err, "get \(fourCC(selector))") }
        return cf.takeUnretainedValue() as String
    }

    static func set<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ value: T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws {
        var addr = address(selector, scope: scope)
        var copy = value
        let err = AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &copy)
        guard err == noErr else { throw HALError.status(err, "set \(fourCC(selector))") }
    }

    static func addListener(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue,
        block: @escaping () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        var addr = address(selector, scope: scope)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            queue.async { block() }
        }
        AudioObjectAddPropertyListenerBlock(object, &addr, queue, listener)
        return listener
    }

    static func removeListener(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var addr = address(selector, scope: scope)
        AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
    }

    static func fourCC(_ value: UInt32) -> String {
        let chars: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: chars, encoding: .ascii) ?? "\(value)"
    }
}

extension AudioObjectID {
    static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }
}
