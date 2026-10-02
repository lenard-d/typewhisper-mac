import CoreAudio
import XCTest
@testable import TypeWhisper

final class AudioMuffleTests: XCTestCase {
    func testLowPassKeepsBassAndReducesHighFrequencies() throws {
        let bass = try filteredRMS(frequency: 100)
        let treble = try filteredRMS(frequency: 5_000)
        XCTAssertGreaterThan(bass, 0.65)
        XCTAssertLessThan(treble, bass * 0.03)
    }

    func testStereoChannelsDoNotMix() throws {
        let samples = (0..<12_000).flatMap { frame -> [Float] in
            [Float(sin(Double(frame) * 2 * .pi * 100 / 48_000)), 0]
        }
        let result = try process(samples, channels: 2)
        XCTAssertGreaterThan(result.enumerated().filter { $0.offset % 2 == 0 }.map { abs($0.element) }.max() ?? 0, 0.9)
        XCTAssertTrue(result.enumerated().filter { $0.offset % 2 == 1 }.allSatisfy { $0.element == 0 })
    }

    func testNonInterleavedStereoReadsTapAfterPhysicalInputs() throws {
        let filter = try XCTUnwrap(AudioMuffleFilterCreate(48_000, 2))
        defer { AudioMuffleFilterDestroy(filter) }
        var left = (0..<12_000).map { Float(sin(Double($0) * 2 * .pi * 100 / 48_000)) }
        var right = Array(repeating: Float(0), count: left.count)
        var filteredLeft = right
        var filteredRight = right
        let inputStorage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size + 2 * MemoryLayout<AudioBuffer>.stride,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let outputStorage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { inputStorage.deallocate(); outputStorage.deallocate() }
        let input = inputStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let output = outputStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        input.pointee.mNumberBuffers = 3
        output.pointee.mNumberBuffers = 2
        left.withUnsafeMutableBytes { leftData in
            right.withUnsafeMutableBytes { rightData in
                filteredLeft.withUnsafeMutableBytes { leftOutput in
                    filteredRight.withUnsafeMutableBytes { rightOutput in
                        let inputs = UnsafeMutableAudioBufferListPointer(input)
                        inputs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
                        inputs[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(leftData.count), mData: leftData.baseAddress)
                        inputs[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rightData.count), mData: rightData.baseAddress)
                        let outputs = UnsafeMutableAudioBufferListPointer(output)
                        outputs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(leftOutput.count), mData: leftOutput.baseAddress)
                        outputs[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rightOutput.count), mData: rightOutput.baseAddress)
                        var time = AudioTimeStamp()
                        _ = AudioMuffleFilterIOProc(0, &time, input, &time, output, &time, UnsafeMutableRawPointer(filter))
                    }
                }
            }
        }
        XCTAssertEqual(filteredLeft, try process(left, channels: 1))
        XCTAssertTrue(filteredRight.allSatisfy { $0 == 0 })
        XCTAssertFalse(AudioMuffleFilterHasFailed(filter))
    }

    func testInvalidBufferLayoutSilencesOutputAndReportsFailure() throws {
        let filter = try XCTUnwrap(AudioMuffleFilterCreate(48_000, 2))
        defer { AudioMuffleFilterDestroy(filter) }
        var samples: [Float] = [1, 1, 1, 1]
        var result = samples
        samples.withUnsafeMutableBytes { source in
            result.withUnsafeMutableBytes { target in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(source.count), mData: source.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(target.count), mData: target.baseAddress))
                var time = AudioTimeStamp()
                _ = AudioMuffleFilterIOProc(0, &time, &input, &time, &output, &time, UnsafeMutableRawPointer(filter))
            }
        }
        XCTAssertEqual(result, [0, 0, 0, 0])
        XCTAssertTrue(AudioMuffleFilterHasFailed(filter))
    }

    func testFilterRejectsUnsupportedSampleRatesAndChannelCounts() {
        XCTAssertNil(AudioMuffleFilterCreate(.nan, 2))
        XCTAssertNil(AudioMuffleFilterCreate(48_000, 3))
        XCTAssertNil(AudioMuffleFilterCreate(0, 1))
    }

    private func filteredRMS(frequency: Double) throws -> Double {
        let samples = (0..<24_000).map { Float(sin(Double($0) * 2 * .pi * frequency / 48_000)) }
        let result = try process(samples, channels: 1).dropFirst(12_000)
        return sqrt(result.reduce(0) { $0 + Double($1 * $1) } / Double(result.count))
    }

    private func process(_ samples: [Float], channels: UInt32) throws -> [Float] {
        let filter = try XCTUnwrap(AudioMuffleFilterCreate(48_000, channels))
        defer { AudioMuffleFilterDestroy(filter) }
        var samples = samples
        var result = Array(repeating: Float(0), count: samples.count)
        samples.withUnsafeMutableBytes { source in
            result.withUnsafeMutableBytes { target in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(source.count), mData: source.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(target.count), mData: target.baseAddress))
                var time = AudioTimeStamp()
                _ = AudioMuffleFilterIOProc(0, &time, &input, &time, &output, &time, UnsafeMutableRawPointer(filter))
            }
        }
        XCTAssertFalse(AudioMuffleFilterHasFailed(filter))
        return result
    }
}
