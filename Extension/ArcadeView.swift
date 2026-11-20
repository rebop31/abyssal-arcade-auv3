// ArcadeView.swift
// SwiftUI interface for the plugin: the arena (Canvas + drag gestures) and the controls.
import SwiftUI

// MARK: - Style

private enum Palette {
    static let bg = Color(red: 0.04, green: 0.03, blue: 0.035)
    static let panel = Color(red: 0.09, green: 0.065, blue: 0.075)
    static let line = Color(red: 0.18, green: 0.14, blue: 0.155)
    static let bone = Color(red: 0.91, green: 0.86, blue: 0.78)
    static let ash = Color(red: 0.52, green: 0.47, blue: 0.44)
    static let ember = Color(red: 1.0, green: 0.353, blue: 0.122)
    static let blood = Color(red: 0.83, green: 0.082, blue: 0.247)
    static let void_ = Color(red: 0.6, green: 0.42, blue: 1.0)
    static let voices: [Color] = [
        Color(red: 1.0, green: 0.353, blue: 0.122),
        Color(red: 0.949, green: 0.757, blue: 0.306),
        Color(red: 0.831, green: 0.082, blue: 0.247),
        Color(red: 0.498, green: 0.839, blue: 0.902),
        Color(red: 0.851, green: 0.82, blue: 0.761),
    ]
}

enum Tool: String, CaseIterable {
    case launch = "Launch", peg = "Peg", spawner = "Spawner", bumper = "Bumper", well = "Well", tweak = "Tweak", erase = "Erase"
}

// MARK: - Model

final class ArcadeModel: ObservableObject {
    let au: ArcadeAudioUnit
    var host: EngineHost { au.host }

    @Published var tool: Tool = .peg
    @Published var voice: Voice = .chug
    @Published var brushChance = 1.0
    @Published var brushRatchet = 1
    @Published var selectedID: Int? = nil
    @Published var selChance = 1.0
    @Published var selRatchet = 1
    @Published var selIsSpawner = false
    @Published var storeMode = false
    @Published var aimStart: CGPoint? = nil
    @Published var aimEnd: CGPoint? = nil
    @Published var sceneFilled = [Bool](repeating: false, count: 8)
    @Published var activeScene = -1
    @Published var pendingScene: Int? = nil
    @Published var frozen = false
    @Published var internalRunning = true
    @Published var settings: Settings {
        didSet { if !applying { push() } }
    }

    private var applying = false
    private var timer: Timer?

    private enum Drag {
        case idle
        case launch
        case paint(add: Bool)
        case spawn(c: Int, r: Int)
        case erase
    }
    private var drag: Drag = .idle
    private var began = false

    init(au: ArcadeAudioUnit) {
        self.au = au
        self.settings = au.host.edit { $0.settings }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    // MARK: Engine <-> UI sync

    private func push() {
        let s = settings
        host.edit { e in
            let harmonyChanged = e.settings.prog != s.prog || e.settings.barsPerChord != s.barsPerChord
            e.settings = s
            if harmonyChanged { e.restartProgression() }
        }
        au.syncFromSettings()
    }

    func refresh() {
        struct State { var settings: Settings; var scene: Int; var pending: Int?; var filled: [Bool]; var frozen: Bool
                       var chance: Double?; var ratchet: Int; var spawner: Bool; var selExists: Bool }
        let sel = selectedID
        let st: State = host.edit { e in
            let it = sel.flatMap { id in e.items.first { $0.id == id } }
            return State(settings: e.settings, scene: e.activeScene, pending: e.pendingScene, filled: e.scenes.map { $0 != nil },
                         frozen: e.frozen, chance: it?.chance, ratchet: it?.ratchet ?? 1, spawner: it?.kind == .spawner, selExists: it != nil)
        }
        if st.settings != settings { applying = true; settings = st.settings; applying = false }
        if st.scene != activeScene { activeScene = st.scene }
        if st.pending != pendingScene { pendingScene = st.pending }
        if st.filled != sceneFilled { sceneFilled = st.filled }
        if st.frozen != frozen { frozen = st.frozen }
        if sel != nil && !st.selExists { selectedID = nil }
        if let c = st.chance, c != selChance { selChance = c }
        if st.ratchet != selRatchet { selRatchet = st.ratchet }
        if st.spawner != selIsSpawner { selIsSpawner = st.spawner }
        let run = au.internalRunning
        if run != internalRunning { internalRunning = run }
    }

    var chordNames: [String] {
        let scale = Music.scales[min(max(settings.scale, 0), Music.scales.count - 1)]
        if settings.prog == Music.customIndex {
            return customList.map { Music.chordName(key: settings.key, scale: scale, offset: 0, semitones: $0) }
        }
        let prog = Music.progressions[min(max(settings.prog, 0), Music.progressions.count - 1)]
        return prog.degrees.enumerated().map { i, d in
            Music.chordName(key: settings.key, scale: scale, offset: d, semitones: i < prog.semitones.count ? prog.semitones[i] : 0)
        }
    }

    // MARK: Custom progression

    var customList: [Int] { settings.customProgression ?? Music.defaultCustom }

    /// Picker value for slot i: the semitone move, or 99 for "end of list".
    func customValue(_ i: Int) -> Int { i < customList.count ? customList[i] : 99 }

    func setCustomValue(_ i: Int, _ v: Int) {
        var c = customList
        if v == 99 {
            if i > 0 && i < c.count { c = Array(c.prefix(i)) }
        } else {
            while c.count < i { c.append(0) }
            if i < c.count { c[i] = v } else if c.count < Music.maxCustomChords { c.append(v) }
        }
        settings.customProgression = c
    }

    func progressionName(_ i: Int) -> String {
        if i == Music.customIndex { return "Custom  " + customList.map { Music.intervalName($0) }.joined(separator: " > ") }
        return Music.progressions[i].name
    }

    // MARK: Chance / ratchet (brush or the selected item)

    var chanceValue: Double { selectedID != nil ? selChance : brushChance }
    var ratchetValue: Int { selectedID != nil ? selRatchet : brushRatchet }

    func setChance(_ v: Double) {
        if let id = selectedID { host.edit { $0.update(id: id) { $0.chance = v } }; selChance = v } else { brushChance = v }
    }

    func setRatchet(_ k: Int) {
        if let id = selectedID, !selIsSpawner { host.edit { $0.update(id: id) { $0.ratchet = k } }; selRatchet = k }
        else if selectedID == nil { brushRatchet = k }
    }

    // MARK: Scenes

    func sceneTapped(_ i: Int) {
        if storeMode || !sceneFilled[i] { host.edit { $0.saveScene(i) } }
        else { host.edit { $0.recallScene(i) } }
        refresh()
    }

    func clearScene(_ i: Int) { host.edit { $0.clearScene(i) }; refresh() }

    // MARK: Arena actions

    func toggleFreeze() { host.edit { $0.frozen.toggle() }; refresh() }
    func flushOrbs() { host.edit { $0.flushOrbs() } }
    func clearArena() { host.edit { $0.clearAll() }; selectedID = nil; refresh() }
    func toggleInternalRun() { au.setInternalRunning(!au.internalRunning); refresh() }

    func conjure() {
        host.edit { e in
            let pool: [Voice] = [.chug, .chug, .lead, .bell, .bass]
            var placed = 0
            while placed < 10 {
                let c = 1 + Int.random(in: 0..<(Arena.cols - 2)), r = 1 + Int.random(in: 0..<13)
                if e.item(atC: c, r: r) != nil { continue }
                let v = Bool.random() ? voice : pool[Int.random(in: 0..<pool.count)]
                e.place(.peg, c: c, r: r, voice: v.rawValue, chance: brushChance, ratchet: brushRatchet)
                placed += 1
            }
            let c = 3 + Int.random(in: 0..<24)
            if e.item(atC: c, r: 15) == nil {
                e.place(.spawner, c: c, r: 15, angle: Double.pi / 2 + (Double.random(in: 0..<1) - 0.5) * 0.3, div: Bool.random() ? 4 : 8)
            }
        }
    }

    // MARK: Gestures (points arrive in view space; `scale` converts to arena units)

    func dragChanged(_ v: DragGesture.Value, scale: CGFloat) {
        let s = CGPoint(x: v.startLocation.x / scale, y: v.startLocation.y / scale)
        let p = CGPoint(x: v.location.x / scale, y: v.location.y / scale)
        if !began { began = true; begin(at: s) }
        switch drag {
        case .launch, .spawn:
            aimStart = aimStart ?? s
            aimEnd = p
        case .paint(let add):
            paint(at: p, add: add)
        case .erase:
            host.edit { $0.removeItem(atC: Arena.col(Double(p.x)), r: Arena.row(Double(p.y))) }
        case .idle:
            break
        }
    }

    func dragEnded(_ v: DragGesture.Value, scale: CGFloat) {
        let s = CGPoint(x: v.startLocation.x / scale, y: v.startLocation.y / scale)
        let p = CGPoint(x: v.location.x / scale, y: v.location.y / scale)
        let dx = Double(p.x - s.x), dy = Double(p.y - s.y), len = hypot(dx, dy)
        switch drag {
        case .launch:
            if len < 14 {
                host.edit { $0.launch(x: Double(s.x), y: Double(s.y), vx: 0, vy: 0) }
            } else {
                let sp = min(900, len * 3.4)       // slingshot: drag back, release
                host.edit { $0.launch(x: Double(s.x), y: Double(s.y), vx: -dx / len * sp, vy: -dy / len * sp) }
            }
        case .spawn(let c, let r):
            let existing = host.edit { $0.item(atC: c, r: r) }
            if len < 22, let ex = existing, ex.kind == .spawner {
                host.edit { $0.cycleSpawnerRate(id: ex.id) }
            } else {
                let ang = len < 22 ? Double.pi / 2 + 0.04 : atan2(dy, dx)
                host.edit { $0.place(.spawner, c: c, r: r, chance: 1, angle: ang, div: 4) }
            }
        default:
            break
        }
        drag = .idle
        began = false
        aimStart = nil
        aimEnd = nil
    }

    private func begin(at s: CGPoint) {
        let c = Arena.col(Double(s.x)), r = Arena.row(Double(s.y))
        switch tool {
        case .launch:
            drag = .launch
        case .peg:
            let ex = host.edit { $0.item(atC: c, r: r) }
            if let ex = ex, ex.kind == .peg, ex.voice == voice.rawValue {
                host.edit { $0.removeItem(id: ex.id) }
                drag = .paint(add: false)
            } else {
                drag = .paint(add: true)
                paintCell(c, r)
            }
        case .spawner:
            drag = .spawn(c: c, r: r)
        case .bumper, .well:
            let kind: ItemKind = tool == .bumper ? .bumper : .well
            let ex = host.edit { $0.item(atC: c, r: r) }
            if let ex = ex, ex.kind == kind {
                host.edit { $0.removeItem(id: ex.id) }
                drag = .paint(add: false)
            } else {
                drag = .paint(add: true)
                paintCell(c, r)
            }
        case .tweak:
            selectedID = host.edit { $0.nearestEditable(x: Double(s.x), y: Double(s.y)) }
            refresh()
            drag = .idle
        case .erase:
            host.edit { $0.removeItem(atC: c, r: r) }
            drag = .erase
        }
    }

    private func paint(at p: CGPoint, add: Bool) {
        let c = Arena.col(Double(p.x)), r = Arena.row(Double(p.y))
        if add { paintCell(c, r) } else { host.edit { $0.removeItem(atC: c, r: r) } }
    }

    private func paintCell(_ c: Int, _ r: Int) {
        host.edit { e in
            let ex = e.item(atC: c, r: r)
            switch tool {
            case .peg:
                if let ex = ex, ex.kind == .peg, ex.voice == voice.rawValue { return }
                e.place(.peg, c: c, r: r, voice: voice.rawValue, chance: brushChance, ratchet: brushRatchet)
            case .bumper:
                if ex?.kind == .bumper { return }
                e.place(.bumper, c: c, r: r)
            case .well:
                if ex?.kind == .well { return }
                e.place(.well, c: c, r: r)
            default:
                break
            }
        }
    }
}

// MARK: - Arena drawing

private func polygon(_ c: CGPoint, _ r: CGFloat, _ sides: Int, _ rot: CGFloat) -> Path {
    var p = Path()
    for i in 0..<sides {
        let a = rot + CGFloat(i) * 2 * .pi / CGFloat(sides)
        let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

private let voiceSides = [4, 3, 6, 8, 4]
private let voiceRot: [CGFloat] = [-.pi / 2, -.pi / 2, 0, .pi / 8, .pi / 4]
private let divNames: [Int: String] = [16: "1 bar", 8: "1/2", 4: "1/4", 2: "1/8", 1: "1/16"]

private func glow(_ g: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ color: Color, _ alpha: Double) {
    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    g.fill(Path(ellipseIn: rect),
           with: .radialGradient(Gradient(colors: [color.opacity(alpha), color.opacity(0)]), center: c, startRadius: 0, endRadius: r))
}

private func drawArena(_ gc: GraphicsContext, size: CGSize, snap: Snapshot, model: ArcadeModel) {
    var g = gc
    let sc = size.width / CGFloat(Arena.width)
    g.scaleBy(x: sc, y: sc)
    let W = CGFloat(Arena.width), H = CGFloat(Arena.height), cell = CGFloat(Arena.cell)
    g.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(Palette.bg))

    let s = model.settings
    let scale = Music.scales[min(max(s.scale, 0), Music.scales.count - 1)]
    let n = scale.steps.count
    for r in 0..<Arena.rows {
        let y = CGFloat(Arena.rows - 1 - r) * cell
        let deg = r + snap.chordOffset
        let idx = Music.mod(deg, n)
        let semi = scale.steps[idx]
        let isRoot = idx == 0
        if isRoot { g.fill(Path(CGRect(x: 0, y: y, width: W, height: cell)), with: .color(Palette.ember.opacity(0.12))) }
        else if semi == 7 { g.fill(Path(CGRect(x: 0, y: y, width: W, height: cell)), with: .color(Palette.blood.opacity(0.07))) }
        else if r % 2 == 1 { g.fill(Path(CGRect(x: 0, y: y, width: W, height: cell)), with: .color(Color.white.opacity(0.016))) }
        g.fill(Path(CGRect(x: 0, y: y + cell - 1, width: W, height: 1)), with: .color(isRoot ? Palette.ember.opacity(0.35) : Palette.bone.opacity(0.06)))
        let name = Music.noteNames[Music.mod(Music.baseMidi(key: s.key) + Music.degreeSemitones(scale, deg) + snap.chordShift, 12)]
        g.draw(Text(name).font(.system(size: 12, design: .monospaced)).foregroundColor(isRoot ? Palette.ember : Palette.bone.opacity(0.42)),
               at: CGPoint(x: 10, y: y + cell / 2), anchor: .leading)
        g.draw(Text("\(idx + 1)").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.bone.opacity(0.2)),
               at: CGPoint(x: 34, y: y + cell / 2), anchor: .leading)
    }
    var grid = Path()
    for c in 1..<Arena.cols { grid.move(to: CGPoint(x: CGFloat(c) * cell, y: 0)); grid.addLine(to: CGPoint(x: CGFloat(c) * cell, y: H)) }
    g.stroke(grid, with: .color(Palette.bone.opacity(0.035)), lineWidth: 1)

    // beat strip
    let pos = Music.mod(Int(floor(max(0, snap.tick))), 16)
    for i in 0..<16 {
        let x = CGFloat(i) * W / 16
        let on = snap.running && i == pos
        g.fill(Path(CGRect(x: x + 3, y: 0, width: W / 16 - 6, height: i % 4 == 0 ? 5 : 3)),
               with: .color(on ? Palette.ember : Palette.bone.opacity(i % 4 == 0 ? 0.35 : 0.12)))
    }

    // items
    for it in snap.items {
        let c = CGPoint(x: it.x, y: it.y)
        switch it.kind {
        case .peg:
            let v = min(max(it.voice, 0), 4)
            let col = Palette.voices[v]
            let muted = s.mute[v]
            if it.glow > 0.01 { glow(&g, c, CGFloat(24 + it.glow * 26), col, 0.35 + it.glow * 0.65) }
            let poly = polygon(c, CGFloat(13 + it.glow * 3), voiceSides[v], voiceRot[v])
            g.fill(poly, with: .color(it.glow > 0.05 ? col.opacity(0.25 + it.glow * 0.6) : Palette.panel))
            g.stroke(poly, with: .color(muted ? Palette.bone.opacity(0.25) : col), lineWidth: 2)
            if it.chance < 1 {
                var ring = Path(); ring.addArc(center: c, radius: 19.5, startAngle: .degrees(-90),
                                               endAngle: .degrees(-90 + 360 * it.chance), clockwise: false)
                g.stroke(ring, with: .color(col.opacity(0.85)), lineWidth: 2.5)
            }
            if it.ratchet > 1 {
                for k in 0..<it.ratchet {
                    let x = c.x + (CGFloat(k) - CGFloat(it.ratchet - 1) / 2) * 7
                    g.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: c.y + 21.8, width: 4.4, height: 4.4)), with: .color(col))
                }
            }
            if model.selectedID == it.id {
                g.stroke(Path(ellipseIn: CGRect(x: c.x - 27, y: c.y - 27, width: 54, height: 54)), with: .color(.white),
                         style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        case .bumper:
            if it.glow > 0.01 { glow(&g, c, CGFloat(34 + it.glow * 20), Palette.blood, it.glow) }
            let ring = Path(ellipseIn: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))
            g.fill(ring, with: .color(Color(red: 0.09, green: 0.035, blue: 0.05)))
            g.stroke(ring, with: .color(Color(red: 0.75, green: 0.13, blue: 0.23)), lineWidth: 2.5)
            g.stroke(Path(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)), with: .color(Palette.blood.opacity(0.55)), lineWidth: 1)
        case .well:
            glow(&g, c, 70, Palette.void_, 0.38)
            var spiral = Path()
            let rot = snap.tick * 0.7
            var a = 0.0
            while a < 2 * Double.pi * 2.4 {
                let rr = 3 + a * 3.2
                let pt = CGPoint(x: c.x + CGFloat(cos(a + rot) * rr), y: c.y + CGFloat(sin(a + rot) * rr))
                if a == 0 { spiral.move(to: pt) } else { spiral.addLine(to: pt) }
                a += 0.18
            }
            g.stroke(spiral, with: .color(Palette.void_), lineWidth: 1.6)
            g.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(.white))
            g.stroke(Path(ellipseIn: CGRect(x: c.x - 150, y: c.y - 150, width: 300, height: 300)), with: .color(Palette.void_.opacity(0.07)), lineWidth: 1)
        case .spawner:
            let ca = CGFloat(cos(it.angle)), sa = CGFloat(sin(it.angle))
            if it.glow > 0.01 { glow(&g, c, CGFloat(34 + it.glow * 18), Palette.bone, it.glow * 0.8) }
            let body = Path(ellipseIn: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30))
            g.fill(body, with: .color(Palette.panel))
            g.stroke(body, with: .color(Palette.bone), lineWidth: 1.6)
            var arrow = Path()
            arrow.move(to: CGPoint(x: c.x + ca * 8, y: c.y + sa * 8))
            arrow.addLine(to: CGPoint(x: c.x + ca * 30, y: c.y + sa * 30))
            g.stroke(arrow, with: .color(Palette.bone), lineWidth: 2)
            let ax = c.x + ca * 30, ay = c.y + sa * 30
            var head = Path()
            head.move(to: CGPoint(x: ax + ca * 7, y: ay + sa * 7))
            head.addLine(to: CGPoint(x: ax - sa * 5, y: ay + ca * 5))
            head.addLine(to: CGPoint(x: ax + sa * 5, y: ay - ca * 5))
            head.closeSubpath()
            g.fill(head, with: .color(Palette.bone))
            if snap.running {
                let ph = (snap.tick / Double(it.div)).truncatingRemainder(dividingBy: 1)
                var arc = Path(); arc.addArc(center: c, radius: 19, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * ph), clockwise: false)
                g.stroke(arc, with: .color(Palette.ember), lineWidth: 2)
            }
            var label = divNames[it.div] ?? ""
            if it.chance < 1 { label += " · \(Int(it.chance * 100))%" }
            g.draw(Text(label).font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.bone.opacity(0.75)),
                   at: CGPoint(x: c.x, y: c.y + (sa > 0.3 ? -30 : 32)), anchor: .center)
            if model.selectedID == it.id {
                g.stroke(Path(ellipseIn: CGRect(x: c.x - 29, y: c.y - 29, width: 58, height: 58)), with: .color(.white),
                         style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
    }

    // orbs
    for o in snap.orbs {
        let c = CGPoint(x: o.x, y: o.y)
        let col = o.voice >= 0 ? Palette.voices[min(o.voice, 4)] : Palette.bone
        let f = o.life > 100_000_000 ? 1.0 : min(max(Double(o.life) / Double(max(o.maxLife, 1)), 0.15), 1)
        var tail = Path()
        tail.move(to: c)
        tail.addLine(to: CGPoint(x: c.x - CGFloat(o.vx) * 0.035, y: c.y - CGFloat(o.vy) * 0.035))
        g.stroke(tail, with: .color(col.opacity(0.55 * f)), lineWidth: 4)
        glow(&g, c, 17, col, 0.55 * f + 0.2)
        g.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(Color(red: 1, green: 0.97, blue: 0.92)))
    }

    // aim line
    if let a = model.aimStart, let b = model.aimEnd {
        var line = Path(); line.move(to: a); line.addLine(to: b)
        let launch = model.tool == .launch
        g.stroke(line, with: .color(launch ? Palette.bone.opacity(0.5) : Palette.ember), style: StrokeStyle(lineWidth: launch ? 1.5 : 2, dash: launch ? [4, 5] : []))
        if launch {
            let dx = Double(a.x - b.x), dy = Double(a.y - b.y), len = hypot(dx, dy)
            if len > 14 {
                let sp = min(900, len * 3.4), vx = dx / len * sp, vy = dy / len * sp, gr = model.settings.gravity * 900
                for i in 1...16 {
                    let t = Double(i) * 0.055
                    let px = Double(a.x) + vx * t, py = Double(a.y) + vy * t + 0.5 * gr * t * t
                    if px < 0 || px > Arena.width || py < 0 || py > Arena.height { break }
                    let rr = CGFloat(2.2 - Double(i) * 0.07)
                    g.fill(Path(ellipseIn: CGRect(x: px - Double(rr), y: py - Double(rr), width: Double(rr) * 2, height: Double(rr) * 2)),
                           with: .color(Palette.bone.opacity(0.5)))
                }
            }
        }
    }

    if !snap.running {
        g.draw(Text("stopped — start the host transport (or the internal clock)").font(.system(size: 14, design: .monospaced))
                .foregroundColor(Palette.bone.opacity(0.4)), at: CGPoint(x: W / 2, y: cell * 1.5), anchor: .center)
    }
}

struct ArenaView: View {
    @ObservedObject var model: ArcadeModel

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / CGFloat(Arena.width)
            TimelineView(.animation) { _ in
                Canvas { gc, size in
                    let snap = model.host.edit { $0.makeSnapshot() }
                    drawArena(gc, size: size, snap: snap, model: model)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { model.dragChanged($0, scale: scale) }
                    .onEnded { model.dragEnded($0, scale: scale) }
            )
        }
        .aspectRatio(CGFloat(Arena.width / Arena.height), contentMode: .fit)
        .overlay(Rectangle().stroke(Palette.line, lineWidth: 1))
    }
}

// MARK: - Controls

private struct SmallLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, design: .monospaced)).kerning(1.4).foregroundColor(Palette.ash)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

private struct PillButton: View {
    let title: String
    var on = false
    var tint: Color = Palette.ember
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .kerning(0.8)
                .foregroundColor(on ? Color.black : Palette.bone)
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(on ? tint : Palette.panel)
                .overlay(Rectangle().stroke(on ? tint : Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct SliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { SmallLabel(title); Spacer(); Text(valueText).font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.bone) }
            Slider(value: $value, in: range).accentColor(Palette.ember)
        }
        .frame(minWidth: 150)
    }
}

struct ArcadeView: View {
    @ObservedObject var model: ArcadeModel

    private func quantLabel(_ q: Int) -> String { [1: "1/16 grid", 2: "1/8 grid", 4: "1/4 grid", 0: "Off (raw)"][q] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ArenaView(model: model)   // pinned: dragging on the arena never scrolls
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    toolsRow
                    voicesRow
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {   // wide windows: two columns
                            VStack(alignment: .leading, spacing: 10) { harmonyControls; behaviorControls }.frame(minWidth: 400)
                            VStack(alignment: .leading, spacing: 10) { feelControls; physicsControls }.frame(minWidth: 300)
                        }
                        VStack(alignment: .leading, spacing: 14) {   // narrow windows: one column
                            harmonyControls; behaviorControls; feelControls; physicsControls
                        }
                    }
                    scenesRow
                    routingRow
                    Text("MIDI out: Chug ch 1 (power chords), Lead ch 2, Bass ch 3, Bell ch 4, Drums ch 10 by default. Route this plugin's MIDI to your synths in the host.")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.ash)
                }
            }
        }
        .padding(12)
        .background(Palette.bg)
        .tint(Palette.ember)
        .accentColor(Palette.ember)
        .preferredColorScheme(.dark)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Text("Abyssal Arcade").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundColor(Palette.bone)
            Text("MIDI").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(Palette.ember)
            Spacer()
            ForEach(Array(model.chordNames.enumerated()), id: \.offset) { item in
                Text(item.element).font(.system(size: 12, design: .monospaced)).foregroundColor(Palette.bone)
                    .padding(.horizontal, 8).padding(.vertical, 5).overlay(Rectangle().stroke(Palette.line, lineWidth: 1))
            }
        }
    }

    private var toolsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("Tool")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Tool.allCases, id: \.self) { t in
                        PillButton(title: t.rawValue, on: model.tool == t) { model.tool = t }
                    }
                    Spacer().frame(width: 10)
                    PillButton(title: model.frozen ? "Frozen" : "Freeze", on: model.frozen, tint: Color.cyan) { model.toggleFreeze() }
                    PillButton(title: "Flush orbs") { model.flushOrbs() }
                    PillButton(title: "Clear") { model.clearArena() }
                    PillButton(title: "Conjure") { model.conjure() }
                }
            }
        }
    }

    private var voicesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("Voice")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Voice.allCases, id: \.self) { v in
                        let col = Palette.voices[v.rawValue]
                        HStack(spacing: 0) {
                            Button { model.voice = v } label: {
                                HStack(spacing: 6) {
                                    Rectangle().fill(col).frame(width: 9, height: 9)
                                    Text(v.name.uppercased()).font(.system(size: 12, design: .monospaced))
                                }
                                .foregroundColor(model.settings.mute[v.rawValue] ? Palette.bone.opacity(0.35) : Palette.bone)
                                .padding(.horizontal, 12).frame(minHeight: 40)
                            }.buttonStyle(.plain)
                            Button { model.settings.mute[v.rawValue].toggle() } label: {
                                Text(model.settings.mute[v.rawValue] ? "MUTED" : "M")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(model.settings.mute[v.rawValue] ? Palette.blood : Palette.ash)
                                    .padding(.horizontal, 9).frame(minHeight: 40)
                            }.buttonStyle(.plain)
                        }
                        .background(Palette.panel)
                        .overlay(Rectangle().stroke(model.voice == v ? col : Palette.line, lineWidth: model.voice == v ? 2 : 1))
                    }
                }
            }
        }
    }

    private var harmonyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallLabel("Harmony")
            HStack {
                Picker("Key", selection: $model.settings.key) {
                    ForEach(0..<12, id: \.self) { Text(Music.noteNames[$0]).tag($0) }
                }
                Picker("Mode", selection: $model.settings.scale) {
                    ForEach(0..<Music.scales.count, id: \.self) { Text(Music.scales[$0].name).tag($0) }
                }
            }.pickerStyle(.menu)
            HStack {
                Picker("Progression", selection: $model.settings.prog) {
                    ForEach(0..<Music.progressions.count, id: \.self) { Text(model.progressionName($0)).tag($0) }
                }
                Picker("Bars", selection: $model.settings.barsPerChord) {
                    ForEach([1, 2, 4], id: \.self) { Text("\($0) bar\($0 > 1 ? "s" : "")").tag($0) }
                }
            }.pickerStyle(.menu)
            if model.settings.prog == Music.customIndex { customEditor }
            HStack {
                Picker("Quantize", selection: $model.settings.quant) {
                    ForEach([1, 2, 4, 0], id: \.self) { Text(quantLabel($0)).tag($0) }
                }.pickerStyle(.menu)
                Picker("Sync", selection: $model.settings.internalClock) {
                    Text("Host tempo").tag(false)
                    Text("Internal clock").tag(true)
                }.pickerStyle(.menu)
            }
            if model.settings.internalClock {
                HStack(spacing: 10) {
                    PillButton(title: model.internalRunning ? "Stop" : "Play", on: model.internalRunning) { model.toggleInternalRun() }
                    SliderRow(title: "Tempo", valueText: "\(Int(model.settings.bpm)) bpm",
                              value: $model.settings.bpm, range: 60...220)
                }
            }
            Toggle(isOn: $model.settings.powerChord) {
                Text("Chug sends power chords (root + 5th + octave)").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.bone)
            }.toggleStyle(SwitchToggleStyle(tint: Palette.ember))
        }
    }

    /// Eight slots of chord roots, in semitones from the tonic. "End" stops the list at that slot.
    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("Custom progression · chord roots in semitones from the tonic")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 70), spacing: 6), count: 4), spacing: 6) {
                ForEach(0..<Music.maxCustomChords, id: \.self) { i in
                    Picker("Chord \(i + 1)", selection: Binding(get: { model.customValue(i) }, set: { model.setCustomValue(i, $0) })) {
                        if i > 0 { Text("— end").tag(99) }
                        ForEach(-12...12, id: \.self) { st in
                            Text("\(st > 0 ? "+" : "")\(st) · \(Music.intervalName(st))").tag(st)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .background(Palette.panel)
                    .overlay(Rectangle().stroke(i < model.customList.count ? Palette.ember.opacity(0.6) : Palette.line, lineWidth: 1))
                    .opacity(i <= model.customList.count ? 1 : 0.4)
                }
            }
        }
    }

    private var behaviorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallLabel(model.selectedID != nil ? (model.selIsSpawner ? "Editing spawner" : "Editing peg") : "Behavior · new pegs")
            SliderRow(title: "Chance", valueText: "\(Int(model.chanceValue * 100))%",
                      value: Binding(get: { model.chanceValue }, set: { model.setChance(($0 * 20).rounded() / 20) }), range: 0.05...1)
            HStack(spacing: 6) {
                SmallLabel("Ratchet")
                ForEach(1...4, id: \.self) { k in
                    PillButton(title: "×\(k)", on: !model.selIsSpawner && model.ratchetValue == k) { model.setRatchet(k) }
                        .opacity(model.selIsSpawner ? 0.35 : 1)
                }
                if model.selectedID != nil { PillButton(title: "Done") { model.selectedID = nil } }
            }
        }
    }

    private var feelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallLabel("Feel")
            SliderRow(title: "Swing", valueText: model.settings.swing <= 0.505 ? "straight" : "\(Int((model.settings.swing * 100).rounded()))%",
                      value: $model.settings.swing, range: 0.5...0.75)
            SliderRow(title: "Humanize", valueText: "\(Int(model.settings.humanize * 100))%", value: $model.settings.humanize, range: 0...1)
        }
    }

    private var physicsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallLabel("Physics")
            SliderRow(title: "Gravity", valueText: "\(model.settings.gravity > 0 ? "↓" : model.settings.gravity < 0 ? "↑" : "")\(Int(abs(model.settings.gravity) * 100))",
                      value: $model.settings.gravity, range: -1...1)
            SliderRow(title: "Orb speed", valueText: "\(Int(model.settings.orbSpeed))", value: $model.settings.orbSpeed, range: 120...720)
            SliderRow(title: "Orb life", valueText: model.settings.orbLife > 40 ? "∞" : "\(model.settings.orbLife)",
                      value: Binding(get: { Double(model.settings.orbLife) }, set: { model.settings.orbLife = Int($0.rounded()) }), range: 2...41)
        }
    }

    private var scenesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("Scenes · tap to recall on the next bar · empty slot saves")
            HStack(spacing: 6) {
                ForEach(0..<8, id: \.self) { i in
                    let filled = model.sceneFilled[i]
                    let active = model.activeScene == i
                    let pend = model.pendingScene == i
                    Button { model.sceneTapped(i) } label: {
                        Text("\(i + 1)").font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(active ? Color.black : (filled ? Palette.bone : Palette.ash))
                            .frame(width: 48, height: 48)
                            .background(active ? Palette.ember : (filled ? Palette.panel : Color.clear))
                            .overlay(Rectangle().stroke(pend ? Color.yellow : (model.storeMode ? Color.yellow.opacity(0.6) : (filled ? Palette.ember.opacity(0.5) : Palette.line)),
                                                        style: StrokeStyle(lineWidth: pend ? 2 : 1, dash: filled ? [] : [3, 3])))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Save current arena here") { model.host.edit { $0.saveScene(i) }; model.refresh() }
                        if filled { Button("Clear scene", role: .destructive) { model.clearScene(i) } }
                    }
                }
                PillButton(title: "Store to…", on: model.storeMode, tint: Color.yellow) { model.storeMode.toggle() }
            }
        }
    }

    private var routingRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("MIDI channel per voice")
            HStack(spacing: 14) {
                ForEach(Voice.allCases, id: \.self) { v in
                    HStack(spacing: 4) {
                        Rectangle().fill(Palette.voices[v.rawValue]).frame(width: 8, height: 8)
                        Picker(v.name, selection: Binding(get: { model.settings.channel[v.rawValue] },
                                                          set: { model.settings.channel[v.rawValue] = $0 })) {
                            ForEach(0..<16, id: \.self) { Text("\(v.name) · ch \($0 + 1)").tag($0) }
                        }.pickerStyle(.menu)
                    }
                }
            }
        }
    }
}
