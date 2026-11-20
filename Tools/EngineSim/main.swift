// EngineSim: runs the engine against a fake host clock and checks the MIDI it produces.
import Foundation
import ArcadeEngine

struct Ev { var t: Double; var frame: Int; var status: UInt8; var d1: UInt8; var d2: UInt8 }

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print(ok ? "  PASS  " : "  FAIL  ", msg)
    if !ok { failures += 1 }
}

/// Fake host clock. `advance` runs the engine for some seconds and returns every MIDI message with its absolute time.
final class Runner {
    let e: ArcadeEngine
    var tick: Double, time = 0.0
    let bpm: Double, frames: Int, sr: Double
    init(_ e: ArcadeEngine, bpm: Double = 120, frames: Int = 256, sr: Double = 48000, startTick: Double = 0) {
        self.e = e; self.bpm = bpm; self.frames = frames; self.sr = sr; self.tick = startTick
    }
    var tps: Double { bpm / 60 * 4 }
    func advance(_ seconds: Double, transportStopsAfter: Double? = nil) -> [Ev] {
        var out: [Ev] = []
        let end = time + seconds
        while time < end - 1e-9 {
            let running = transportStopsAfter.map { time < $0 } ?? true
            let t0 = time
            e.process(frames: frames, sampleRate: sr, tickStart: tick, ticksPerSecond: tps, run: running) { off, st, d1, d2 in
                out.append(Ev(t: t0 + Double(off) / sr, frame: off, status: st, d1: d1, d2: d2))
            }
            tick += Double(frames) / sr * tps
            time += Double(frames) / sr
        }
        return out
    }
}
func run(_ e: ArcadeEngine, seconds: Double, bpm: Double = 120, startTick: Double = 0, transportStopsAfter: Double? = nil) -> [Ev] {
    Runner(e, bpm: bpm, startTick: startTick).advance(seconds, transportStopsAfter: transportStopsAfter)
}

func fresh(items: [Item] = [], configure: (inout Settings) -> Void = { _ in }) -> ArcadeEngine {
    let e = ArcadeEngine()
    e.clearAll()
    configure(&e.settings)
    for it in items { e.place(it.kind, c: it.c, r: it.r, voice: it.voice, chance: it.chance, ratchet: it.ratchet, angle: it.angle, div: it.div) }
    return e
}
func peg(_ c: Int, _ r: Int, _ v: Voice, chance: Double = 1, ratchet: Int = 1) -> Item {
    Item(id: 0, kind: .peg, c: c, r: r, voice: v.rawValue, chance: chance, ratchet: ratchet)
}
func spawner(_ c: Int, _ r: Int, div: Int = 4, angle: Double = Double.pi / 2) -> Item {
    Item(id: 0, kind: .spawner, c: c, r: r, angle: angle, div: div)
}
func ons(_ evs: [Ev]) -> [Ev] { evs.filter { $0.status & 0xF0 == 0x90 } }
func offs(_ evs: [Ev]) -> [Ev] { evs.filter { $0.status & 0xF0 == 0x80 } }

/// One orb dropped straight onto the peg at (10, 3) from above, so exactly one hit happens soon after the start.
func dropOnPeg(_ e: ArcadeEngine, offsetY: Double = 60, x: Double = 9) {
    e.settings.gravity = 0.5
    e.launch(x: Arena.x(10) + x, y: Arena.y(3) - offsetY, vx: 0, vy: 0)
}

print("1. starter scene plays, every on has an off, times never go backwards")
do {
    let e = ArcadeEngine()
    let evs = run(e, seconds: 20)
    let on = ons(evs), off = offs(evs)
    print("     notes on: \(on.count), off: \(off.count)")
    check(on.count > 40, "starter scene 1 produces notes (\(on.count))")
    check(zip(evs, evs.dropFirst()).allSatisfy { $0.t <= $1.t + 1e-9 }, "events are in time order across buffers")
    let e2 = ArcadeEngine()
    let evs2 = run(e2, seconds: 12, transportStopsAfter: 6)
    var held: [String: Int] = [:]
    for ev in evs2 {
        let ch = ev.status & 0x0F
        let k = "\(ch)-\(ev.d1)"
        if ev.status & 0xF0 == 0x90 { held[k, default: 0] += 1 }
        else if ev.status & 0xF0 == 0x80 { held[k, default: 0] -= 1 }
        else if ev.status & 0xF0 == 0xB0 && ev.d1 == 123 { for key in held.keys where key.hasPrefix("\(ch)-") { held[key] = 0 } }
    }
    check(held.values.allSatisfy { $0 <= 0 }, "no stuck notes after the transport stops")
    check(evs2.contains { $0.status & 0xF0 == 0xB0 && $0.d1 == 123 }, "all-notes-off sent when the transport stops")
    check(!evs2.contains { $0.t > 6.1 && $0.status & 0xF0 == 0x90 }, "no new notes after the transport stops")
}

print("2. pitch: in key, and following the progression")
do {
    // Lead peg on row 3, static progression: G3 (MIDI 55) in D Dorian
    let e = fresh(items: [peg(10, 3, .lead)]) { $0.prog = 1; $0.quant = 0 }
    dropOnPeg(e)
    let lead = ons(run(e, seconds: 2)).filter { $0.status & 0x0F == 1 }
    check(lead.first.map { Int($0.d1) } == 55, "Lead peg on row 3 in D Dorian plays G3 (MIDI 55); got \(lead.first.map { Int($0.d1) } ?? -1)")
    // The same peg under the Vamp progression: bar 1 = Dm (G), bar 2 = C (one scale step lower: F)
    var seen: [Int] = []
    for bar in 0..<2 {
        let p = fresh(items: [peg(10, 3, .lead)]) { $0.prog = 0; $0.quant = 1 }
        dropOnPeg(p)
        let ev = ons(run(p, seconds: 1.5, startTick: Double(bar * 16) + 0.5))
        if let f = ev.first { seen.append(Int(f.d1)) }
    }
    check(seen == [55, 53], "progression moves the same peg a scale step down on the second chord (\(seen))")
    // Bell rain scene under 'Dread': Lead/Bass/Bell notes stay inside D Dorian
    let d = ArcadeEngine()
    d.applyScene(3)
    d.settings.prog = 3
    let dorianPCs = Set(Music.scales[0].steps.map { Music.mod($0 + 2, 12) })
    let pitched = ons(run(d, seconds: 40)).filter { $0.status & 0x0F != 9 }
    let pcs = Set(pitched.map { Music.mod(Int($0.d1), 12) })
    print("     pitch classes used over 40 s: \(pcs.sorted().map { Music.noteNames[$0] })")
    check(pitched.count > 40 && pcs.isSubset(of: dorianPCs), "bells and bass stay inside D Dorian while the chords move (\(pitched.count) notes)")
}

print("3. quantise grid and swing")
do {
    let tps = 120.0 / 60 * 4
    func gridRun(swing: Double, humanize: Double = 0) -> [Double] {
        let e = fresh(items: [peg(10, 3, .lead)]) { $0.prog = 1; $0.quant = 1; $0.swing = swing; $0.humanize = humanize }
        let r = Runner(e)
        var evs: [Ev] = []
        for _ in 0..<40 { dropOnPeg(e); evs += r.advance(0.37) }
        evs += r.advance(1)
        return ons(evs).map { $0.t * tps }
    }
    let straight = gridRun(swing: 0.5)
    check(straight.count > 20 && straight.allSatisfy { abs($0 - $0.rounded()) < 0.03 }, "straight 1/16 grid: \(straight.count) notes, all on the grid")
    let swung = gridRun(swing: 0.67)
    let okSwing = swung.allSatisfy { t in
        let slot = Int(floor(t + 0.03)), f = t - Double(slot)
        return slot % 2 == 0 ? abs(f) < 0.03 : abs(f - 0.34) < 0.03
    }
    let oddCount = swung.filter { Int(floor($0 + 0.03)) % 2 == 1 }.count
    check(swung.count > 20 && okSwing && oddCount > 3, "swing 67%: off-beat slots land a third of a tick late (\(swung.count) notes, \(oddCount) off-beat)")
    let hum = gridRun(swing: 0.5, humanize: 1)
    let offGrid = hum.filter { abs($0 - $0.rounded()) > 0.01 }.count
    check(hum.count > 20 && offGrid > hum.count * 3 / 4, "humanize moves notes off the grid (\(offGrid) of \(hum.count))")
}

print("4. chance, ratchet, humanize, mute")
do {
    var hits = 0
    for _ in 0..<200 {
        let e = fresh(items: [peg(10, 3, .lead, chance: 0.25)]) { $0.prog = 1; $0.quant = 1 }
        dropOnPeg(e)
        if !ons(run(e, seconds: 1.2)).isEmpty { hits += 1 }
    }
    check(hits > 20 && hits < 85, "chance 25% plays about a quarter of the time (\(hits) of 200)")
    let e = fresh(items: [peg(10, 3, .lead, ratchet: 4)]) { $0.prog = 1; $0.quant = 1 }
    dropOnPeg(e)
    let evs = run(e, seconds: 1.5)
    let on = ons(evs)
    check(on.count == 4, "ratchet x4 plays four notes per hit (\(on.count))")
    check(on.count == 4 && on[0].d2 > on[3].d2, "ratchet repeats get quieter (\(on.map { Int($0.d2) }))")
    check(offs(evs).count == on.count, "ratchet notes all have matching offs")
    let m = fresh(items: [peg(10, 3, .lead)]) { $0.prog = 1; $0.mute[Voice.lead.rawValue] = true }
    dropOnPeg(m)
    check(ons(run(m, seconds: 1.5)).isEmpty, "a muted voice sends no MIDI")
}

print("5. channels and drum routing")
do {
    let e = fresh(items: [peg(10, 3, .chug)]) { $0.prog = 1; $0.quant = 1 }
    dropOnPeg(e)
    let on = ons(run(e, seconds: 1.5))
    let notes = Set(on.map { Int($0.d1) })
    check(on.count == 3 && notes == Set([43, 50, 55]), "Chug sends root, fifth and octave (\(notes.sorted()))")
    check(on.allSatisfy { $0.status & 0x0F == 0 }, "Chug is on MIDI channel 1 by default")
    let d = fresh(items: [peg(10, 3, .drums)]) { $0.prog = 1; $0.quant = 1 }
    dropOnPeg(d)
    let dn = ons(run(d, seconds: 1.5))
    check(dn.count == 1 && dn[0].d1 == 38 && dn[0].status & 0x0F == 9, "Drums row 3 is a snare on channel 10 (\(dn.map { ($0.d1, $0.status & 0x0F) }))")
    let c = fresh(items: [peg(10, 3, .bass)]) { $0.prog = 1; $0.channel[Voice.bass.rawValue] = 6 }
    dropOnPeg(c)
    check(ons(run(c, seconds: 1.5)).first.map { $0.status & 0x0F } == 6, "voice channel can be remapped")
}

print("6. spawner rate and chance")
do {
    let e = fresh(items: [spawner(15, 15, div: 4)]) { $0.prog = 1; $0.gravity = 0; $0.orbSpeed = 40 }
    _ = run(e, seconds: 4)
    check(e.orbs.count == 8, "quarter-note spawner makes 8 orbs in 2 bars (\(e.orbs.count))")
    var total = 0
    for _ in 0..<100 {
        let s = fresh(items: [Item(id: 0, kind: .spawner, c: 15, r: 15, chance: 0.3, angle: Double.pi / 2, div: 16)]) { $0.prog = 1; $0.orbSpeed = 40; $0.gravity = 0 }
        _ = run(s, seconds: 0.1, startTick: 0)
        total += s.orbs.count
    }
    check(total > 12 && total < 55, "spawner chance 30% over 100 bars gives about 30 orbs (\(total))")
}

print("7. scenes and persistence")
do {
    let e = ArcadeEngine()
    let n0 = e.items.count
    e.applyScene(1)
    check(e.items.count != n0 && e.settings.prog == 2 && e.settings.barsPerChord == 2, "scene 2 loads its items and progression")
    let data = e.exportState()
    let f = ArcadeEngine()
    if let d = data { f.importState(d) }
    check(data != nil && f.items.count == e.items.count && f.scenes.compactMap { $0 }.count == 4, "state round-trips through JSON (\(data?.count ?? 0) bytes)")
    let r = ArcadeEngine()
    _ = run(r, seconds: 0.3)
    r.recallScene(2)
    check(r.pendingScene == 2, "recall while running waits for the bar")
    _ = run(r, seconds: 3, startTick: 3)
    check(r.activeScene == 2, "scene applied on the next bar line")
}

print("9. all scales and progressions")
do {
    check(Music.scales.count == 41 && Music.progressions.count == 54, "41 scales and 54 progressions (53 + Custom) are defined (\(Music.scales.count), \(Music.progressions.count))")
    let uniqueScales = Set(Music.scales.map { $0.steps })
    check(uniqueScales.count == Music.scales.count, "no two scales share the same notes")
    check(Music.scales.allSatisfy { $0.steps.first == 0 && $0.steps == $0.steps.sorted() && ($0.steps.last ?? 99) < 12 }, "every scale starts on the root and ascends within one octave")
    let presets = Music.progressions.dropLast()
    check(Set(presets.map { "\($0.degrees)|\($0.semitones)" }).count == presets.count && Music.customIndex == 53, "no two preset progressions are identical; Custom is the last slot")
    check(Music.progressions.allSatisfy { $0.semitones.count == $0.degrees.count }, "every progression has one semitone move per chord")
    check(Music.progressions[0..<37].allSatisfy { $0.semitones.allSatisfy { $0 == 0 } } && Music.progressions[37..<53].allSatisfy { $0.semitones.contains { $0 != 0 } }, "the first 37 stay in key and the last 16 have chromatic moves")
    // a lead peg on every row, every scale, every progression: every pitch class stays inside the scale
    var badCombos = 0, notes = 0
    for (si, scale) in Music.scales.enumerated() {
        let inKey = Set(scale.steps.map { Music.mod($0 + 2, 12) })   // key D
        for pi in 0..<37 {
            let items = (0..<16).map { peg(2 + $0, $0, .lead) }
            let e = fresh(items: items) { $0.prog = pi; $0.quant = 1; $0.scale = si }
            e.settings.gravity = 0.5
            for k in 0..<16 { e.launch(x: Arena.x(2 + k) + 9, y: Arena.y(k) - 60, vx: 0, vy: 0) }
            let evs = ons(run(e, seconds: 3, startTick: 0)).filter { $0.status & 0x0F == 1 }
            notes += evs.count
            if !evs.allSatisfy({ inKey.contains(Music.mod(Int($0.d1), 12)) }) { badCombos += 1 }
        }
    }
    check(notes > 5000 && badCombos == 0, "all 41 scales x 37 in-key progressions stay in key (\(notes) notes checked, \(badCombos) bad)")

    // chromatic progressions: every note is a scale note shifted by one of that progression's semitone moves
    var badChromatic = 0, chromaticNotes = 0, leftKey = 0
    for pi in 37..<53 {
        let shifts = Set(Music.progressions[pi].semitones.map { Music.mod($0, 12) })
        for (si, scale) in Music.scales.enumerated() where si % 7 == 0 {
            let inKey = Set(scale.steps.map { Music.mod($0 + 2, 12) })
            let allowed = Set(shifts.flatMap { sh in inKey.map { Music.mod($0 + sh, 12) } })
            let items = (0..<16).map { peg(2 + $0, $0, .lead) }
            let e = fresh(items: items) { $0.prog = pi; $0.quant = 1; $0.scale = si }
            e.settings.gravity = 0.5
            for k in 0..<16 { e.launch(x: Arena.x(2 + k) + 9, y: Arena.y(k) - 60, vx: 0, vy: 0) }
            let evs = ons(run(e, seconds: 40)).filter { $0.status & 0x0F == 1 }
            chromaticNotes += evs.count
            if !evs.allSatisfy({ allowed.contains(Music.mod(Int($0.d1), 12)) }) { badChromatic += 1 }
            if evs.contains(where: { !inKey.contains(Music.mod(Int($0.d1), 12)) }) { leftKey += 1 }
        }
    }
    check(chromaticNotes > 2000 && badChromatic == 0, "chromatic moves only add the intended semitone shifts (\(chromaticNotes) notes, \(badChromatic) bad)")
    check(leftKey > 5, "chromatic progressions do leave the key, as intended (\(leftKey) runs)")
    // Tritone stab (index 40): the same Lead peg plays G3 (55) on the Dm bar and Ab (61) on the next bar
    var tri: [Int] = []
    for bar in 0..<2 {
        let e = fresh(items: [peg(10, 3, .lead)]) { $0.prog = 40; $0.quant = 1 }
        dropOnPeg(e)
        if let f = ons(run(e, seconds: 1.5, startTick: Double(bar * 16) + 0.5)).first { tri.append(Int(f.d1)) }
    }
    check(tri == [55, 61], "Tritone stab moves the same peg up six semitones on the second chord (\(tri))")
    // drums ignore chromatic moves
    var drumNotes = Set<Int>()
    for bar in 0..<2 {
        let e = fresh(items: [peg(10, 3, .drums)]) { $0.prog = 40; $0.quant = 1 }
        dropOnPeg(e)
        for ev in ons(run(e, seconds: 1.5, startTick: Double(bar * 16) + 0.5) ) { drumNotes.insert(Int(ev.d1)) }
    }
    check(drumNotes == [38], "drums are not transposed by chromatic moves (\(drumNotes.sorted()))")

    // --- the Custom progression ---
    func customPitches(_ custom: [Int], bars: Int) -> [Int] {
        var out: [Int] = []
        for bar in 0..<bars {
            let e = fresh(items: [peg(10, 3, .lead)]) { $0.prog = Music.customIndex; $0.quant = 1; $0.customProgression = custom }
            dropOnPeg(e)
            if let f = ons(run(e, seconds: 1.5, startTick: Double(bar * 16) + 0.5)).first { out.append(Int(f.d1)) }
        }
        return out
    }
    check(customPitches([0, 6], bars: 2) == [55, 61], "Custom [0, +6]: G then Ab, like Tritone stab (\(customPitches([0, 6], bars: 2)))")
    check(customPitches([0, 3, -5], bars: 4) == [55, 58, 50, 55], "Custom [0, +3, -5] cycles every three bars (\(customPitches([0, 3, -5], bars: 4)))")
    check(customPitches([12], bars: 1) == [67], "Custom [+12] plays an octave up (\(customPitches([12], bars: 1)))")
    let ce = fresh { $0.prog = Music.customIndex; $0.customProgression = [0, 1, 2, 3, 4] }
    check(ce.progressionLength == 5 && ce.chordShift(atTick: 16 * 3) == 3 && ce.chordShift(atTick: 16 * 5) == 0, "Custom length and per-bar shifts follow the list")
    ce.settings.customProgression = nil
    check(ce.progressionLength == 4 && ce.chordShift(atTick: 16) == 6, "an unset Custom falls back to the default list")
    ce.settings.customProgression = Array(repeating: 99, count: 3) + [-50]
    check(ce.chordShift(atTick: 0) == 12 && ce.chordShift(atTick: 16 * 3) == -12, "out-of-range Custom values are clamped to +-12")
    let saved = fresh { $0.prog = Music.customIndex; $0.customProgression = [0, 7, 5] }
    if let data = saved.exportState() {
        let back = ArcadeEngine(); back.importState(data)
        check(back.settings.prog == Music.customIndex && back.settings.customProgression == [0, 7, 5], "Custom progression round-trips through saved state")
        // state saved by an older build has no customProgression key: it must still load
        if var json = String(data: data, encoding: .utf8) {
            json = json.replacingOccurrences(of: "\"customProgression\":[0,7,5],", with: "").replacingOccurrences(of: ",\"customProgression\":[0,7,5]", with: "")
            let old = ArcadeEngine(); old.importState(Data(json.utf8))
            check(!json.contains("customProgression") && old.settings.customProgression == nil && old.items.count == saved.items.count, "state without a Custom list (older versions) still loads")
        }
    } else { check(false, "export state") }
    // --- scenes carry their own Custom list ---
    do {
        let e = fresh(items: [peg(10, 3, .lead)]) { $0.prog = Music.customIndex; $0.customProgression = [0, 6] }
        e.saveScene(0)
        e.settings.customProgression = [0, 3, -5]
        e.saveScene(1)
        e.settings.prog = 1                       // a scene that does not use Custom
        e.saveScene(2)
        check(e.scenes[0]?.customProgression == [0, 6] && e.scenes[1]?.customProgression == [0, 3, -5], "scenes using Custom store the list")
        check(e.scenes[2]?.customProgression == nil, "a scene that does not use Custom stores no list")
        e.settings.customProgression = [7]        // edit the live Custom list while another scene is active
        e.applyScene(2)
        check(e.settings.customProgression == [7], "recalling a non-Custom scene leaves your Custom list alone")
        e.applyScene(0)
        check(e.settings.prog == Music.customIndex && e.settings.customProgression == [0, 6], "recalling a Custom scene restores its list")
        e.applyScene(1)
        check(e.settings.customProgression == [0, 3, -5] && e.progressionLength == 3, "another Custom scene restores a different list")
        let data = e.exportState()
        let back = ArcadeEngine()
        if let d = data { back.importState(d) }
        check(back.scenes[0]?.customProgression == [0, 6] && back.scenes[1]?.customProgression == [0, 3, -5], "scene lists survive saved state")
        // an old scene without the key still loads
        if var json = data.flatMap({ String(data: $0, encoding: .utf8) }) {
            json = json.replacingOccurrences(of: ",\"customProgression\":[0,6]", with: "").replacingOccurrences(of: ",\"customProgression\":[0,3,-5]", with: "")
            let old = ArcadeEngine(); old.importState(Data(json.utf8))
            check(old.scenes[0] != nil && old.scenes[0]?.customProgression == nil, "scenes saved by older builds (no list) still load")
            old.settings.customProgression = [0, 5]
            old.applyScene(0)
            check(old.settings.customProgression == [0, 5], "a Custom scene without a stored list keeps the current one")
        }
        let p = fresh(items: [peg(10, 3, .lead)]) { $0.prog = Music.customIndex; $0.quant = 1; $0.customProgression = [0, 9, 9] }
        p.scenes[3] = SceneData(gravity: 0.5, swing: 0.5, humanize: 0, prog: Music.customIndex, barsPerChord: 1, mute: [false, false, false, false, false],
                                items: [peg(10, 3, .lead)], customProgression: [0, 6])
        p.applyScene(3)
        dropOnPeg(p)
        var seen: [Int] = []
        for bar in 0..<2 {
            let e2 = fresh(items: [peg(10, 3, .lead)]) { $0.prog = Music.customIndex; $0.quant = 1; $0.customProgression = [0, 9, 9] }
            e2.scenes[0] = p.scenes[3]; e2.applyScene(0)
            dropOnPeg(e2)
            if let f = ons(run(e2, seconds: 1.5, startTick: Double(bar * 16) + 0.5)).first { seen.append(Int(f.d1)) }
        }
        check(seen == [55, 61], "playing after recalling a Custom scene uses the scene's list (\(seen))")
    }
    check(Music.chordName(key: 2, scale: Music.scales[0], offset: 0, semitones: 6) == "Abm" && Music.intervalName(6) == "#4" && Music.intervalName(-5) == "5v", "chord and interval names for root moves")
}

print("8. cost per buffer")
do {
    let e = ArcadeEngine()
    let frames = 128, sr = 48000.0
    var worst = 0.0, tick = 0.0, total = 0.0, n = 0
    let wall = Date()
    for _ in 0..<(48000 * 30 / frames) {
        let a = Date()
        e.process(frames: frames, sampleRate: sr, tickStart: tick, ticksPerSecond: 8, run: true) { _, _, _, _ in }
        let d = Date().timeIntervalSince(a)
        worst = max(worst, d); total += d; n += 1
        tick += Double(frames) / sr * 8
    }
    let budget = Double(frames) / sr
    print(String(format: "     mean %.1f us, worst %.1f us per 128-frame buffer (budget %.0f us); wall %.2f s for 30 s of audio",
                 total / Double(n) * 1e6, worst * 1e6, budget * 1e6, Date().timeIntervalSince(wall)))
    check(total / Double(n) < budget * 0.1, "average cost is under 10% of the buffer budget")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
