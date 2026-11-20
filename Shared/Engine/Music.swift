// Music.swift: scales, progressions, voices and pitch maths shared by the engine and the UI.
import Foundation

public enum Arena {
    public static let cols = 30
    public static let rows = 16
    public static let cell = 40.0
    public static let width = 1200.0
    public static let height = 640.0
    public static func x(_ c: Int) -> Double { Double(c) * cell + cell / 2 }
    public static func y(_ r: Int) -> Double { Double(rows - 1 - r) * cell + cell / 2 }
    public static func col(_ x: Double) -> Int { min(max(Int(floor(x / cell)), 0), cols - 1) }
    public static func row(_ y: Double) -> Int { min(max(rows - 1 - Int(floor(y / cell)), 0), rows - 1) }
}

public struct Scale {
    public let name: String
    public let steps: [Int]
}

public struct Progression {
    public let name: String
    /// Scale-degree offsets applied to every peg, one per chord slot.
    public let degrees: [Int]
    /// Chromatic root move in semitones added on top of the degree offset, one per chord slot (all zeros = stays in key).
    public let semitones: [Int]

    public init(name: String, degrees: [Int], semitones: [Int]? = nil) {
        self.name = name
        self.degrees = degrees
        self.semitones = semitones ?? [Int](repeating: 0, count: degrees.count)
    }
}

public enum Music {
    public static let noteNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// The first 10 are the core scales; the next 31 are extra modes and scales (indices are stable, only ever appended).
    public static let scales: [Scale] = [
        Scale(name: "Dorian", steps: [0, 2, 3, 5, 7, 9, 10]),
        Scale(name: "Phrygian", steps: [0, 1, 3, 5, 7, 8, 10]),
        Scale(name: "Aeolian (natural minor)", steps: [0, 2, 3, 5, 7, 8, 10]),
        Scale(name: "Locrian", steps: [0, 1, 3, 5, 6, 8, 10]),
        Scale(name: "Phrygian dominant", steps: [0, 1, 4, 5, 7, 8, 10]),
        Scale(name: "Harmonic minor", steps: [0, 2, 3, 5, 7, 8, 11]),
        Scale(name: "Hungarian minor", steps: [0, 2, 3, 6, 7, 8, 11]),
        Scale(name: "Mixolydian", steps: [0, 2, 4, 5, 7, 9, 10]),
        Scale(name: "Minor pentatonic", steps: [0, 3, 5, 7, 10]),
        Scale(name: "Blues", steps: [0, 3, 5, 6, 7, 10]),
        Scale(name: "Ionian (major)", steps: [0, 2, 4, 5, 7, 9, 11]),
        Scale(name: "Lydian", steps: [0, 2, 4, 6, 7, 9, 11]),
        Scale(name: "Melodic minor", steps: [0, 2, 3, 5, 7, 9, 11]),
        Scale(name: "Dorian ♭2", steps: [0, 1, 3, 5, 7, 9, 10]),
        Scale(name: "Lydian augmented", steps: [0, 2, 4, 6, 8, 9, 11]),
        Scale(name: "Lydian dominant", steps: [0, 2, 4, 6, 7, 9, 10]),
        Scale(name: "Mixolydian ♭6", steps: [0, 2, 4, 5, 7, 8, 10]),
        Scale(name: "Locrian ♮2", steps: [0, 2, 3, 5, 6, 8, 10]),
        Scale(name: "Altered (super Locrian)", steps: [0, 1, 3, 4, 6, 8, 10]),
        Scale(name: "Harmonic major", steps: [0, 2, 4, 5, 7, 8, 11]),
        Scale(name: "Double harmonic (Byzantine)", steps: [0, 1, 4, 5, 7, 8, 11]),
        Scale(name: "Neapolitan minor", steps: [0, 1, 3, 5, 7, 8, 11]),
        Scale(name: "Neapolitan major", steps: [0, 1, 3, 5, 7, 9, 11]),
        Scale(name: "Ukrainian Dorian", steps: [0, 2, 3, 6, 7, 9, 10]),
        Scale(name: "Lydian ♯2", steps: [0, 3, 4, 6, 7, 9, 11]),
        Scale(name: "Ionian ♯5", steps: [0, 2, 4, 5, 8, 9, 11]),
        Scale(name: "Locrian ♮6", steps: [0, 1, 3, 5, 6, 9, 10]),
        Scale(name: "Ultra Locrian", steps: [0, 1, 3, 4, 6, 8, 9]),
        Scale(name: "Enigmatic", steps: [0, 1, 4, 6, 8, 10, 11]),
        Scale(name: "Persian", steps: [0, 1, 4, 5, 6, 8, 11]),
        Scale(name: "Hungarian major", steps: [0, 3, 4, 6, 7, 9, 10]),
        Scale(name: "Todi (raga)", steps: [0, 1, 3, 6, 7, 8, 11]),
        Scale(name: "Marva (raga)", steps: [0, 1, 4, 6, 7, 9, 11]),
        Scale(name: "Purvi (raga)", steps: [0, 1, 4, 6, 7, 8, 11]),
        Scale(name: "Whole tone", steps: [0, 2, 4, 6, 8, 10]),
        Scale(name: "Diminished (whole-half)", steps: [0, 2, 3, 5, 6, 8, 9, 11]),
        Scale(name: "Diminished (half-whole)", steps: [0, 1, 3, 4, 6, 7, 9, 10]),
        Scale(name: "Augmented (hexatonic)", steps: [0, 3, 4, 7, 8, 11]),
        Scale(name: "Prometheus", steps: [0, 2, 4, 6, 9, 10]),
        Scale(name: "Hirajoshi", steps: [0, 2, 3, 7, 8]),
        Scale(name: "Major pentatonic", steps: [0, 2, 4, 7, 9]),
    ]

    public static let progressions: [Progression] = [
        Progression(name: "Vamp  1 > 7", degrees: [0, -1]),
        Progression(name: "Static  1", degrees: [0]),
        Progression(name: "Descent  1 > 7 > 6 > 5", degrees: [0, -1, -2, -3]),
        Progression(name: "Dread  1 > 7 > 4 > 7", degrees: [0, -1, 3, -1]),
        Progression(name: "Abyss  1 > 3 > 4 > 7", degrees: [0, 2, 3, -1]),
        Progression(name: "Pedal  1 > 1 > 7 > 4", degrees: [0, 0, -1, 3]),
        Progression(name: "Lament  1 > 6 > 7 > 1", degrees: [0, -2, -1, 0]),
        Progression(name: "Dirge  1 > 6 > 7 > 5", degrees: [0, -2, -1, -3]),
        Progression(name: "Plague  1 > 1 > 1 > 7", degrees: [0, 0, 0, -1]),
        Progression(name: "Crypt  1 > 5 > 6 > 7", degrees: [0, -3, -2, -1]),
        Progression(name: "Gallows  1 > 4 > 7 > 6", degrees: [0, 3, -1, -2]),
        Progression(name: "Siege  1 > 1 > 4 > 4 > 7 > 7 > 1 > 1", degrees: [0, 0, 3, 3, -1, -1, 0, 0]),
        Progression(name: "Tomb  1 > 6 > 1 > 7", degrees: [0, -2, 0, -1]),
        Progression(name: "Ritual  1 > 3 > 1 > 4", degrees: [0, 2, 0, 3]),
        Progression(name: "Ember  1 > 5 > 4 > 5", degrees: [0, 4, 3, 4]),
        Progression(name: "Funeral  1 > 7 > 6 > 7", degrees: [0, -1, -2, -1]),
        Progression(name: "Hollow  1 > 6 > 4 > 5", degrees: [0, -2, -4, -3]),
        Progression(name: "Requiem  1 > 7 > 5 > 6", degrees: [0, -1, -3, -2]),
        Progression(name: "Ascent of the damned  1 > 2 > 3 > 4", degrees: [0, 1, 2, 3]),
        Progression(name: "Spire  1 > 3 > 5 > 7", degrees: [0, 2, 4, 6]),
        Progression(name: "Falling thirds  1 > 6 > 4 > 2", degrees: [0, -2, -4, -6]),
        Progression(name: "Black mass  1 > 2 > 1 > 7", degrees: [0, 1, 0, -1]),
        Progression(name: "Rot  1 > 1 > 2 > 2", degrees: [0, 0, 1, 1]),
        Progression(name: "Tolling  1 > 4 > 1 > 5", degrees: [0, 3, 0, 4]),
        Progression(name: "Cathedral  1 > 5 > 6 > 4", degrees: [0, 4, 5, 3]),
        Progression(name: "Pendulum  1 > 7 > 1 > 2", degrees: [0, -1, 0, 1]),
        Progression(name: "Warpath  1 > 1 > 7 > 7 > 6 > 6 > 7 > 7", degrees: [0, 0, -1, -1, -2, -2, -1, -1]),
        Progression(name: "Inferno  1 > 3 > 2 > 4", degrees: [0, 2, 1, 3]),
        Progression(name: "Carrion  1 > 4 > 6 > 7", degrees: [0, -4, -2, -1]),
        Progression(name: "Eclipse  1 > 2 > 7 > 1", degrees: [0, 1, -1, 0]),
        Progression(name: "Wraith  1 > 4 > 3 > 2", degrees: [0, 3, 2, 1]),
        Progression(name: "Altar  1 > 1 > 1 > 1 > 7 > 7 > 4 > 4", degrees: [0, 0, 0, 0, -1, -1, 3, 3]),
        Progression(name: "Abyssal stair  1 > 6 > 5 > 4", degrees: [0, -2, -3, -4]),
        Progression(name: "Mirror  1 > 3 > 5 > 3", degrees: [0, 2, 4, 2]),
        Progression(name: "Thorns  1 > 2 > 4 > 2", degrees: [0, 1, 3, 1]),
        Progression(name: "Vigil  1 > 7 > 7 > 1 > 3 > 3 > 7 > 7", degrees: [0, -1, -1, 0, 2, 2, -1, -1]),
        Progression(name: "Oblivion  1 > 7 > 6 > 5 > 4 > 3 > 2", degrees: [0, -1, -2, -3, -4, -5, -6]),
        Progression(name: "Chromatic climb  1 > ♭2 > 2 > ♭3", degrees: [0, 0, 0, 0], semitones: [0, 1, 2, 3]),
        Progression(name: "Chromatic fall  1 > 7↓ > ♭7↓ > 6↓", degrees: [0, 0, 0, 0], semitones: [0, -1, -2, -3]),
        Progression(name: "Semitone grind  1 > ♭2 > 1 > 7↓", degrees: [0, 0, 0, 0], semitones: [0, 1, 0, -1]),
        Progression(name: "Tritone stab  1 > ♯4", degrees: [0, 0], semitones: [0, 6]),
        Progression(name: "Devil's staircase  1 > ♯4 > 1 > 4", degrees: [0, 0, 0, 0], semitones: [0, 6, 0, 5]),
        Progression(name: "Neapolitan slam  1 > ♭2 > 1 > 1", degrees: [0, 0, 0, 0], semitones: [0, 1, 0, 0]),
        Progression(name: "Diminished roots  1 > ♭3 > ♯4 > 6", degrees: [0, 0, 0, 0], semitones: [0, 3, 6, 9]),
        Progression(name: "Whole-tone slide  1 > 2 > 3 > ♯4", degrees: [0, 0, 0, 0], semitones: [0, 2, 4, 6]),
        Progression(name: "Augmented roots  1 > 3 > ♭6", degrees: [0, 0, 0], semitones: [0, 4, 8]),
        Progression(name: "Mediant swing  1 > 3 > 1 > ♭6", degrees: [0, 0, 0, 0], semitones: [0, 4, 0, 8]),
        Progression(name: "Tritone & fifth  1 > ♯4 > 5 > ♯4", degrees: [0, 0, 0, 0], semitones: [0, 6, 7, 6]),
        Progression(name: "Semitone dread  1 > ♭2 > ♯4 > ♭2", degrees: [0, 0, 0, 0], semitones: [0, 1, 6, 1]),
        Progression(name: "Chromatic ladder  1 > ♭2 > 2 > ♭2 > 1 > 7↓ > ♭7↓ > 7↓", degrees: [0, 0, 0, 0, 0, 0, 0, 0], semitones: [0, 1, 2, 1, 0, -1, -2, -1]),
        Progression(name: "Phrygian crawl  1 > ♭2 > ♭3 > ♭2", degrees: [0, 0, 0, 0], semitones: [0, 1, 3, 1]),
        Progression(name: "Rising tritones  1 > ♯4 > ♭2 > 5 > 2 > ♭6", degrees: [0, 0, 0, 0, 0, 0], semitones: [0, 6, 1, 7, 2, 8]),
        Progression(name: "Octave plunge  1 > 1↓ > 1 > 1↓", degrees: [0, 0, 0, 0], semitones: [0, -12, 0, -12]),
        // Slot 53: "Custom". Its chords come from Settings.customProgression, not from this placeholder.
        Progression(name: "Custom", degrees: [0], semitones: [0]),
    ]

    /// Index of the user-editable "Custom" progression (always the last entry).
    public static var customIndex: Int { progressions.count - 1 }
    public static let defaultCustom = [0, 6, 7, 6]
    public static let maxCustomChords = 8
    public static let intervalNames = ["1", "b2", "2", "b3", "3", "4", "#4", "5", "b6", "6", "b7", "7"]

    /// Interval of a root move above the tonic, e.g. 6 -> "#4", -5 -> "5v", 12 -> "1^".
    public static func intervalName(_ semitones: Int) -> String {
        intervalNames[mod(semitones, 12)] + (semitones < 0 ? "v" : semitones >= 12 ? "^" : "")
    }

    /// General-MIDI drum note for each of the 16 rows (kick low, hats high).
    public static let drumNotes: [UInt8] = [36, 36, 35, 38, 38, 37, 45, 47, 50, 42, 42, 46, 46, 51, 49, 52]
    public static let drumNames = ["Kick", "Kick", "Kick 2", "Snare", "Snare", "Rim", "Tom lo", "Tom mid", "Tom hi",
                                   "Hat", "Hat", "Hat open", "Hat open", "Ride", "Crash", "China"]

    @inline(__always) public static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }
    @inline(__always) public static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }

    public static func degreeSemitones(_ scale: Scale, _ degree: Int) -> Int {
        let n = scale.steps.count
        return floorDiv(degree, n) * 12 + scale.steps[mod(degree, n)]
    }

    public static func baseMidi(key: Int) -> Int { key >= 7 ? 24 + key : 36 + key }

    public static func noteName(key: Int, scale: Scale, degree: Int) -> String {
        noteNames[mod(baseMidi(key: key) + degreeSemitones(scale, degree), 12)]
    }

    /// Name of the chord built on the given degree offset (triads for seven-note scales, plain root otherwise).
    public static func chordName(key: Int, scale: Scale, offset: Int, semitones: Int = 0) -> String {
        let root = noteNames[mod(baseMidi(key: key) + degreeSemitones(scale, offset) + semitones, 12)]
        guard scale.steps.count == 7 else { return root }
        let t = degreeSemitones(scale, offset + 2) - degreeSemitones(scale, offset)
        let f = degreeSemitones(scale, offset + 4) - degreeSemitones(scale, offset)
        if t == 3 { return root + (f == 6 ? "dim" : f == 8 ? "m#5" : "m") }
        if t == 4 { return root + (f == 8 ? "+" : "") }
        return root + "sus"
    }
}

public enum Voice: Int, CaseIterable, Codable {
    case chug, lead, bass, bell, drums

    public var name: String { ["Chug", "Lead", "Bass", "Bell", "Drums"][rawValue] }
    /// Octave shift in semitones relative to row 0 (D2 in the default key).
    public var octave: Int { [0, 12, -12, 24, 0][rawValue] }
    /// Default note length in 16th-note ticks.
    public var noteTicks: Double { [1, 3, 2, 6, 0.5][rawValue] }
    public static let defaultChannels = [0, 1, 2, 3, 9]
}
