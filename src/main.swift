import Cocoa
import CoreAudio

// MARK: - CoreAudio Volume
//
// 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
// Using the raw four-char-code so we don't need to import AudioToolbox.
private let kVirtualMainVolSel: AudioObjectPropertySelector = 0x766D7663

private func defaultOutputDevice() -> AudioDeviceID {
    var id   = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &addr, 0, nil, &size, &id)
    return id
}

/// Returns 0 when the system is muted (F10 / menu-bar mute button).
func getVolume() -> Int {
    let dev = defaultOutputDevice()

    // Mute state
    var muted    = UInt32(0)
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    if AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &muteSize, &muted) == noErr,
       muted != 0 { return 0 }

    // Volume scalar (0.0 – 1.0)
    var vol     = Float32(0)
    var volSize = UInt32(MemoryLayout<Float32>.size)
    var volAddr = AudioObjectPropertyAddress(
        mSelector: kVirtualMainVolSel,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(dev, &volAddr, 0, nil, &volSize, &vol) == noErr
    else { return 50 }
    return Int((vol * 100).rounded())
}

func setVolume(_ volume: Int) {
    let dev  = defaultOutputDevice()
    var vol  = Float32(max(0, min(100, volume))) / 100
    let size = UInt32(MemoryLayout<Float32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kVirtualMainVolSel,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol)
}

func isMuted() -> Bool {
    let dev = defaultOutputDevice()

    var muted    = UInt32(0)
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    return AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &muteSize, &muted) == noErr && muted != 0
}

func setMuted(_ muted: Bool) {
    let dev = defaultOutputDevice()
    var mutedValue = UInt32(muted ? 1 : 0)
    let size = UInt32(MemoryLayout<UInt32>.size)
    var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, size, &mutedValue)
}

func symbolName(for volume: Int) -> String {
    switch volume {
    case 0:       return "speaker.slash.fill"
    case 1...33:  return "speaker.fill"
    case 34...66: return "speaker.wave.1.fill"
    default:      return "speaker.wave.3.fill"
    }
}

// MARK: - Custom Status Bar View

class VolumeBarView: NSView {
    var onScroll: ((Int, Bool) -> Void)?
    var onLeftClick: ((NSEvent) -> Void)?
    var onResize: ((CGFloat) -> Void)?

    private let iconView = NSImageView()
    private let label: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return tf
    }()

    private var trackpadAccumulator: CGFloat = 0
    private let iconPt: CGFloat = 13
    private let gap: CGFloat    = 3
    private let hPad: CGFloat   = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        addSubview(label)
    }
    required init?(coder: NSCoder) { nil }

    func update(volume: Int) {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconPt, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName(for: volume),
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        label.stringValue = "\(volume)%"
        label.sizeToFit()

        let w = ceil(hPad + iconPt + gap + label.frame.width + hPad)
        onResize?(w)
        layoutContent()
    }

    private func layoutContent() {
        let midY = bounds.midY
        iconView.frame = NSRect(x: hPad, y: midY - iconPt/2, width: iconPt, height: iconPt)
        label.frame    = NSRect(x: hPad + iconPt + gap,
                                y: midY - label.frame.height/2,
                                width: label.frame.width, height: label.frame.height)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [] else { return }
        if event.hasPreciseScrollingDeltas {
            trackpadAccumulator += event.scrollingDeltaY
            let steps = Int(trackpadAccumulator / 4)
            guard steps != 0 else { return }
            trackpadAccumulator -= CGFloat(steps) * 4
            // invert scroll direction
            onScroll?(steps * -1, true)
        } else {
            let d = event.deltaY
            if d > 0.5       { onScroll?( 1, false) }
            else if d < -0.5 { onScroll?(-1, false) }
        }
    }

    override func mouseDown(with event: NSEvent) { onLeftClick?(event) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var barView: VolumeBarView!
    private let step = 5
    private let sensitivityValues = [22, 33, 44]
    private let defaultStepsReducer = 33
    private var stepsReducer = 33
    private weak var sensitivityLabelItem: NSMenuItem?

    /// Optimistic cache — updated instantly on scroll so the UI never waits for a read.
    private var cachedVolume = 50
    /// Coalesces rapid CoreAudio notifications (e.g. smooth slider drags).
    private var pendingRefresh: DispatchWorkItem?
    /// Tracks which device we're already listening to, to avoid duplicate listeners.
    private var observedDeviceID: AudioDeviceID = 0

    @objc private func stepsReducerChanged(_ sender: NSSlider) {
        let index = max(0, min(sensitivityValues.count - 1, sender.integerValue - 1))
        stepsReducer = sensitivityValues[index]
        sensitivityLabelItem?.title = "Scroll Sensitivity"
    }

    @objc private func resetStepsReducer() {
        stepsReducer = defaultStepsReducer
        sensitivityLabelItem?.title = "Scroll Sensitivity"
    }

    private func sensitivityIndex(for value: Int) -> Int {
        max(0, sensitivityValues.firstIndex(of: value) ?? 1)
    }

    @objc private func toggleMute() {
        let muted = isMuted()
        setMuted(!muted)
        cachedVolume = getVolume()
        barView.update(volume: cachedVolume)
    }

    private func showLeftMenu(with event: NSEvent) {
        let menu = NSMenu()
        let current = NSMenuItem(title: "Current Volume: \(cachedVolume)%",
                                 action: #selector(toggleMute), keyEquivalent: "")
        current.target = self
        menu.addItem(current)
        menu.addItem(.separator())

        let sensitivityLabel = NSMenuItem(title: "Scroll Sensitivity",
                                          action: nil,
                                          keyEquivalent: "")
        sensitivityLabel.isEnabled = false
        menu.addItem(sensitivityLabel)
        sensitivityLabelItem = sensitivityLabel

        let slider = NSSlider(value: Double(sensitivityIndex(for: stepsReducer) + 1),
                      minValue: 1,
                      maxValue: 3,
                      target: self,
                      action: #selector(stepsReducerChanged(_:)))
        slider.isEnabled = true
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.numberOfTickMarks = sensitivityValues.count
        slider.allowsTickMarkValuesOnly = true
        slider.integerValue = sensitivityIndex(for: stepsReducer) + 1

        let sliderContainer = NSView(frame: NSRect(x: 0, y: 0, width: 196, height: 42))

        let hint = NSTextField(labelWithString: "Drag to adjust")
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 24, width: 164, height: 12)
        sliderContainer.addSubview(hint)

        slider.frame = NSRect(x: 16, y: 4, width: 170, height: 24)
        sliderContainer.addSubview(slider)

        let sliderItem = NSMenuItem()
        sliderItem.view = sliderContainer
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit VolumeScroll",
                              action: #selector(self.quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.popUpMenu(menu)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let barH = NSStatusBar.system.thickness
        statusItem = NSStatusBar.system.statusItem(withLength: 60)
        barView    = VolumeBarView(frame: NSRect(x: 0, y: 0, width: 60, height: barH))

        // Scroll: optimistic update — display changes before the next read.
        barView.onScroll = { [weak self] steps, isTouchPad in
            guard let self else { return }
            var newVol = self.cachedVolume

            if (isTouchPad) {
                newVol = max(0, min(100, self.cachedVolume + ((steps * self.step) * self.stepsReducer / 100)))
            } else {
                newVol = max(0, min(100, self.cachedVolume + steps * self.step))
            }

            self.cachedVolume = newVol
            setVolume(newVol)
            self.barView.update(volume: newVol)
        }

        barView.onLeftClick = { [weak self] event in
            self?.showLeftMenu(with: event)
        }

        barView.onResize = { [weak self] w in
            guard let self else { return }
            self.statusItem.length       = w
            self.barView.frame.size.width = w
        }

        statusItem.view = barView   // deprecated but the only way to capture scroll events

        setupAudioObservers()
        hardRefresh()
    }

    // MARK: - CoreAudio Observers

    private func setupAudioObservers() {
        // 1. Watch for default-output-device changes (headphone plug/unplug, AirPlay switch…)
        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &sysAddr, .main
        ) { [weak self] _, _ in
            self?.reregisterDeviceListeners()
            self?.scheduleRefresh()
        }

        reregisterDeviceListeners()
    }

    /// Attaches volume + mute listeners to the current default output device.
    /// Safe to call multiple times — skips if the device hasn't changed.
    private func reregisterDeviceListeners() {
        var id   = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr,
              id != 0, id != observedDeviceID
        else { return }
        observedDeviceID = id

        // Volume changes (F11/F12, system slider, other apps)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kVirtualMainVolSel,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(id, &volAddr, .main) { [weak self] _, _ in
            self?.scheduleRefresh()
        }

        // Mute toggle (F10, Control Center mute button)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(id, &muteAddr, .main) { [weak self] _, _ in
            self?.scheduleRefresh()
        }
    }

    // MARK: - Refresh

    /// Debounced: coalesces a burst of CoreAudio notifications into one UI update.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hardRefresh() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// Reads the real volume from CoreAudio and syncs the display + cache.
    private func hardRefresh() {
        cachedVolume = getVolume()
        barView.update(volume: cachedVolume)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry Point

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
