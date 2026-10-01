import CoreAudio
import AudioToolbox
import Foundation

/// Thin, throwing wrappers around the C `AudioObjectGetPropertyData` family so the
/// rest of the audio layer can read Core Audio properties without boilerplate.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func dataSize(_ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var addr = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size)
        guard status == noErr else { throw AudioError.coreAudio(status, "size of \(address.mSelector.fourCC)") }
        return size
    }

    /// Reads a fixed-layout value (numbers, structs).
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) throws -> T {
        var addr = Self.address(selector, scope: scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        // Go through `withUnsafeMutableBytes` rather than `&result`: taking a raw
        // pointer to a generic directly is only sound for trivial types, and the
        // compiler can't know that here.
        let status = withUnsafeMutableBytes(of: &result) { buffer in
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { throw AudioError.coreAudio(status, selector.fourCC) }
        return result
    }

    /// Reads a variable-length array property (e.g. object lists).
    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      of type: T.Type) throws -> [T] {
        var addr = Self.address(selector, scope: scope)
        let byteSize = try dataSize(addr)
        let count = Int(byteSize) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        var buffer = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        var size = byteSize
        let status = buffer.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { throw AudioError.coreAudio(status, selector.fourCC) }
        return Array(buffer.prefix(Int(size) / MemoryLayout<T>.size))
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var addr = Self.address(selector, scope: scope)
        // Core Audio hands back a +1 CFString; take ownership explicitly instead of
        // letting Swift bridge a reference through a raw pointer.
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutableBytes(of: &unmanaged) { buffer in
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr, let unmanaged else {
            throw AudioError.coreAudio(status, selector.fourCC)
        }
        return unmanaged.takeRetainedValue() as String
    }

    // MARK: - Convenience

    static func defaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice,
                                      default: AudioObjectID.unknown)
    }

    var deviceUID: String { (try? readString(kAudioDevicePropertyDeviceUID)) ?? "" }
    var deviceName: String { (try? readString(kAudioObjectPropertyName)) ?? "Unknown Device" }

    /// Every process Core Audio knows about (macOS 14.2+ process objects).
    static func allAudioProcesses() -> [AudioObjectID] {
        (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList,
                                             of: AudioObjectID.self)) ?? []
    }

    var processPID: pid_t { (try? read(kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1 }
    var processBundleID: String? { try? readString(kAudioProcessPropertyBundleID) }
    var isRunningOutput: Bool { ((try? read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0 }
}

extension AudioObjectPropertySelector {
    /// Renders a selector as its human-readable four-character code for error messages.
    var fourCC: String {
        let value = UInt32(self)
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        let string = String(bytes: bytes, encoding: .ascii) ?? "????"
        return string.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? "'\(string)'" : "\(value)"
    }
}

enum AudioError: LocalizedError {
    case coreAudio(OSStatus, String)
    case permissionDenied
    case noOutputDevice

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status, let what):
            return "Core Audio error \(status) while reading \(what)."
        case .permissionDenied:
            return "Audio recording permission was denied."
        case .noOutputDevice:
            return "No system audio output device is available."
        }
    }
}
