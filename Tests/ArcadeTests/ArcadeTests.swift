// ArcadeTests.swift
// Runs on an iOS Simulator (Xcode). The test bundle compiles the extension's sources directly, so these tests
// exercise the real audio unit render block, state saving, the SwiftUI interface and the model.
import XCTest
import SwiftUI
import AVFoundation
import AudioToolbox

private func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }

final class ArcadeTests: XCTestCase {
    private typealias MIDIMessage = (sample: Int64, bytes: [UInt8])

    private func makeUnit() throws -> ArcadeAudioUnit {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_MIDIProcessor,
                                             componentSubType: fourCC("Arcd"),
                                             componentManufacturer: fourCC("Abys"),
                                             componentFlags: 0, componentFlagsMask: 0)
        return try ArcadeAudioUnit(componentDescription: desc, options: [])
    }

    /// Runs the real render block against a fake host (tempo + beat position + transport) and collects its MIDI.
    private func render(_ au: ArcadeAudioUnit, seconds: Double, tempo: Double = 120,
                        moving: @escaping (Double) -> Bool = { _ in true },
                        each: ((Double) -> Void)? = nil) throws -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var beat = 0.0
        var isMoving = true
        au.midiOutputEventBlock = { time, _, length, bytes in
            out.append((time, Array(UnsafeBufferPointer(start: bytes, count: length))))
            return noErr
        }
        au.musicalContextBlock = { tempoPtr, _, _, beatPtr, _, _ in
            tempoPtr?.pointee = tempo
            beatPtr?.pointee = beat
            return true
        }
        au.transportStateBlock = { flagsPtr, _, _, _ in
            flagsPtr?.pointee = isMoving ? AUHostTransportStateFlags.moving : AUHostTransportStateFlags()
            return true
        }
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }

        let format = au.outputBusses[0].format
        let sampleRate = format.sampleRate
        let frames: AUAudioFrameCount = 512
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let block = au.internalRenderBlock
        var flags = AudioUnitRenderActionFlags()
        var sample = 0.0
        while sample / sampleRate < seconds {
            beat = sample / sampleRate * tempo / 60
            isMoving = moving(sample / sampleRate)
            each?(sample / sampleRate)
            var ts = AudioTimeStamp()
            ts.mSampleTime = sample
            ts.mFlags = .sampleTimeValid
            let status = block(&flags, &ts, frames, 0, buffer.mutableAudioBufferList, nil, nil)
            XCTAssertEqual(status, noErr)
            sample += Double(frames)
        }
        return out
    }

    // MARK: Audio unit

    func testAudioUnitHasMIDIOutputAndSilentAudioBus() throws {
        let au = try makeUnit()
        XCTAssertEqual(au.midiOutputNames, ["Abyssal Arcade"])
        XCTAssertEqual(au.outputBusses.count, 1)
        XCTAssertEqual(au.outputBusses[0].format.channelCount, 2)
    }

    func testRenderBlockEmitsNotesFromTheHostClock() throws {
        let au = try makeUnit()
        let events = try render(au, seconds: 20)
        let noteOns = events.filter { $0.bytes.count == 3 && $0.bytes[0] & 0xF0 == 0x90 }
        XCTAssertGreaterThan(noteOns.count, 40, "the starter scene should play")
        XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy { $0.sample <= $1.sample }, "MIDI must be in time order")
        XCTAssertTrue(noteOns.allSatisfy { $0.bytes[1] < 128 && $0.bytes[2] > 0 && $0.bytes[2] < 128 })
        let channels = Set(noteOns.map { $0.bytes[0] & 0x0F })
        XCTAssertTrue(channels.contains(0) || channels.contains(9), "Chug (ch 1) or Drums (ch 10) should sound in scene 1")
    }

    func testStoppingTheHostTransportSilencesEverything() throws {
        let au = try makeUnit()
        let stopAt = 4.0
        let events = try render(au, seconds: 9, moving: { $0 < stopAt })
        let sampleRate = au.outputBusses[0].format.sampleRate
        let afterStop = events.filter { Double($0.sample) / sampleRate > stopAt + 0.1 }
        XCTAssertTrue(afterStop.allSatisfy { $0.bytes[0] & 0xF0 != 0x90 }, "no new notes after the transport stops")
        XCTAssertTrue(events.contains { $0.bytes[0] & 0xF0 == 0xB0 && $0.bytes[1] == 123 }, "all-notes-off is sent on stop")
    }

    func testSwingAndQuantiseReachTheRenderedMIDI() throws {
        let au = try makeUnit()
        au.host.edit { e in
            e.clearAll()
            e.settings.quant = 1
            e.settings.swing = 0.5
            e.settings.humanize = 0
            e.settings.prog = 1
            e.place(.peg, c: 10, r: 3, voice: Voice.lead.rawValue)
            e.settings.gravity = 0.5
        }
        // drop an orb on the peg every 0.9 s while the host plays
        var nextDrop = 0.0
        let events = try render(au, seconds: 12, each: { t in
            if t >= nextDrop {
                au.host.edit { $0.launch(x: Arena.x(10) + 9, y: Arena.y(3) - 60, vx: 0, vy: 0) }
                nextDrop += 0.9
            }
        })
        let leadOns = events.filter { $0.bytes[0] == 0x91 }
        // Lead is on channel 2. With a straight 1/16 grid at 120 bpm every note-on lands on a 16th. MIDI timestamps are whole
        // samples and a 16th is 5512.5 samples at 44.1 kHz, so allow up to one sample of rounding.
        let sampleRate = au.outputBusses[0].format.sampleRate
        let grid = sampleRate * 60 / 120 / 4
        for on in leadOns {
            let phase = Double(on.sample).truncatingRemainder(dividingBy: grid)
            let off = min(phase, grid - phase)
            XCTAssertLessThanOrEqual(off, 1.01, "note-on at sample \(on.sample) is not on the host's 16th-note grid")
        }
        XCTAssertGreaterThan(leadOns.count, 4)
    }

    func testStateSurvivesSaveAndLoad() throws {
        let a = try makeUnit()
        a.host.edit { e in
            e.settings.swing = 0.67
            e.settings.prog = Music.customIndex
            e.settings.customProgression = [0, 6, 5]
            e.saveScene(5)
        }
        let state = a.fullState
        XCTAssertNotNil(state?["abyssal"])
        let b = try makeUnit()
        b.fullState = state
        let (s, scene) = b.host.edit { ($0.settings, $0.scenes[5]) }
        XCTAssertEqual(s.swing, 0.67, accuracy: 1e-9)
        XCTAssertEqual(s.customProgression, [0, 6, 5])
        XCTAssertEqual(scene?.customProgression, [0, 6, 5])
    }

    // MARK: Interface and model

    private func pixels(_ image: UIImage) throws -> (w: Int, h: Int, data: [UInt8]) {
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, data)
    }

    /// Prints the rendered picture into the test log (base64 PNG between markers) so it can be looked at afterwards.
    private func logPicture(_ image: UIImage, name: String) {
        if let png = image.pngData() { print("ARCADE_PNG_BEGIN:\(name):\(png.base64EncodedString()):ARCADE_PNG_END") }
    }

    @MainActor
    func testArenaDrawsPegsAndOrbs() throws {
        let model = ArcadeModel(au: try makeUnit())
        model.host.edit { $0.launch(x: 600, y: 300, vx: 0, vy: 0) }
        let renderer = ImageRenderer(content: ArenaView(model: model).frame(width: 900, height: 480))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "the arena should render")
        logPicture(image, name: "arena")
        let attachment = XCTAttachment(image: image)
        attachment.name = "arena"
        attachment.lifetime = .keepAlways
        add(attachment)
        let px = try pixels(image)
        var ember = 0, white = 0, i = 0
        while i < px.data.count {
            let r = Int(px.data[i]), g = Int(px.data[i + 1]), b = Int(px.data[i + 2])
            if r > 200 && g > 50 && g < 140 && b < 80 { ember += 1 }
            if r > 235 && g > 235 && b > 220 { white += 1 }
            i += 4
        }
        XCTAssertGreaterThan(ember, 100, "the Chug pegs (ember orange) should be drawn (\(ember) px)")
        XCTAssertGreaterThan(white, 10, "the launched orb should be drawn (\(white) px)")
    }

    @MainActor
    func testInterfaceRendersTheArena() throws {
        let model = ArcadeModel(au: try makeUnit())
        let content = ArcadeView(model: model).frame(width: 900, height: 720).background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "the SwiftUI interface should render")
        XCTAssertEqual(Int(image.size.width), 900)
        let attachment = XCTAttachment(image: image)
        attachment.name = "interface"
        attachment.lifetime = .keepAlways
        add(attachment)
        logPicture(image, name: "interface")

        // not blank: the rendered picture contains plenty of distinct colours
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        var colours = Set<UInt32>()
        var i = 0
        while i < w * h * 4 {
            colours.insert(UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]))
            i += 4 * 7
        }
        XCTAssertGreaterThan(colours.count, 30, "the interface looks blank (\(colours.count) colours)")
    }

    @MainActor
    func testModelEditingAndScenes() throws {
        let model = ArcadeModel(au: try makeUnit())
        let before = model.host.edit { $0.items.count }
        model.conjure()
        XCTAssertGreaterThan(model.host.edit { $0.items.count }, before)
        model.clearArena()
        XCTAssertEqual(model.host.edit { $0.items.count }, 0)

        model.host.edit { $0.place(.peg, c: 3, r: 3, voice: Voice.bass.rawValue) }
        model.sceneTapped(7)                                   // empty slot: saves
        XCTAssertTrue(model.host.edit { $0.scenes[7] != nil })
        model.clearArena()
        model.sceneTapped(7)                                   // filled slot: recalls (transport not running, so immediately)
        XCTAssertEqual(model.host.edit { $0.items.count }, 1)
    }

    @MainActor
    func testCustomProgressionEditor() throws {
        let model = ArcadeModel(au: try makeUnit())
        model.settings.prog = Music.customIndex
        model.setCustomValue(2, -5)
        model.setCustomValue(3, 99)                            // "end" on slot 4
        XCTAssertEqual(model.customList, [0, 6, -5])
        XCTAssertEqual(model.host.edit { $0.settings.customProgression }, [0, 6, -5], "edits reach the engine")
        XCTAssertEqual(model.chordNames.count, 3)
        XCTAssertEqual(model.chordNames.first, "Dm")
        XCTAssertEqual(model.customValue(1), 6)
        XCTAssertEqual(model.customValue(5), 99)
    }
}
