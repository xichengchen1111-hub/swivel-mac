import AppKit

/// The tools in the Swivel bundle. Each one can be switched on or off on its own.
enum Feature: String, CaseIterable {
    case wheel, clothesline, textCapture, shelf, imagePresets, quickActions
    case batchRename, pdfPages, qrCodes, appRouting, keepAwake
    case doctor

    var title: String {
        switch self {
        case .wheel: L("Wheel")
        case .clothesline: L("Clothesline")
        case .textCapture: L("Text Capture")
        case .shelf: L("File Shelf")
        case .imagePresets: L("Image Presets")
        case .quickActions: L("Quick Actions")
        case .batchRename: L("Batch Rename")
        case .pdfPages: L("PDF Pages")
        case .qrCodes: L("QR & Barcodes")
        case .appRouting: L("App Actions")
        case .keepAwake: L("Keep Awake")
        case .doctor: L("Mac Doctor")
        }
    }

    var symbol: String {
        switch self {
        case .wheel: "circle.circle"
        case .clothesline: "tshirt"
        case .textCapture: "text.viewfinder"
        case .shelf: "tray.full"
        case .imagePresets: "slider.horizontal.3"
        case .quickActions: "command.square"
        case .batchRename: "character.cursor.ibeam"
        case .pdfPages: "doc.on.doc"
        case .qrCodes: "qrcode.viewfinder"
        case .appRouting: "arrow.up.forward.app"
        case .keepAwake: "cup.and.saucer"
        case .doctor: "stethoscope"
        }
    }

    var blurb: String {
        switch self {
        case .wheel: L("Drag a file and tap a key: a menu pops up to convert it, edit it or send it somewhere.")
        case .clothesline: L("Screenshots hang on a rope under the menu bar instead of piling up on the desktop.")
        case .textCapture: L("Turn text in an image into editable, copyable text. Everything stays on your Mac.")
        case .shelf: L("Gather files from different places, then drag a selection out together.")
        case .imagePresets: L("Save your favourite image sizes, formats and privacy settings for next time.")
        case .quickActions: L("Find an action from the keyboard, even when the menu bar is crowded.")
        case .batchRename: L("Preview and rename a batch of files, with conflict checks and undo.")
        case .pdfPages: L("Pick, reorder, rotate and export PDF pages without changing the originals.")
        case .qrCodes: L("Read QR codes and barcodes from selected images, entirely on your Mac.")
        case .appRouting: L("Open files in your chosen apps, or prepare a Codex or Claude Code draft.")
        case .keepAwake: L("Stop your Mac from going to sleep for a while: during a long copy, a download or a presentation.")
        case .doctor: L("Find out why your Mac is full, slow or won’t open an app. It only reads, and fixes nothing without asking.")
        }
    }

    @MainActor var isOn: Bool {
        get {
            switch self {
            case .wheel: Prefs.isEnabled
            case .clothesline: Prefs.clotheslineEnabled
            default: Prefs.featureEnabled(self)
            }
        }
        nonmutating set {
            switch self {
            case .wheel: Prefs.isEnabled = newValue
            case .clothesline: Clothesline.shared.setEnabled(newValue)
            default:
                Prefs.setFeatureEnabled(self, newValue)
                if !newValue {
                    switch self {
                    case .shelf: Shelf.shared.hide()
                    case .textCapture: TextCaptureWindow.closeAll()
                    case .quickActions: QuickActions.shared.hide()
                    case .keepAwake: KeepAwake.shared.stop()
                    default: break
                    }
                }
            }
        }
    }
}
