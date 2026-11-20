// AudioUnit.swift
// The AUv3 MIDI processor ('aumi'). It has no audio input and renders silence on a stereo output bus (some hosts
// only pull plugins that have an audio bus); its job is to emit MIDI from the arcade engine, locked to the host
// transport and tempo.
import AudioToolbox
import AVFoundation
import CoreAudioKit

/// Everything the render block needs, copied out of the AU in allocateRenderResources so the audio thread
/// never touches `self`.
final class RenderContext {
    var musical: AUHostMusicalContextBlock?
    var transport: AUHostTransportStateBlock?
    var midiOut: AUMIDIOutputEventBlock?
    var sampleRate = 44100.0
    // internal clock (used when the host gives no musical context, or when the user selects it)
    var useInternal = false
    var bpm = 104.0
    var internalRun = true
    var internalTick = 0.0
}

@inline(__always)
private func sendMIDI(_ out: AUMIDIOutputEventBlock, _ sampleTime: AUEventSampleTime, _ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
    var bytes: (UInt8, UInt8, UInt8) = (status, d1, d2)
    withUnsafePointer(to: &bytes) { tuplePtr in
        tuplePtr.withMemoryRebound(to: UInt8.self, capacity: 3) { ptr in
            _ = out(sampleTime, 0, 3, ptr)
        }
    }
}

public final class ArcadeAudioUnit: AUAudioUnit {
    public let host = EngineHost()
    private let ctx = RenderContext()
    private var outputBus: AUAudioUnitBus!
    private var outputBusArray: AUAudioUnitBusArray!

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
        syncFromSettings()
    }

    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var channelCapabilities: [NSNumber]? { [0, 2] }          // no inputs, stereo output
    public override var midiOutputNames: [String] { ["Abyssal Arcade"] }

    // MARK: Clock settings shared with the render thread

    /// Mirror the clock-related settings into the render context. Safe to call from the UI thread.
    public func syncFromSettings() {
        let s = host.edit { $0.settings }
        ctx.useInternal = s.internalClock
        ctx.bpm = s.bpm
    }

    public func setInternalRunning(_ on: Bool) { ctx.internalRun = on }
    public var internalRunning: Bool { ctx.internalRun }

    // MARK: Render resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        ctx.musical = musicalContextBlock
        ctx.transport = transportStateBlock
        ctx.midiOut = midiOutputEventBlock
        ctx.sampleRate = outputBus.format.sampleRate
        ctx.internalTick = 0
    }

    public override func deallocateRenderResources() {
        // release any note we may still be holding before the MIDI output goes away
        if let out = ctx.midiOut {
            host.edit { e in e.panic { _, st, d1, d2 in sendMIDI(out, AUEventSampleTime(0), st, d1, d2) } }
        }
        ctx.musical = nil
        ctx.transport = nil
        ctx.midiOut = nil
        super.deallocateRenderResources()
    }

    // MARK: Render

    public override var internalRenderBlock: AUInternalRenderBlock {
        let host = self.host
        let ctx = self.ctx
        return { _, timestamp, frameCount, _, outputData, _, _ in
            // silence on the (unused) audio output
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            for i in 0..<abl.count {
                if let data = abl[i].mData { memset(data, 0, Int(abl[i].mDataByteSize)) }
            }
            guard let midiOut = ctx.midiOut else { return noErr }
            let frames = Int(frameCount)
            let sr = ctx.sampleRate

            // transport: host tempo + beat position, or the internal clock
            var tempo = 120.0
            var beat = 0.0
            var haveMusical = false
            if let musical = ctx.musical { haveMusical = musical(&tempo, nil, nil, &beat, nil, nil) }
            var running = true
            if let transport = ctx.transport {
                var flags = AUHostTransportStateFlags()
                if transport(&flags, nil, nil, nil) { running = flags.contains(.moving) }
            }
            let tickStart: Double
            let tps: Double
            if ctx.useInternal || !haveMusical {
                tps = ctx.bpm / 60 * 4
                tickStart = ctx.internalTick
                running = ctx.internalRun
                if running { ctx.internalTick += Double(frames) / sr * tps }
            } else {
                tps = tempo / 60 * 4
                tickStart = beat * 4
            }

            let base = AUEventSampleTime(timestamp.pointee.mSampleTime)
            _ = host.tryProcess(frames: frames, sampleRate: sr, tickStart: tickStart, ticksPerSecond: tps, run: running) { offset, status, d1, d2 in
                sendMIDI(midiOut, base + AUEventSampleTime(offset), status, d1, d2)
            }
            return noErr
        }
    }

    // MARK: Project state

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            if let data = host.edit({ $0.exportState() }) { state["abyssal"] = data }
            return state
        }
        set {
            if let data = newValue?["abyssal"] as? Data { host.edit { $0.importState(data) } }
            super.fullState = newValue
            syncFromSettings()
        }
    }
}
