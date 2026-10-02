import CoreAudio
import Foundation
import os

private let muffleLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "AudioMuffle")

@MainActor
protocol AudioMuffling: AnyObject {
    func start(onFailure: @escaping @MainActor (String) -> Void) throws
    func stop()
}

/// Replays a device-scoped process tap through a low-pass filter. The default device stays unchanged.
@MainActor
final class AudioMuffleService: AudioMuffling {
    private var session: AudioMuffleSession?
    private var monitor: Timer?

    func start(onFailure: @escaping @MainActor (String) -> Void) throws {
        guard session == nil else { return }
        guard #available(macOS 14.2, *) else {
            throw MuffleError.unsupportedSystem
        }
        let newSession = AudioMuffleSession()
        try newSession.start()
        session = newSession
        monitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session === newSession, !newSession.isOutputValid else { return }
                self.stop()
                onFailure(String(localized: "Audio output changed. Muffle stopped."))
            }
        }
    }

    func stop() {
        monitor?.invalidate()
        monitor = nil
        session?.stop()
        session = nil
    }
}

private enum MuffleError: LocalizedError {
    case unsupportedSystem
    case unsupportedOutput
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            String(localized: "Audio muffle requires macOS 14.2 or later.")
        case .unsupportedOutput:
            String(localized: "Audio muffle requires a mono or stereo Float32 output device.")
        case .coreAudio(let status):
            String(localized: "Could not start audio muffle. Allow system audio access in System Settings and try again.") + " (\(status))"
        }
    }
}

@MainActor
private final class AudioMuffleSession {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var filter: OpaquePointer?
    private var outputID: AudioObjectID = 0
    private var sampleRate: Double = 0

    var isOutputValid: Bool {
        guard let filter, !AudioMuffleFilterHasFailed(filter),
              let currentOutput: AudioObjectID = try? readProperty(
                AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self
              ), currentOutput == outputID,
              let currentRate: Double = try? readProperty(outputID, selector: kAudioDevicePropertyNominalSampleRate, as: Double.self) else {
            return false
        }
        return currentRate == sampleRate
    }

    @available(macOS 14.2, *)
    func start() throws {
        do {
            outputID = try readProperty(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
            let outputUID: CFString = try readProperty(outputID, selector: kAudioDevicePropertyDeviceUID, as: CFString.self)
            var pid = ProcessInfo.processInfo.processIdentifier
            var ownProcess: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
            try check(AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess
            ))
            guard ownProcess != kAudioObjectUnknown else { throw MuffleError.unsupportedOutput }
            let description = CATapDescription(excludingProcesses: [ownProcess], deviceUID: outputUID as String, stream: 0)
            description.name = "TypeWhisper Audio Muffle"
            description.isPrivate = true
            // Normal playback returns as soon as the IOProc stops, including on app exit.
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tapID))
            let format: AudioStreamBasicDescription = try readProperty(tapID, selector: kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                  format.mBitsPerChannel == 32,
                  (1...2).contains(format.mChannelsPerFrame),
                  let newFilter = AudioMuffleFilterCreate(format.mSampleRate, format.mChannelsPerFrame) else {
                throw MuffleError.unsupportedOutput
            }
            filter = newFilter
            sampleRate = format.mSampleRate
            let tapUID: CFString = try readProperty(tapID, selector: kAudioTapPropertyUID, as: CFString.self)
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "TypeWhisper Audio Muffle",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
            let outputFormat: AudioStreamBasicDescription = try readProperty(
                aggregateID, selector: kAudioDevicePropertyStreamFormat, as: AudioStreamBasicDescription.self, scope: kAudioDevicePropertyScopeOutput
            )
            guard outputFormat.mFormatID == format.mFormatID,
                  outputFormat.mFormatFlags == format.mFormatFlags,
                  outputFormat.mChannelsPerFrame == format.mChannelsPerFrame,
                  outputFormat.mSampleRate == format.mSampleRate else { throw MuffleError.unsupportedOutput }
            try check(AudioDeviceCreateIOProcID(aggregateID, AudioMuffleFilterIOProc, UnsafeMutableRawPointer(newFilter), &ioProcID))
            try disablePhysicalInputs()
            try check(AudioDeviceStart(aggregateID, ioProcID))
            muffleLogger.info("Audio muffle started")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        var callbackDestroyed = ioProcID == nil
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            callbackDestroyed = AudioDeviceDestroyIOProcID(aggregateID, ioProcID) == noErr
        }
        ioProcID = nil
        if aggregateID != 0 {
            callbackDestroyed = AudioHardwareDestroyAggregateDevice(aggregateID) == noErr || callbackDestroyed
            aggregateID = 0
        }
        if tapID != 0, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        // Keep storage alive if HAL could not remove the callback or its device.
        if let filter, callbackDestroyed { AudioMuffleFilterDestroy(filter) }
        filter = nil
    }

    private func disablePhysicalInputs() throws {
        guard let ioProcID else { throw MuffleError.unsupportedOutput }
        var address = propertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size))
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        let usage = storage.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        try check(AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, storage))
        guard usage.pointee.mNumberStreams > 0 else { throw MuffleError.unsupportedOutput }
        withUnsafeMutablePointer(to: &usage.pointee.mStreamIsOn) { firstStream in
            let streams = UnsafeMutableRawPointer(firstStream).assumingMemoryBound(to: UInt32.self)
            for index in 0..<Int(usage.pointee.mNumberStreams) {
                streams[index] = index == Int(usage.pointee.mNumberStreams) - 1 ? 1 : 0
            }
        }
        try check(AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, storage))
    }

    private func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // Specify the HAL value type so try? cannot infer an Optional with a different byte size.
    private func readProperty<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, as type: T.Type, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var address = propertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage))
        return storage.load(as: T.self)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw MuffleError.coreAudio(status) }
    }
}
