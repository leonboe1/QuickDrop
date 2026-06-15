//
//  DeviceListCell.swift
//  ShareExtension
//
//  Created by Grishka on 20.09.2023.
//

import Cocoa

class DeviceListCell: NSCollectionViewItem {
    public var clickHandler: (() -> Void)?
    @IBOutlet private var peerMarkerView: NSImageView?

    override func viewDidLoad() {
        super.viewDidLoad()
        let btn: NSButton = view as! NSButton
        btn.isEnabled = true
        btn.setButtonType(.momentaryPushIn)
        btn.action = #selector(onClick)
        btn.target = self

        addClickRecognizer(to: view)
        addClickRecognizer(to: textField)
        addClickRecognizer(to: imageView)
        addClickRecognizer(to: peerMarkerView)

        peerMarkerView?.image = NSImage(named: "MenuBarIcon")
        peerMarkerView?.image?.isTemplate = true
        peerMarkerView?.contentTintColor = .white
    }

    @IBAction func onClick(_: Any?) {
        guard let handler = clickHandler else { return }
        handler()
    }

    func configure(deviceName: String, deviceImage: NSImage, showsQuickDropPeerMarker: Bool) {
        textField?.stringValue = deviceName
        imageView?.image = deviceImage
        peerMarkerView?.isHidden = !showsQuickDropPeerMarker
    }

    private func addClickRecognizer(to targetView: NSView?) {
        guard let targetView else { return }

        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(onClick(_:)))
        recognizer.buttonMask = 0x1
        targetView.addGestureRecognizer(recognizer)
    }
}
