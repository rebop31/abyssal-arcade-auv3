// The container app. iOS only shows an AUv3 plugin once the app that contains it is installed, so this app
// is deliberately small: it explains how to use the plugin. The plugin itself is the "AbyssalArcadeAU" extension.
import SwiftUI

@main
struct AbyssalArcadeApp: App {
    var body: some Scene {
        WindowGroup { InfoView() }
    }
}

struct InfoView: View {
    private let steps = [
        "Open a host that supports AUv3 MIDI plugins (AUM, AudioBus, Loopy Pro and similar).",
        "Add \"Abyssal Arcade MIDI\" as a MIDI plugin (it appears under MIDI processors / generators).",
        "Route its MIDI output to your synths. Defaults: Chug ch 1, Lead ch 2, Bass ch 3, Bell ch 4, Drums ch 10.",
        "Press play in the host. Orbs launch on the beat and every collision becomes a note locked to the host tempo.",
        "Use the plugin's Sync menu to switch to its own clock if your host does not send tempo.",
    ]

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.03, blue: 0.035).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Abyssal Arcade").font(.system(size: 40, weight: .semibold, design: .serif))
                        .foregroundColor(Color(red: 0.91, green: 0.86, blue: 0.78))
                    Text("MIDI generator plugin (AUv3)").font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.353, blue: 0.122))
                    Text("This app only installs the plugin. Open it from inside your music host.")
                        .foregroundColor(Color(red: 0.75, green: 0.7, blue: 0.65))
                    ForEach(Array(steps.enumerated()), id: \.offset) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(item.offset + 1)").font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(red: 1.0, green: 0.353, blue: 0.122))
                            Text(item.element).foregroundColor(Color(red: 0.91, green: 0.86, blue: 0.78))
                        }
                    }
                }
                .padding(28)
            }
        }
        .preferredColorScheme(.dark)
    }
}
