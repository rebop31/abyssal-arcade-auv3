// AudioUnitViewController.swift
// The AUv3 extension's entry point: creates the audio unit and shows the SwiftUI interface.
import CoreAudioKit
import SwiftUI
import UIKit

public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: ArcadeAudioUnit?
    private var hosting: UIHostingController<ArcadeView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.03, blue: 0.035, alpha: 1)
        preferredContentSize = CGSize(width: 900, height: 640)
        connectIfReady()
    }

    /// Called by the host. May arrive before or after viewDidLoad, and not necessarily on the main thread.
    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try ArcadeAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = unit
        DispatchQueue.main.async { [weak self] in self?.connectIfReady() }
        return unit
    }

    private func connectIfReady() {
        guard hosting == nil, isViewLoaded, let unit = audioUnit else { return }
        let model = ArcadeModel(au: unit)
        let controller = UIHostingController(rootView: ArcadeView(model: model))
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .clear
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        hosting = controller
    }
}
