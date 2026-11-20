// ArcadeEngine.swift
// The physics sequencer: orbs bounce around an arena of tuned pegs and every collision becomes MIDI.
// Pure Swift (Foundation only). It is driven from the audio thread: process() never allocates once the
// reserved capacities below are in place, and all time is expressed in 16th-note "ticks" of the host timeline.
import Foundation

// MARK: - Model types

public enum ItemKind: String, Codable { case peg, spawner, bumper, well }

public struct Item: Codable, Identifiable {
    public var id: Int
    public var kind: ItemKind
    public var c: Int
    public var r: Int
    public var voice: Int = 0          // Voice rawValue (pegs)
    public var chance: Double = 1      // pegs and spawners
    public var ratchet: Int = 1        // pegs, 1...4
    public var angle: Double = Double.pi / 2 + 0.04   // spawners, radians, screen space (y down)
    public var div: Int = 4            // spawners: ticks between orbs (16, 8, 4, 2, 1)
    public var glow: Double = 0        // UI flash, decays in process()

    public var x: Double { Arena.x(c) }
    public var y: Double { Arena.y(r) }
    public var radius: Double {
        switch kind { case .peg: return 13; case .bumper: return 22; case .spawner: return 16; case .well: return 18 }
    }

    enum CodingKeys: String, CodingKey { case id, kind, c, r, voice, chance, ratchet, angle, div }

    public init(id: Int, kind: ItemKind, c: Int, r: Int, voice: Int = 0, chance: Double = 1, ratchet: Int = 1,
                angle: Double = Double.pi / 2 + 0.04, div: Int = 4) {
        self.id = id; self.kind = kind; self.c = c; self.r = r; self.voice = voice
        self.chance = chance; self.ratchet = ratchet; self.angle = angle; self.div = div
    }
}

public struct Orb: Identifiable {
    public var id: Int
    public var x: Double, y: Double, vx: Double, vy: Double
    public var life: Int
    public var maxLife: Int
    public var age: Double = 0
    public var slow: Double = 0
    public var voice: Int = -1         // voice of the last peg hit (for colouring)
    var lastItem: Int = -1
    var lastItemTime: Double = -10
}

public struct Settings: Codable, Equatable {
    public var key = 2                 // D
    public var scale = 0               // Dorian
    public var quant = 1               // 0 raw, 1 = 1/16, 2 = 1/8, 4 = 1/4
    public var prog = 0                // Vamp
    public var barsPerChord = 1
    public var gravity = 0.35          // -1...1
    public var orbSpeed = 360.0        // points per second
    public var orbLife = 12            // hits; 41 = unlimited
    public var swing = 0.5             // 0.5 straight ... 0.75 dotted
    public var humanize = 0.0          // 0...1
    public var bpm = 104.0             // used by the internal clock
    public var internalClock = false
    public var powerChord = true       // Chug sends root + 5th + octave
    /// Chord roots of the Custom progression, in semitones from the tonic (1...8 entries). nil = default.
    public var customProgression: [Int]? = nil
    public var mute = [false, false, false, false, false]
    public var channel = Voice.defaultChannels   // 0-based MIDI channel per voice
    public init() {}
}

public struct SceneData: Codable {
    public var gravity: Double
    public var swing: Double
    public var humanize: Double
    public var prog: Int
    public var barsPerChord: Int
    public var mute: [Bool]
    public var items: [Item]
    /// The Custom progression's chord roots, stored only when the scene uses the Custom progression.
    public var customProgression: [Int]? = nil

    public init(gravity: Double, swing: Double, humanize: Double, prog: Int, barsPerChord: Int, mute: [Bool],
                items: [Item], customProgression: [Int]? = nil) {
        self.gravity = gravity; self.swing = swing; self.humanize = humanize; self.prog = prog
        self.barsPerChord = barsPerChord; self.mute = mute; self.items = items; self.customProgression = customProgression
    }
}

struct PersistedState: Codable {
    var settings: Settings
    var items: [Item]
    var scenes: [SceneData?]
}

struct Pending {
    var tick: Double
    var kind: UInt8      // 0 = note off, 1 = note on, 2 = controller
    var channel: UInt8
    var d1: UInt8
    var d2: UInt8
}

struct XorShift {
    var s: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s >> 11) / Double(UInt64(1) << 53)
    }
}

public struct Snapshot {
    public var items: [Item]
    public var orbs: [Orb]
    public var tick: Double
    public var running: Bool
    public var chordIndex: Int
    public var chordOffset: Int
    public var chordShift: Int
    public var pendingScene: Int?
}

// MARK: - Engine

public final class ArcadeEngine {
    public var settings = Settings()
    public var frozen = false
    public private(set) var items: [Item] = []
    public private(set) var orbs: [Orb] = []
    public var scenes: [SceneData?] = Array(repeating: nil, count: 8)
    public private(set) var activeScene = -1
    public private(set) var pendingScene: Int?
    public private(set) var currentTick = 0.0
    public private(set) var running = false

    private var pending: [Pending] = []
    private var scratch: [Pending] = []
    private var solidIdx: [Int] = []
    private var wellIdx: [Int] = []
    private var spawnIdx: [Int] = []
    private var nextItemID = 1
    private var nextOrbID = 1
    private var rng = XorShift()
    private var simTime = 0.0
    private var lastEndTick = -1.0
    private var nextTickToFire = 0
    private var progOrigin = 0
    private var held = [Int](repeating: 0, count: 16)
    // de-duplication of (item, grid slot) and a per-slot note cap
    private var dedupeItem = [Int](repeating: -1, count: 64)
    private var dedupeSlot = [Int](repeating: -1, count: 64)
    private var dedupePos = 0
    private var capSlot = [Int](repeating: -1, count: 8)
    private var capCount = [Int](repeating: 0, count: 8)
    private var ticksPerSecond = 8.0

    public static let maxOrbs = 48

    public init() {
        rng.s = UInt64.random(in: 1...UInt64.max)
        pending.reserveCapacity(1024)
        scratch.reserveCapacity(256)
        orbs.reserveCapacity(Self.maxOrbs + 4)
        items.reserveCapacity(700)
        solidIdx.reserveCapacity(700)
        wellIdx.reserveCapacity(64)
        spawnIdx.reserveCapacity(64)
        loadStarterScenes()
        applyScene(0)
    }

    // MARK: Editing (call under the host lock)

    private func rebuildIndex() {
        solidIdx.removeAll(keepingCapacity: true)
        wellIdx.removeAll(keepingCapacity: true)
        spawnIdx.removeAll(keepingCapacity: true)
        for (i, it) in items.enumerated() {
            switch it.kind {
            case .peg, .bumper: solidIdx.append(i)
            case .well: wellIdx.append(i)
            case .spawner: spawnIdx.append(i)
            }
        }
    }

    public func item(atC c: Int, r: Int) -> Item? { items.first { $0.c == c && $0.r == r } }

    @discardableResult
    public func place(_ kind: ItemKind, c: Int, r: Int, voice: Int = 0, chance: Double = 1, ratchet: Int = 1,
                      angle: Double = Double.pi / 2 + 0.04, div: Int = 4) -> Int {
        guard c >= 0, c < Arena.cols, r >= 0, r < Arena.rows else { return -1 }
        if let i = items.firstIndex(where: { $0.c == c && $0.r == r }) { items.remove(at: i) }
        let id = nextItemID; nextItemID += 1
        if items.count >= 600 { items.removeFirst() }
        items.append(Item(id: id, kind: kind, c: c, r: r, voice: voice, chance: chance, ratchet: ratchet, angle: angle, div: div))
        rebuildIndex()
        return id
    }

    public func removeItem(id: Int) {
        if let i = items.firstIndex(where: { $0.id == id }) { items.remove(at: i); rebuildIndex() }
    }

    public func removeItem(atC c: Int, r: Int) {
        if let i = items.firstIndex(where: { $0.c == c && $0.r == r }) { items.remove(at: i); rebuildIndex() }
    }

    public func update(id: Int, _ f: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { f(&items[i]) }
    }

    public func cycleSpawnerRate(id: Int) {
        let divs = [16, 8, 4, 2, 1]
        update(id: id) { it in
            let i = divs.firstIndex(of: it.div) ?? 2
            it.div = divs[(i + 1) % divs.count]
        }
    }

    /// Nearest peg or spawner within about one cell, used by the Tweak tool.
    public func nearestEditable(x: Double, y: Double) -> Int? {
        var best: Int? = nil
        var bd = 36.0
        for it in items where it.kind == .peg || it.kind == .spawner {
            let d = hypot(it.x - x, it.y - y)
            if d < bd { bd = d; best = it.id }
        }
        return best
    }

    public func launch(x: Double, y: Double, vx: Double, vy: Double) {
        spawnOrb(x: x, y: y, vx: vx, vy: vy)
    }

    public func flushOrbs() { orbs.removeAll(keepingCapacity: true) }

    public func clearAll() {
        items.removeAll(keepingCapacity: true)
        orbs.removeAll(keepingCapacity: true)
        rebuildIndex()
        activeScene = -1
    }

    // MARK: Scenes

    public func snapshotScene() -> SceneData {
        SceneData(gravity: settings.gravity, swing: settings.swing, humanize: settings.humanize,
                  prog: settings.prog, barsPerChord: settings.barsPerChord, mute: settings.mute, items: items,
                  customProgression: settings.prog == Music.customIndex ? (settings.customProgression ?? Music.defaultCustom) : nil)
    }

    public func saveScene(_ i: Int) {
        guard i >= 0, i < 8 else { return }
        scenes[i] = snapshotScene()
        activeScene = i
    }

    public func clearScene(_ i: Int) {
        guard i >= 0, i < 8 else { return }
        scenes[i] = nil
        if activeScene == i { activeScene = -1 }
    }

    public func applyScene(_ i: Int) {
        guard i >= 0, i < 8, let sc = scenes[i] else { return }
        items.removeAll(keepingCapacity: true)
        for var it in sc.items {
            it.id = nextItemID; nextItemID += 1
            it.glow = 0
            items.append(it)
        }
        settings.gravity = sc.gravity
        settings.swing = sc.swing
        settings.humanize = sc.humanize
        if sc.prog == Music.customIndex, let cp = sc.customProgression, !cp.isEmpty {
            settings.customProgression = Array(cp.prefix(Music.maxCustomChords)).map { min(max($0, -12), 12) }
        }
        if sc.prog != settings.prog || sc.barsPerChord != settings.barsPerChord {
            settings.prog = min(max(sc.prog, 0), Music.progressions.count - 1)
            settings.barsPerChord = [1, 2, 4].contains(sc.barsPerChord) ? sc.barsPerChord : 1
            progOrigin = (Int(currentTick) / 16) * 16
        }
        if sc.mute.count == 5 { settings.mute = sc.mute }
        activeScene = i
        rebuildIndex()
    }

    /// Recall a scene on the next bar line while running, immediately otherwise.
    public func recallScene(_ i: Int) {
        guard i >= 0, i < 8, scenes[i] != nil else { return }
        if running && !frozen { pendingScene = i } else { applyScene(i) }
    }

    /// Start the current progression from its first chord at the current bar.
    public func restartProgression() { progOrigin = (Int(max(0, currentTick)) / 16) * 16 }

    public func setProgression(_ p: Int) {
        settings.prog = min(max(p, 0), Music.progressions.count - 1)
        progOrigin = (Int(currentTick) / 16) * 16
    }

    // MARK: Harmony

    private var isCustom: Bool { settings.prog == Music.customIndex }

    /// Number of chords in the active progression (the Custom progression has 1...8).
    public var progressionLength: Int {
        if isCustom { return min(max((settings.customProgression ?? Music.defaultCustom).count, 1), Music.maxCustomChords) }
        return Music.progressions[min(max(settings.prog, 0), Music.progressions.count - 1)].degrees.count
    }

    public func chordIndex(atTick tick: Int) -> Int {
        let step = Music.floorDiv(tick - progOrigin, 16 * max(1, settings.barsPerChord))
        return Music.mod(step, progressionLength)
    }

    public func chordOffset(atTick tick: Int) -> Int {
        if isCustom { return 0 }
        let p = Music.progressions[min(max(settings.prog, 0), Music.progressions.count - 1)].degrees
        return p[chordIndex(atTick: tick)]
    }

    /// Chromatic root move (semitones) for the chord at this tick; 0 for in-key progressions.
    public func chordShift(atTick tick: Int) -> Int {
        let i = chordIndex(atTick: tick)
        if isCustom {
            let c = settings.customProgression ?? Music.defaultCustom
            return i < c.count ? min(max(c[i], -12), 12) : 0
        }
        let p = Music.progressions[min(max(settings.prog, 0), Music.progressions.count - 1)].semitones
        return i < p.count ? p[i] : 0
    }

    // MARK: Snapshot for the UI (allocates; call from the UI thread under the lock)

    public func makeSnapshot() -> Snapshot {
        let t = Int(max(0, currentTick))
        return Snapshot(items: items, orbs: orbs, tick: currentTick, running: running,
                        chordIndex: chordIndex(atTick: t), chordOffset: chordOffset(atTick: t),
                        chordShift: chordShift(atTick: t), pendingScene: pendingScene)
    }

    // MARK: Persistence

    public func exportState() -> Data? {
        try? JSONEncoder().encode(PersistedState(settings: settings, items: items, scenes: scenes))
    }

    public func importState(_ data: Data) {
        guard let st = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        settings = st.settings
        if settings.mute.count != 5 { settings.mute = [false, false, false, false, false] }
        if settings.channel.count != 5 { settings.channel = Voice.defaultChannels }
        items.removeAll(keepingCapacity: true)
        for var it in st.items { it.id = nextItemID; nextItemID += 1; items.append(it) }
        scenes = Array(st.scenes.prefix(8))
        while scenes.count < 8 { scenes.append(nil) }
        rebuildIndex()
    }

    // MARK: Real-time processing

    /// Advance the world by one render buffer.
    /// - Parameters:
    ///   - frames: frames in this buffer.
    ///   - sampleRate: sample rate in Hz.
    ///   - tickStart: host position of the buffer start in 16th notes.
    ///   - ticksPerSecond: tempo expressed in 16ths per second (bpm / 60 * 4).
    ///   - run: false while the host transport is stopped.
    ///   - emit: called for each MIDI message with its frame offset inside the buffer, in time order.
    public func process(frames: Int, sampleRate: Double, tickStart: Double, ticksPerSecond tps: Double, run: Bool,
                        emit: (_ frameOffset: Int, _ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> Void) {
        ticksPerSecond = tps
        if !run {
            if running { panic(emit: emit) }
            running = false
            lastEndTick = -1
            return
        }
        let dt = Double(frames) / sampleRate
        let tickEnd = tickStart + dt * tps
        if !running || lastEndTick < 0 || tickStart < lastEndTick - 0.05 || tickStart > lastEndTick + 4 {
            // start or relocate: drop sounding notes and queued events, restart the tick counter
            if running { panic(emit: emit) }
            pending.removeAll(keepingCapacity: true)
            nextTickToFire = Int(ceil(tickStart - 1e-6))
            progOrigin = 0   // harmony follows the host timeline: bar 1 = first chord
        }
        running = true
        currentTick = tickStart
        lastEndTick = tickEnd

        // grid ticks inside this buffer: spawners, scene recall
        while Double(nextTickToFire) < tickEnd - 1e-6 {
            onTick(nextTickToFire)
            nextTickToFire += 1
        }

        for i in 0..<items.count where items[i].glow > 0 { items[i].glow = max(0, items[i].glow - dt * 3.2) }
        if !frozen { stepPhysics(dt: dt, tickStart: tickStart, tickEnd: tickEnd) }

        // collect events due before the end of the buffer
        scratch.removeAll(keepingCapacity: true)
        var i = pending.count - 1
        while i >= 0 {
            if pending[i].tick < tickEnd {
                scratch.append(pending[i])
                pending.swapAt(i, pending.count - 1)
                pending.removeLast()
            }
            i -= 1
        }
        // insertion sort: by time, note offs before note ons at equal time
        if scratch.count > 1 {
            for a in 1..<scratch.count {
                let key = scratch[a]
                var b = a - 1
                while b >= 0, (scratch[b].tick > key.tick || (scratch[b].tick == key.tick && scratch[b].kind > key.kind)) {
                    scratch[b + 1] = scratch[b]; b -= 1
                }
                scratch[b + 1] = key
            }
        }
        let tickPerFrame = tps / sampleRate
        for ev in scratch {
            var off = tickPerFrame > 0 ? Int((ev.tick - tickStart) / tickPerFrame) : 0
            off = min(max(off, 0), max(frames - 1, 0))
            let ch = min(ev.channel, 15)
            switch ev.kind {
            case 1: held[Int(ch)] += 1; emit(off, 0x90 | ch, ev.d1, ev.d2)
            case 0: held[Int(ch)] = max(0, held[Int(ch)] - 1); emit(off, 0x80 | ch, ev.d1, 0)
            default: emit(off, 0xB0 | ch, ev.d1, ev.d2)
            }
        }
    }

    /// Silence everything the plugin has started (transport stop, relocate, unload).
    public func panic(emit: (Int, UInt8, UInt8, UInt8) -> Void) {
        pending.removeAll(keepingCapacity: true)
        for ch in 0..<16 where held[ch] > 0 {
            emit(0, 0xB0 | UInt8(ch), 123, 0)   // all notes off
            held[ch] = 0
        }
        orbs.removeAll(keepingCapacity: true)
        pendingScene = nil
    }

    // MARK: Internals

    private func onTick(_ idx: Int) {
        if idx % 16 == 0, let s = pendingScene { pendingScene = nil; applyScene(s) }
        if frozen { return }
        for si in spawnIdx {
            let it = items[si]
            if idx % it.div != 0 { continue }
            if it.chance < 1 && rng.next() > it.chance { continue }
            let c = cos(it.angle), s = sin(it.angle)
            spawnOrb(x: it.x + c * 22, y: it.y + s * 22, vx: c * settings.orbSpeed, vy: s * settings.orbSpeed)
            items[si].glow = 1
        }
    }

    private func spawnOrb(x: Double, y: Double, vx: Double, vy: Double) {
        if orbs.count >= Self.maxOrbs { orbs.removeFirst() }
        let life = settings.orbLife > 40 ? 1_000_000_000 : settings.orbLife
        orbs.append(Orb(id: nextOrbID, x: x, y: y, vx: vx, vy: vy, life: life, maxLife: min(life, 40)))
        nextOrbID += 1
    }

    private func stepPhysics(dt: Double, tickStart: Double, tickEnd: Double) {
        if orbs.isEmpty { return }
        let g = settings.gravity * 900
        let sub = min(8, max(1, Int(ceil(dt * 180))))
        let h = dt / Double(sub)
        let R = 7.0
        for s in 0..<sub {
            let tickNow = tickStart + (tickEnd - tickStart) * Double(s + 1) / Double(sub)
            simTime += h
            var i = 0
            while i < orbs.count {
                var o = orbs[i]
                o.vy += g * h
                for wi in wellIdx {
                    let w = items[wi]
                    let dx = w.x - o.x, dy = w.y - o.y
                    let d = hypot(dx, dy)
                    if d > 6 && d < 360 {
                        let a = min(2200, 100_000 / (d + 20))
                        o.vx += dx / d * a * h
                        o.vy += dy / d * a * h
                    }
                }
                o.x += o.vx * h
                o.y += o.vy * h
                if o.x < R { o.x = R; o.vx = abs(o.vx) * 0.99 } else if o.x > Arena.width - R { o.x = Arena.width - R; o.vx = -abs(o.vx) * 0.99 }
                if o.y > Arena.height - R { o.y = Arena.height - R; o.vy = -abs(o.vy) * (g > 0 ? 0.88 : 0.99) }
                else if o.y < R { o.y = R; o.vy = abs(o.vy) * (g < 0 ? 0.88 : 0.99) }
                for si in solidIdx {
                    let it = items[si]
                    let dx = o.x - it.x, dy = o.y - it.y
                    let rr = it.radius + R
                    if dx * dx + dy * dy < rr * rr {
                        let d = max(sqrt(dx * dx + dy * dy), 0.01)
                        let nx = dx / d, ny = dy / d
                        let vn = o.vx * nx + o.vy * ny
                        let speed = hypot(o.vx, o.vy)
                        if vn < 0 {
                            let e = it.kind == .bumper ? 1.15 : 0.96
                            o.vx -= (1 + e) * vn * nx
                            o.vy -= (1 + e) * vn * ny
                        }
                        o.x = it.x + nx * rr
                        o.y = it.y + ny * rr
                        handleHit(itemIndex: si, orb: &o, speed: speed, tickNow: tickNow)
                    }
                }
                orbs[i] = o
                i += 1
            }
        }
        var i = orbs.count - 1
        while i >= 0 {
            var o = orbs[i]
            let sp = hypot(o.vx, o.vy)
            if sp > 950 { o.vx *= 950 / sp; o.vy *= 950 / sp }
            o.age += dt
            o.slow = sp < 22 ? o.slow + dt : 0
            orbs[i] = o
            let maxAge = o.life > 100_000_000 ? 120.0 : 40.0
            if o.life <= 0 || o.slow > 1.4 || o.age > maxAge {
                orbs.swapAt(i, orbs.count - 1)
                orbs.removeLast()
            }
            i -= 1
        }
    }

    private func handleHit(itemIndex: Int, orb o: inout Orb, speed: Double, tickNow: Double) {
        let it = items[itemIndex]
        if o.lastItem == it.id && simTime - o.lastItemTime < 0.09 { return }
        o.lastItem = it.id
        o.lastItemTime = simTime
        if it.kind == .bumper { items[itemIndex].glow = 1; return }
        o.voice = it.voice
        o.life -= 1
        items[itemIndex].glow = 1
        schedule(item: it, speed: speed, tickNow: tickNow)
    }

    /// Turn one peg hit into quantised, swung, ratcheted, humanised MIDI.
    private func schedule(item it: Item, speed: Double, tickNow: Double) {
        if it.chance < 1 && rng.next() > it.chance { return }
        let s = settings
        let q = s.quant
        var idx: Int
        var t: Double
        if q == 0 {
            t = tickNow + 0.02
            idx = Int(floor(t))
        } else {
            let qd = Double(q)
            idx = Int(ceil(tickNow / qd - 1e-9)) * q
            let sw = (2 * s.swing - 1) * qd
            func odd(_ i: Int) -> Bool { Music.mod(i / q, 2) == 1 }
            if sw > 0, idx - q >= 0, odd(idx - q), Double(idx - q) + sw >= tickNow { idx -= q }
            t = Double(idx) + ((sw > 0 && odd(idx)) ? sw : 0)
        }
        // one note per peg per grid slot, and at most 12 notes per slot
        for k in 0..<dedupeItem.count where dedupeItem[k] == it.id && dedupeSlot[k] == idx { return }
        dedupeItem[dedupePos] = it.id; dedupeSlot[dedupePos] = idx
        dedupePos = (dedupePos + 1) % dedupeItem.count
        let cs = Music.mod(idx, capSlot.count)
        if capSlot[cs] != idx { capSlot[cs] = idx; capCount[cs] = 0 }
        capCount[cs] += 1
        if capCount[cs] > 12 { return }

        guard let voice = Voice(rawValue: it.voice) else { return }
        let scale = Music.scales[min(max(s.scale, 0), Music.scales.count - 1)]
        let off = voice == .drums ? 0 : chordOffset(atTick: max(0, idx))
        let shift = voice == .drums ? 0 : chordShift(atTick: max(0, idx))
        let channel = UInt8(min(max(s.channel[voice.rawValue], 0), 15))
        let vel01 = min(max(0.35 + speed / 800, 0.35), 1)
        let n = min(max(it.ratchet, 1), 4)
        let span = Double(max(q, 2))
        let silent = s.mute[voice.rawValue]
        for k in 0..<n {
            var tk = t + Double(k) * span / Double(n)
            var v = max(0.2, vel01 * pow(0.84, Double(k)))
            if s.humanize > 0 {
                tk = max(tickNow, tk + (rng.next() * 2 - 1) * s.humanize * 0.028 * ticksPerSecond)
                v = min(max(v * (1 + (rng.next() * 2 - 1) * s.humanize * 0.28), 0.2), 1)
            }
            let midiVel = UInt8(min(max(Int(v * 127), 1), 127))
            var dur = voice.noteTicks
            if voice == .chug && v > 0.78 && k == 0 { dur = 3 }       // hard hits ring open
            if n > 1 { dur = min(dur, span / Double(n) * 0.9) }
            dur = max(dur, 0.25)
            if silent { continue }
            if voice == .drums {
                pushNote(tick: tk, channel: channel, note: Int(Music.drumNotes[it.r]), vel: midiVel, dur: dur)
            } else {
                let base = Music.baseMidi(key: s.key) + Music.degreeSemitones(scale, it.r + off) + shift + voice.octave
                pushNote(tick: tk, channel: channel, note: base, vel: midiVel, dur: dur)
                if voice == .chug && s.powerChord {
                    pushNote(tick: tk, channel: channel, note: base + 7, vel: midiVel, dur: dur)
                    pushNote(tick: tk, channel: channel, note: base + 12, vel: midiVel, dur: dur)
                }
            }
        }
    }

    private func pushNote(tick: Double, channel: UInt8, note: Int, vel: UInt8, dur: Double) {
        guard note >= 0, note <= 127, pending.count + 2 <= pending.capacity else { return }
        let n = UInt8(note)
        // a still-sounding earlier copy of this note must end just before the new one starts
        for i in 0..<pending.count where pending[i].kind == 0 && pending[i].channel == channel && pending[i].d1 == n && pending[i].tick > tick - 0.001 {
            pending[i].tick = tick - 0.001
        }
        pending.append(Pending(tick: tick, kind: 1, channel: channel, d1: n, d2: vel))
        pending.append(Pending(tick: tick + dur, kind: 0, channel: channel, d1: n, d2: 0))
    }

    // MARK: Starter scenes (the same four as the web version)

    private func loadStarterScenes() {
        func peg(_ c: Int, _ r: Int, _ v: Voice, _ p: Double = 1, _ k: Int = 1) -> Item {
            Item(id: 0, kind: .peg, c: c, r: r, voice: v.rawValue, chance: p, ratchet: k)
        }
        func spawner(_ c: Int, _ r: Int, _ ang: Double, _ div: Int, _ p: Double = 1) -> Item {
            Item(id: 0, kind: .spawner, c: c, r: r, chance: p, angle: ang, div: div)
        }
        let pi2 = Double.pi / 2
        var s1: [Item] = [spawner(15, 15, pi2 + 0.05, 4), spawner(7, 15, pi2 - 0.04, 8, 0.7)]
        for a in [(13, 9), (17, 9), (11, 7), (15, 7), (19, 7), (13, 5), (17, 5), (11, 3), (15, 3), (19, 3), (13, 1), (17, 1)] { s1.append(peg(a.0, a.1, .chug)) }
        for a in [(11, 0), (15, 0), (19, 0)] { s1.append(peg(a.0, a.1, .drums)) }
        for a in [(12, 4), (18, 4)] { s1.append(peg(a.0, a.1, .drums, 1, 2)) }
        for a in [(11, 10), (19, 10)] { s1.append(peg(a.0, a.1, .drums, 0.6, 3)) }
        for a in [(11, 11), (19, 11)] { s1.append(peg(a.0, a.1, .lead, 0.7, 2)) }
        scenes[0] = SceneData(gravity: 0.45, swing: 0.58, humanize: 0.15, prog: 0, barsPerChord: 1, mute: [false, false, false, false, false], items: s1)

        var s2: [Item] = [Item(id: 0, kind: .well, c: 15, r: 8), spawner(2, 8, -0.2, 16), spawner(27, 13, 2.5, 16, 0.6)]
        for a in [(13, 11), (17, 11), (13, 5), (17, 5)] { s2.append(peg(a.0, a.1, .bell)) }
        for a in [(11, 8), (19, 8)] { s2.append(peg(a.0, a.1, .lead)) }
        for a in [(15, 12), (15, 4)] { s2.append(peg(a.0, a.1, .bass)) }
        scenes[1] = SceneData(gravity: 0, swing: 0.5, humanize: 0.3, prog: 2, barsPerChord: 2, mute: [false, false, false, false, false], items: s2)

        var s3: [Item] = [spawner(5, 15, pi2 - 0.06, 2)]
        for a in [(5, 12), (7, 10), (9, 8), (11, 6), (13, 4), (15, 2), (17, 0)] { s3.append(peg(a.0, a.1, .lead)) }
        for a in [(21, 0), (24, 0)] { s3.append(peg(a.0, a.1, .bass)) }
        for a in [(20, 8), (23, 6), (26, 4)] { s3.append(peg(a.0, a.1, .chug)) }
        scenes[2] = SceneData(gravity: 0.5, swing: 0.67, humanize: 0.2, prog: 4, barsPerChord: 1, mute: [false, false, false, false, false], items: s3)

        var s4: [Item] = [spawner(8, 15, pi2 + 0.03, 8), spawner(15, 15, pi2 - 0.05, 16), spawner(22, 15, pi2 + 0.04, 4, 0.5),
                          Item(id: 0, kind: .bumper, c: 15, r: 6), Item(id: 0, kind: .bumper, c: 6, r: 5), Item(id: 0, kind: .bumper, c: 24, r: 5)]
        let bells = [(6, 12), (10, 9), (13, 13), (17, 10), (20, 13), (24, 9), (27, 12), (4, 7), (21, 6), (9, 5), (12, 3), (18, 3)]
        for (i, a) in bells.enumerated() { s4.append(peg(a.0, a.1, .bell, i % 3 == 0 ? 1 : 0.55, i % 4 == 1 ? 3 : 1)) }
        for a in [(8, 0), (15, 0), (22, 0)] { s4.append(peg(a.0, a.1, .bass)) }
        scenes[3] = SceneData(gravity: 0.2, swing: 0.5, humanize: 0.4, prog: 3, barsPerChord: 2, mute: [false, false, false, false, false], items: s4)
    }
}

// MARK: - Thread-safe host wrapper

/// Owns the engine and a mutex. The UI takes the lock to edit or read; the render thread only try-locks,
/// so it never waits (a failed try-lock just skips that buffer's physics, ticks catch up on the next one).
public final class EngineHost {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    public let engine = ArcadeEngine()

    public init() { pthread_mutex_init(mutex, nil) }
    deinit { pthread_mutex_destroy(mutex); mutex.deallocate() }

    @discardableResult
    public func edit<T>(_ f: (ArcadeEngine) -> T) -> T {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return f(engine)
    }

    @inline(__always)
    public func tryProcess(frames: Int, sampleRate: Double, tickStart: Double, ticksPerSecond: Double, run: Bool,
                           emit: (Int, UInt8, UInt8, UInt8) -> Void) -> Bool {
        guard pthread_mutex_trylock(mutex) == 0 else { return false }
        defer { pthread_mutex_unlock(mutex) }
        engine.process(frames: frames, sampleRate: sampleRate, tickStart: tickStart, ticksPerSecond: ticksPerSecond, run: run, emit: emit)
        return true
    }
}
