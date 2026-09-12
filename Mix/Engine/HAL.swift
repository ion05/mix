// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

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

    /// Reads a fixed-size scalar property.
    ///
    /// The type is passed explicitly instead of being inferred, and that is the
    /// whole point of the signature. Written as `try? HAL.get(device, sel)` in
    /// any of the obvious spellings, Swift resolves `T` to `Optional<UInt32>`
    /// rather than `UInt32`, asks CoreAudio for five bytes instead of four, and
    /// leaves the optional's tag byte holding whatever was in the freshly
    /// allocated page. The read then yields the real value or nil at random.
    /// Naming the type here makes that impossible.
    static func get<T: BitwiseCopyable>(
        _ type: T.Type,
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> T {
        var addr = address(selector, scope: scope)
        let expected = UInt32(MemoryLayout<T>.size)
        var size = expected
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        guard err == noErr else { throw HALError.status(err, "get \(fourCC(selector))") }
        guard size == expected else {
            throw HALError.status(err, "got \(size) of \(expected) bytes for \(fourCC(selector))")
        }
        return pointer.pointee
    }

    /// Reads a UInt32 flag property such as `livn` or `mute`.
    static func flag(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        let value = try? get(UInt32.self, object, selector, scope: scope)
        return (value ?? 0) != 0
    }

    static func getArray<T: BitwiseCopyable>(
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
        return cf.takeRetainedValue() as String
    }

    static func set<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ value: T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws {
        var addr = address(selector, scope: scope)
        var copy = value
        let err = withUnsafeMutableBytes(of: &copy) { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudio_ParamError }
            return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(bytes.count), base)
        }
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