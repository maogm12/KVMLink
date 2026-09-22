import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import ServiceManagement

@_silgen_name("KVMLinkSetLGInput")
private func KVMLinkSetLGInput(_ displayUUID: UnsafePointer<CChar>, _ inputValue: UInt16) -> Int32

// MARK: - Private display bridge

private typealias ConfigureDisplayEnabledFunction = @convention(c) (
    CGDisplayConfigRef,
    CGDirectDisplayID,
    Bool
) -> CGError

private typealias GetDisplayListFunction = @convention(c) (
    UInt32,
    UnsafeMutablePointer<CGDirectDisplayID>?,
    UnsafeMutablePointer<UInt32>
) -> CGError

private struct DisplayRecord: Hashable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let isBuiltin: Bool
    let isOnline: Bool
    let width: Int
    let height: Int
    let disabledByThisApp: Bool
}

private enum DisplayControlError: LocalizedError {
    case privateAPIUnavailable
    case displayNotFound(String)
    case builtinNotAllowed
    case beginConfiguration(CGError)
    case configure(CGError)
    case commit(CGError)

    var errorDescription: String? {
        switch self {
        case .privateAPIUnavailable:
            return "当前 macOS 没有可用的显示器断开接口。"
        case .displayNotFound(let uuid):
            return "没有找到绑定的显示器（\(uuid)）。"
        case .builtinNotAllowed:
            return "为安全起见，本程序不会断开 Mac 内置屏幕。"
        case .beginConfiguration(let error):
            return "无法开始显示器配置（错误 \(error.rawValue)）。"
        case .configure(let error):
            return "无法改变显示器连接状态（错误 \(error.rawValue)）。"
        case .commit(let error):
            return "无法提交显示器配置（错误 \(error.rawValue)）。"
        }
    }
}

private final class DisplayController {
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let configureFunction: ConfigureDisplayEnabledFunction?
    private let getDisplayListFunction: GetDisplayListFunction?
    private var sessionCache: [String: DisplayRecord] = [:]

    init() {
        let candidates = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        ]

        var openedHandle: UnsafeMutableRawPointer?
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                openedHandle = handle
                break
            }
        }
        frameworkHandle = openedHandle

        func load<T>(_ names: [String], as type: T.Type) -> T? {
            guard let handle = openedHandle else { return nil }
            for name in names {
                if let symbol = dlsym(handle, name) {
                    return unsafeBitCast(symbol, to: type)
                }
            }
            return nil
        }

        configureFunction = load(
            ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"],
            as: ConfigureDisplayEnabledFunction.self
        )
        getDisplayListFunction = load(
            ["SLSGetDisplayList", "CGSGetDisplayList"],
            as: GetDisplayListFunction.self
        )
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    var isAvailable: Bool {
        configureFunction != nil
    }

    func allDisplays() -> [DisplayRecord] {
        let ids = allDisplayIDs()
        let onlineIDs = Set(onlineDisplayIDs())
        let screenNames: [CGDirectDisplayID: String] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return nil
                }
                return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
            }
        )

        var records = ids.compactMap { id -> DisplayRecord? in
            guard let uuid = uuidString(for: id) else { return nil }
            let online = onlineIDs.contains(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let cachedName = UserDefaults.standard.string(forKey: "displayName.\(uuid)")
            let name = screenNames[id] ?? cachedName ?? (CGDisplayIsBuiltin(id) != 0 ? "内置屏幕" : "外接显示器")
            if online {
                UserDefaults.standard.set(name, forKey: "displayName.\(uuid)")
                UserDefaults.standard.set(Int(id), forKey: "displayID.\(uuid)")
                UserDefaults.standard.set(Int(mode?.width ?? 0), forKey: "displayWidth.\(uuid)")
                UserDefaults.standard.set(Int(mode?.height ?? 0), forKey: "displayHeight.\(uuid)")
                UserDefaults.standard.set(false, forKey: "displayDisabledByUs.\(uuid)")
            }
            let record = DisplayRecord(
                id: id,
                uuid: uuid,
                name: name,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isOnline: online,
                width: mode.map { Int($0.width) } ?? 0,
                height: mode.map { Int($0.height) } ?? 0,
                disabledByThisApp: !online && UserDefaults.standard.bool(forKey: "displayDisabledByUs.\(uuid)")
            )
            sessionCache[uuid.uppercased()] = record
            return record
        }

        // A software-disabled external display may disappear even from the
        // private full-display list. Keep its exact UUID → displayID mapping
        // for the lifetime of this process so it can always be restored.
        let listedUUIDs = Set(records.map { $0.uuid.uppercased() })
        for (uuid, cached) in sessionCache where !listedUUIDs.contains(uuid) {
            records.append(DisplayRecord(
                id: cached.id,
                uuid: cached.uuid,
                name: cached.name,
                isBuiltin: cached.isBuiltin,
                isOnline: false,
                width: cached.width,
                height: cached.height,
                disabledByThisApp: UserDefaults.standard.bool(forKey: "displayDisabledByUs.\(cached.uuid)")
            ))
        }


        // Recover an exact display that this app disabled before an unexpected
        // restart. The cached numeric ID is used only while no online display
        // has claimed it, and only when our own disabled flag is set.
        if let selectedUUID = UserDefaults.standard.string(forKey: "selectedDisplayUUID"),
           !records.contains(where: { $0.uuid.caseInsensitiveCompare(selectedUUID) == .orderedSame }),
           let cached = persistedDisabledDisplay(uuid: selectedUUID) {
            sessionCache[selectedUUID.uppercased()] = cached
            records.append(cached)
        }
        return records
    }

    func externalDisplays() -> [DisplayRecord] {
        allDisplays()
            .filter { !$0.isBuiltin }
            .sorted {
                if $0.isOnline != $1.isOnline { return $0.isOnline && !$1.isOnline }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func display(uuid: String) -> DisplayRecord? {
        let normalized = uuid.uppercased()
        if let liveOrSession = allDisplays().first(where: { $0.uuid.uppercased() == normalized }) {
            return liveOrSession
        }
        if let persisted = persistedDisabledDisplay(uuid: uuid) {
            sessionCache[normalized] = persisted
            return persisted
        }
        return nil
    }

    func setEnabled(uuid: String, enabled: Bool) throws {
        guard let configureFunction else {
            throw DisplayControlError.privateAPIUnavailable
        }
        guard let target = display(uuid: uuid) else {
            throw DisplayControlError.displayNotFound(uuid)
        }
        guard !target.isBuiltin else {
            throw DisplayControlError.builtinNotAllowed
        }

        if enabled == target.isOnline {
            if enabled {
                UserDefaults.standard.set(false, forKey: "displayDisabledByUs.\(uuid)")
            }
            return
        }

        // A numeric display ID may be recycled after a hotplug. Verify every
        // online target immediately before changing it. An offline target is
        // allowed only from this process's UUID cache and only while no online
        // display is using the same numeric ID.
        if target.isOnline {
            guard let currentUUID = uuidString(for: target.id),
                  currentUUID.caseInsensitiveCompare(uuid) == .orderedSame else {
                throw DisplayControlError.displayNotFound(uuid)
            }
        } else {
            guard enabled,
                  UserDefaults.standard.bool(forKey: "displayDisabledByUs.\(uuid)"),
                  !onlineDisplayIDs().contains(target.id) else {
                throw DisplayControlError.displayNotFound(uuid)
            }
        }

        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw DisplayControlError.beginConfiguration(beginResult)
        }

        let configureResult = configureFunction(configuration, target.id, enabled)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayControlError.configure(configureResult)
        }

        let commitResult = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard commitResult == .success else {
            throw DisplayControlError.commit(commitResult)
        }
        UserDefaults.standard.set(!enabled, forKey: "displayDisabledByUs.\(uuid)")
    }

    private func allDisplayIDs() -> [CGDirectDisplayID] {
        if let getDisplayListFunction {
            var count: UInt32 = 0
            if getDisplayListFunction(0, nil, &count) == .success, count > 0 {
                var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
                if getDisplayListFunction(count, &ids, &count) == .success {
                    return Array(ids.prefix(Int(count)))
                }
            }
        }
        return onlineDisplayIDs()
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    private func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private func persistedDisabledDisplay(uuid: String) -> DisplayRecord? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "displayDisabledByUs.\(uuid)") else { return nil }
        let idValue = defaults.integer(forKey: "displayID.\(uuid)")
        guard idValue > 0 else { return nil }
        let id = CGDirectDisplayID(idValue)
        guard !onlineDisplayIDs().contains(id) else { return nil }
        return DisplayRecord(
            id: id,
            uuid: uuid,
            name: defaults.string(forKey: "displayName.\(uuid)") ?? "已绑定显示器",
            isBuiltin: false,
            isOnline: false,
            width: defaults.integer(forKey: "displayWidth.\(uuid)"),
            height: defaults.integer(forKey: "displayHeight.\(uuid)"),
            disabledByThisApp: true
        )
    }
}

// MARK: - DDC input switching

private enum DDCControlError: LocalizedError {
    case commandFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let code):
            return "显示器没有接受 DDC 输入切换指令（错误 \(code)）。"
        }
    }
}

private final class DDCController {
    // LG uses alternate VCP input addressing: HDMI 1 = 144, HDMI 2 = 145.
    private let awayInput = 144
    private let connectedInput = 145

    func switchInput(displayUUID: String, connected: Bool) throws {
        let input = UInt16(connected ? connectedInput : awayInput)
        let result = displayUUID.withCString { KVMLinkSetLGInput($0, input) }
        guard result == 0 else {
            throw DDCControlError.commandFailed(result)
        }
    }
}

// MARK: - USB HID inventory

private enum HIDKind: String {
    case keyboard = "键盘"
    case mouse = "鼠标"
    case other = "USB 设备"
}

private struct HIDRecord: Hashable {
    let key: String
    let name: String
    let vendorID: Int
    let productID: Int
    let serial: String
    let locationID: Int
    let transport: String
    let kind: HIDKind

    var detail: String {
        let serialPart = serial.isEmpty ? String(format: "位置 %08X", locationID) : "序列号 \(serial)"
        return String(format: "%@ · VID %04X / PID %04X · %@", kind.rawValue, vendorID, productID, serialPart)
    }
}

private final class HIDInventory {
    func devices() -> [HIDRecord] {
        // IOHIDManagerCopyDevices can retain the manager's initial snapshot.
        // Create a fresh read-only manager for every poll so a hardware USB
        // switch is reflected immediately, without opening devices or reading
        // any keyboard/mouse events (and therefore without Input Monitoring).
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let rawSet = IOHIDManagerCopyDevices(manager) else { return [] }
        let deviceSet = rawSet as NSSet
        var recordsByKey: [String: HIDRecord] = [:]

        for case let device as IOHIDDevice in deviceSet {
            let vendorID = integerProperty(device, kIOHIDVendorIDKey)
            let productID = integerProperty(device, kIOHIDProductIDKey)
            guard vendorID > 0, productID > 0 else { continue }

            let transport = stringProperty(device, kIOHIDTransportKey)
            guard transport.caseInsensitiveCompare("USB") == .orderedSame else { continue }

            let usagePage = integerProperty(device, kIOHIDPrimaryUsagePageKey)
            let usage = integerProperty(device, kIOHIDPrimaryUsageKey)
            let kind: HIDKind
            if usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard {
                kind = .keyboard
            } else if usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Mouse {
                kind = .mouse
            } else {
                kind = .other
            }

            let serial = stringProperty(device, kIOHIDSerialNumberKey)
            let locationID = integerProperty(device, kIOHIDLocationIDKey)
            let name = stringProperty(device, kIOHIDProductKey).isEmpty
                ? String(format: "USB %04X:%04X", vendorID, productID)
                : stringProperty(device, kIOHIDProductKey)
            let identityPart = serial.isEmpty ? "location:\(locationID)" : "serial:\(serial)"
            let key = String(format: "%04X:%04X:%@", vendorID, productID, identityPart)
            let record = HIDRecord(
                key: key,
                name: name,
                vendorID: vendorID,
                productID: productID,
                serial: serial,
                locationID: locationID,
                transport: transport,
                kind: kind
            )

            if let existing = recordsByKey[key] {
                // One physical USB device may expose several HID collections.
                // Keep the most useful classification for the row icon.
                let rank: [HIDKind: Int] = [.other: 0, .keyboard: 1, .mouse: 2]
                if (rank[kind] ?? 0) > (rank[existing.kind] ?? 0) { recordsByKey[key] = record }
            } else {
                recordsByKey[key] = record
            }
        }

        let sortRank: [HIDKind: Int] = [.mouse: 0, .keyboard: 1, .other: 2]
        return recordsByKey.values.sorted {
            if $0.kind != $1.kind { return (sortRank[$0.kind] ?? 3) < (sortRank[$1.kind] ?? 3) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func integerProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String {
        IOHIDDeviceGetProperty(device, key as CFString) as? String ?? ""
    }
}

// MARK: - Persistent configuration

private enum DisplayControlMode: String {
    case stopOutput
    case ddcInputSwitch
}

private enum AppLanguage: String {
    case chinese
    case english

    func text(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }
}

private final class LinkConfiguration {
    private let defaults = UserDefaults.standard

    var selectedUSBKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: "selectedUSBKeys") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "selectedUSBKeys") }
    }

    var usbLabels: [String: String] {
        get { defaults.dictionary(forKey: "usbLabels") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "usbLabels") }
    }

    var displayUUID: String? {
        get { defaults.string(forKey: "selectedDisplayUUID") }
        set { defaults.set(newValue, forKey: "selectedDisplayUUID") }
    }

    var displayName: String? {
        get { defaults.string(forKey: "selectedDisplayName") }
        set { defaults.set(newValue, forKey: "selectedDisplayName") }
    }

    var automationEnabled: Bool {
        get { defaults.object(forKey: "automationEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "automationEnabled") }
    }

    var controlMode: DisplayControlMode {
        get {
            guard let rawValue = defaults.string(forKey: "displayControlMode") else { return .stopOutput }
            return DisplayControlMode(rawValue: rawValue) ?? .stopOutput
        }
        set { defaults.set(newValue.rawValue, forKey: "displayControlMode") }
    }

    var interfaceLanguage: AppLanguage {
        get {
            guard let rawValue = defaults.string(forKey: "interfaceLanguage") else { return .chinese }
            return AppLanguage(rawValue: rawValue) ?? .chinese
        }
        set { defaults.set(newValue.rawValue, forKey: "interfaceLanguage") }
    }

    var hasCompletedInitialSetup: Bool {
        get { defaults.bool(forKey: "hasCompletedInitialSetup") }
        set { defaults.set(newValue, forKey: "hasCompletedInitialSetup") }
    }
}

// MARK: - Custom popover UI

private struct LinkUISnapshot {
    let devices: [HIDRecord]
    let selectedUSBKeys: Set<String>
    let usbLabels: [String: String]
    let displays: [DisplayRecord]
    let selectedDisplayUUID: String?
    let automationEnabled: Bool
    let controlMode: DisplayControlMode
    let language: AppLanguage
    let loginEnabled: Bool
    let status: String
}

private final class StatusDotView: NSView {
    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private final class StatusPillView: NSView {
    private let label: NSTextField

    init(text: String, foreground: NSColor, background: NSColor) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

private final class CircularLinkButton: NSButton {
    var isLinked = false { didSet { needsDisplay = true } }
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        let accent = NSColor.controlAccentColor
        let foreground = isLinked ? accent : NSColor.secondaryLabelColor
        let alpha: CGFloat = isHighlighted ? 0.22 : (isHovered ? 0.18 : 0.13)
        (isLinked ? accent : NSColor.secondaryLabelColor).withAlphaComponent(alpha).setFill()
        circle.fill()

        foreground.withAlphaComponent(isHovered ? 0.34 : 0.20).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            .applying(.init(paletteColors: [foreground]))
        if let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            symbol.draw(in: NSRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24))
        }
    }
}

private final class LinkConnectorView: NSView {
    var onToggle: (() -> Void)?
    var onForceSync: (() -> Void)?
    private let linked: Bool

    init(snapshot: LinkUISnapshot) {
        linked = snapshot.automationEnabled
        super.init(frame: .zero)

        let liveKeys = Set(snapshot.devices.map(\.key))
        let devicePresent = !snapshot.selectedUSBKeys.intersection(liveKeys).isEmpty
        let statusText: String
        if !snapshot.automationEnabled {
            statusText = snapshot.language.text("已停止联动", "Linking stopped")
        } else if devicePresent {
            statusText = snapshot.language.text("设备已连接，屏幕输出中", "Device connected, display active")
        } else {
            statusText = snapshot.language.text("设备已断开，屏幕已切断", "Device disconnected, display stopped")
        }

        let linkButton = CircularLinkButton()
        linkButton.isBordered = false
        linkButton.isLinked = linked
        linkButton.target = self
        linkButton.action = #selector(linkPressed(_:))
        linkButton.toolTip = linked
            ? snapshot.language.text(
                "点击停止联动并恢复屏幕；按住 Option 点击可立即同步。",
                "Click to stop linking and restore the display. Option-click to sync now."
            )
            : snapshot.language.text(
                "点击开启联动并按当前设备状态同步。",
                "Click to start linking and sync to the current device state."
            )
        linkButton.translatesAutoresizingMaskIntoConstraints = false
        linkButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
        linkButton.heightAnchor.constraint(equalToConstant: 50).isActive = true

        let status = NSTextField(labelWithString: statusText)
        status.font = .systemFont(ofSize: 11.5, weight: .medium)
        status.textColor = linked ? .secondaryLabelColor : .tertiaryLabelColor
        status.alignment = .center

        let stack = NSStackView(views: [linkButton, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func linkPressed(_ sender: NSButton) {
        if linked, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            onForceSync?()
        } else {
            onToggle?()
        }
    }
}

private final class LinkPopoverViewController: NSViewController {
    var snapshotProvider: (() -> LinkUISnapshot)?
    var onToggleAutomation: (() -> Void)?
    var onToggleUSB: ((String) -> Void)?
    var onSelectDisplay: ((String) -> Void)?
    var onSelectControlMode: ((DisplayControlMode) -> Void)?
    var onSelectLanguage: ((AppLanguage) -> Void)?
    var onSync: (() -> Void)?
    var onToggleLogin: (() -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        let background = NSVisualEffectView(frame: .zero)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        view = background
        preferredContentSize = NSSize(width: 420, height: 1)
    }

    func refresh() {
        if !isViewLoaded { loadView() }
        guard let snapshot = snapshotProvider?() else { return }
        view.subviews.forEach { $0.removeFromSuperview() }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -14)
        ])

        let deviceCard = makeDeviceCard(snapshot)
        addFullWidth(deviceCard, to: root)

        let connector = LinkConnectorView(snapshot: snapshot)
        connector.onToggle = { [weak self] in self?.onToggleAutomation?(); self?.refresh() }
        connector.onForceSync = { [weak self] in self?.onSync?(); self?.refresh() }
        addFullWidth(connector, to: root)

        let displayCard = makeDisplayCard(snapshot)
        addFullWidth(displayCard, to: root)

        let controlCard = makeControlModeCard(snapshot)
        addFullWidth(controlCard, to: root)

        let footer = makeFooter(snapshot)
        addFullWidth(footer, to: root)

        view.layoutSubtreeIfNeeded()
        let measuredHeight = ceil(root.fittingSize.height + 30)
        preferredContentSize = NSSize(width: 420, height: min(measuredHeight, 680))
    }

    func renderPNG(to url: URL) throws {
        refresh()
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "USBDisplayLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 UI 预览图"])
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "USBDisplayLink", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法编码 UI 预览图"])
        }
        try data.write(to: url)
    }

    private func makeDeviceCard(_ snapshot: LinkUISnapshot) -> NSView {
        let card = makeCard()
        let stack = cardStack(in: card)
        addFullWidth(makeSectionHeader(
            title: snapshot.language.text("鼠标/键盘", "Mouse / Keyboard"),
            subtitle: snapshot.language.text("选择要监控的设备", "Select a device to monitor")
        ), to: stack)

        let liveKeys = Set(snapshot.devices.map(\.key))
        if snapshot.devices.isEmpty && snapshot.selectedUSBKeys.isEmpty {
            stack.addArrangedSubview(makeEmptyLabel(snapshot.language.text(
                "没有检测到 USB 鼠标或键盘",
                "No USB input devices detected"
            )))
        }
        for device in snapshot.devices {
            addFullWidth(makeDeviceRow(
                key: device.key,
                name: device.name,
                kind: device.kind,
                selected: snapshot.selectedUSBKeys.contains(device.key),
                connected: true,
                toolTip: device.detail,
                language: snapshot.language
            ), to: stack)
        }
        for key in snapshot.selectedUSBKeys.subtracting(liveKeys).sorted() {
            let savedName = snapshot.usbLabels[key] ?? key
            let kind: HIDKind = savedName.contains("鼠标") ? .mouse : (savedName.contains("键盘") ? .keyboard : .other)
            let cleanName = savedName
                .replacingOccurrences(of: "（鼠标）", with: "")
                .replacingOccurrences(of: "（键盘）", with: "")
                .replacingOccurrences(of: "（USB 设备）", with: "")
            addFullWidth(makeDeviceRow(
                key: key,
                name: cleanName,
                kind: kind,
                selected: true,
                connected: false,
                toolTip: snapshot.language.text("当前未连接", "Currently disconnected"),
                language: snapshot.language
            ), to: stack)
        }
        return card
    }

    private func makeDeviceRow(
        key: String,
        name: String,
        kind: HIDKind,
        selected: Bool,
        connected: Bool,
        toolTip: String,
        language: AppLanguage
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let selector = NSButton(radioButtonWithTitle: "", target: self, action: #selector(devicePressed(_:)))
        selector.identifier = NSUserInterfaceItemIdentifier(key)
        selector.state = selected ? .on : .off
        selector.toolTip = toolTip
        selector.translatesAutoresizingMaskIntoConstraints = false
        selector.widthAnchor.constraint(equalToConstant: 18).isActive = true
        selector.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(selector)

        let symbol = kind == .mouse ? "computermouse" : (kind == .keyboard ? "keyboard" : "cable.connector")
        row.addArrangedSubview(makeSymbol(symbol, color: .secondaryLabelColor, size: 17))
        let label = makeLabel(name, size: 12.5, weight: selected ? .medium : .regular, color: .labelColor)
        label.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(label)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(makeStatusIndicator(
            text: connected
                ? language.text("已连接", "Connected")
                : language.text("未连接", "Disconnected"),
            color: connected ? .controlAccentColor : .tertiaryLabelColor
        ))
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        return row
    }

    private func makeDisplayCard(_ snapshot: LinkUISnapshot) -> NSView {
        let card = makeCard()
        let stack = cardStack(in: card)
        let pill = StatusPillView(
            text: snapshot.automationEnabled
                ? snapshot.language.text("联动中", "Linked")
                : snapshot.language.text("停止联动", "Stopped"),
            foreground: snapshot.automationEnabled ? .controlAccentColor : .secondaryLabelColor,
            background: (snapshot.automationEnabled ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).withAlphaComponent(0.12)
        )
        addFullWidth(makeSectionHeader(
            title: snapshot.language.text("外接屏幕", "External Display"),
            subtitle: snapshot.language.text("选择要绑定的屏幕", "Select a display to bind"),
            trailing: pill
        ), to: stack)

        let liveKeys = Set(snapshot.devices.map(\.key))
        let devicePresent = !snapshot.selectedUSBKeys.intersection(liveKeys).isEmpty
        if snapshot.displays.isEmpty {
            stack.addArrangedSubview(makeEmptyLabel(snapshot.language.text(
                "没有检测到外接显示器",
                "No external display detected"
            )))
        }
        for display in snapshot.displays {
            let selected = snapshot.selectedDisplayUUID?.caseInsensitiveCompare(display.uuid) == .orderedSame
            let stateText: String
            let stateColor: NSColor
            if display.disabledByThisApp || (selected && snapshot.automationEnabled && !devicePresent) {
                stateText = snapshot.language.text("已切断", "Stopped")
                stateColor = .systemRed
            } else if display.isOnline {
                stateText = snapshot.language.text("输出中", "Active")
                stateColor = .controlAccentColor
            } else {
                stateText = snapshot.language.text("未连接", "Disconnected")
                stateColor = .tertiaryLabelColor
            }
            addFullWidth(makeDisplayRow(
                display: display,
                selected: selected,
                status: stateText,
                statusColor: stateColor,
                language: snapshot.language
            ), to: stack)
        }
        return card
    }

    private func makeDisplayRow(
        display: DisplayRecord,
        selected: Bool,
        status: String,
        statusColor: NSColor,
        language: AppLanguage
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let icon = NSButton(
            image: NSImage(
                systemSymbolName: "display",
                accessibilityDescription: language.text("屏幕", "Display")
            ) ?? NSImage(),
            target: self,
            action: #selector(displayPressed(_:))
        )
        icon.identifier = NSUserInterfaceItemIdentifier(display.uuid)
        icon.isBordered = false
        icon.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(icon)

        var title = display.name
        if display.width > 0 && display.height > 0 { title += "  ·  \(display.width)×\(display.height)" }
        let name = NSButton(title: title, target: self, action: #selector(displayPressed(_:)))
        name.identifier = NSUserInterfaceItemIdentifier(display.uuid)
        name.isBordered = false
        name.alignment = .left
        name.font = .systemFont(ofSize: 12.5, weight: selected ? .medium : .regular)
        name.contentTintColor = .labelColor
        row.addArrangedSubview(name)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(makeStatusIndicator(text: status, color: statusColor))
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 27).isActive = true
        return row
    }

    private func makeControlModeCard(_ snapshot: LinkUISnapshot) -> NSView {
        let card = makeCard()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -13),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11)
        ])
        row.addArrangedSubview(makeLabel(
            snapshot.language.text("控制方式", "Control Method"),
            size: 12,
            weight: .semibold,
            color: .labelColor
        ))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        let control = NSSegmentedControl(
            labels: [
                snapshot.language.text("停止输出", "Stop Output"),
                snapshot.language.text("DDC 输入切换", "DDC Input Switch")
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(controlModePressed(_:))
        )
        control.selectedSegment = snapshot.controlMode == .stopOutput ? 0 : 1
        control.controlSize = .small
        control.setWidth(snapshot.language == .chinese ? 92 : 102, forSegment: 0)
        control.setWidth(snapshot.language == .chinese ? 118 : 126, forSegment: 1)
        row.addArrangedSubview(control)
        return card
    }

    private func makeFooter(_ snapshot: LinkUISnapshot) -> NSView {
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        let login = NSButton(
            checkboxWithTitle: snapshot.language.text("登录时启动", "Launch at Login"),
            target: self,
            action: #selector(loginPressed(_:))
        )
        login.state = snapshot.loginEnabled ? .on : .off
        login.font = .systemFont(ofSize: 13, weight: .medium)
        footer.addArrangedSubview(login)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)

        let language = NSPopUpButton(frame: .zero, pullsDown: false)
        language.addItems(withTitles: ["中文", "English"])
        language.selectItem(at: snapshot.language == .chinese ? 0 : 1)
        language.target = self
        language.action = #selector(languagePressed(_:))
        language.controlSize = .small
        language.toolTip = snapshot.language.text("语言", "Language")
        let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: language.toolTip)
        language.itemArray.forEach { $0.image = globe }
        footer.addArrangedSubview(language)

        let exitDescription = snapshot.language.text("退出", "Quit")
        let exitImage = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: exitDescription)
            ?? NSImage(systemSymbolName: "door.right.hand.open", accessibilityDescription: exitDescription)
            ?? NSImage(systemSymbolName: "power", accessibilityDescription: exitDescription)
            ?? NSImage()
        let quit = NSButton(image: exitImage, target: self, action: #selector(quitPressed(_:)))
        quit.isBordered = false
        quit.contentTintColor = .systemRed
        quit.toolTip = snapshot.language.text("恢复显示器并退出", "Restore display and quit")
        quit.translatesAutoresizingMaskIntoConstraints = false
        quit.widthAnchor.constraint(equalToConstant: 26).isActive = true
        quit.heightAnchor.constraint(equalToConstant: 26).isActive = true
        footer.addArrangedSubview(quit)
        return footer
    }

    private func makeSectionHeader(title: String, subtitle: String, trailing: NSView? = nil) -> NSView {
        let titles = NSStackView()
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        titles.addArrangedSubview(makeLabel(title, size: 14, weight: .semibold, color: .labelColor))
        titles.addArrangedSubview(makeLabel(subtitle, size: 11, weight: .regular, color: .secondaryLabelColor))

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.addArrangedSubview(titles)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        if let trailing { row.addArrangedSubview(trailing) }
        return row
    }

    private func makeStatusIndicator(text: String, color: NSColor) -> NSView {
        let dot = StatusDotView()
        dot.color = color
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let label = makeLabel(text, size: 11.5, weight: .regular, color: color)
        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func makeSymbol(_ symbol: String, color: NSColor, size: CGFloat) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil)
        imageView.contentTintColor = color
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: size).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: size).isActive = true
        return imageView
    }

    private func makeCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        return card
    }

    private func cardStack(in card: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13)
        ])
        return stack
    }

    private func addFullWidth(_ child: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeEmptyLabel(_ text: String) -> NSTextField {
        makeLabel(text, size: 11.5, weight: .regular, color: .tertiaryLabelColor)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    @objc private func devicePressed(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        onToggleUSB?(key)
        refresh()
    }

    @objc private func displayPressed(_ sender: NSButton) {
        guard let uuid = sender.identifier?.rawValue else { return }
        onSelectDisplay?(uuid)
        refresh()
    }

    @objc private func controlModePressed(_ sender: NSSegmentedControl) {
        onSelectControlMode?(sender.selectedSegment == 0 ? .stopOutput : .ddcInputSwitch)
        refresh()
    }

    @objc private func languagePressed(_ sender: NSPopUpButton) {
        onSelectLanguage?(sender.indexOfSelectedItem == 0 ? .chinese : .english)
        refresh()
    }

    @objc private func loginPressed(_ sender: NSButton) { onToggleLogin?(); refresh() }
    @objc private func quitPressed(_ sender: NSButton) { onQuit?() }
}

// MARK: - Menu bar application

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let displayController = DisplayController()
    private let ddcController = DDCController()
    private let hidInventory = HIDInventory()
    private let configuration = LinkConfiguration()
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var popover: NSPopover!
    private var popoverController: LinkPopoverViewController!
    private var timer: Timer?
    private var pendingSync: DispatchWorkItem?
    private var lastObservedUSBPresent: Bool?
    private var lastObservedPresentCount: Int?
    private var isChangingDisplay = false
    private var lastStatus = "正在启动…"
    private var recentEvents: [String] = []
    private var suppressAutomationUntil = Date.distantPast
    private var resignActiveObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "link", accessibilityDescription: "KVMLink")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "KVMLink"
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        performInitialSetupIfNeeded()
        normalizeSingleDeviceSelection()
        configurePopover()
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.popover.performClose(nil)
            }
        }
        rebuildMenu()
        record("应用已启动")

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.poll(force: true)
        }

        if CommandLine.arguments.contains("--preview-ui") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.togglePopover(nil)
            }
        }

        if let renderIndex = CommandLine.arguments.firstIndex(of: "--render-ui"),
           CommandLine.arguments.indices.contains(renderIndex + 1) {
            let outputPath = CommandLine.arguments[renderIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                do {
                    try self?.popoverController.renderPNG(to: URL(fileURLWithPath: outputPath))
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        pendingSync?.cancel()
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        if let uuid = configuration.displayUUID {
            if configuration.controlMode == .stopOutput {
                try? displayController.setEnabled(uuid: uuid, enabled: true)
            } else {
                try? ddcController.switchInput(displayUUID: uuid, connected: true)
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func configurePopover() {
        popoverController = LinkPopoverViewController()
        popoverController.snapshotProvider = { [weak self] in
            guard let self else {
                return LinkUISnapshot(
                    devices: [], selectedUSBKeys: [], usbLabels: [:], displays: [],
                    selectedDisplayUUID: nil, automationEnabled: false,
                    controlMode: .stopOutput,
                    language: .chinese,
                    loginEnabled: false, status: "应用正在关闭"
                )
            }
            let loginEnabled: Bool
            if #available(macOS 13.0, *) {
                loginEnabled = SMAppService.mainApp.status == .enabled
            } else {
                loginEnabled = false
            }
            return LinkUISnapshot(
                devices: self.hidInventory.devices(),
                selectedUSBKeys: self.configuration.selectedUSBKeys,
                usbLabels: self.configuration.usbLabels,
                displays: self.displayController.externalDisplays(),
                selectedDisplayUUID: self.configuration.displayUUID,
                automationEnabled: self.configuration.automationEnabled,
                controlMode: self.configuration.controlMode,
                language: self.configuration.interfaceLanguage,
                loginEnabled: loginEnabled,
                status: self.lastStatus
            )
        }
        popoverController.onToggleAutomation = { [weak self] in
            self?.toggleAutomation(NSMenuItem())
        }
        popoverController.onToggleUSB = { [weak self] key in
            let item = NSMenuItem()
            item.representedObject = key
            self?.toggleUSBDevice(item)
        }
        popoverController.onSelectDisplay = { [weak self] uuid in
            let item = NSMenuItem()
            item.representedObject = uuid
            self?.selectDisplay(item)
        }
        popoverController.onSelectControlMode = { [weak self] mode in
            self?.selectControlMode(mode)
        }
        popoverController.onSelectLanguage = { [weak self] language in
            self?.selectLanguage(language)
        }
        popoverController.onSync = { [weak self] in
            self?.syncNow(NSMenuItem())
        }
        popoverController.onToggleLogin = { [weak self] in
            self?.toggleLoginItem(NSMenuItem())
        }
        popoverController.onQuit = { [weak self] in
            self?.quit(NSMenuItem())
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = popoverController
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popoverController.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func performInitialSetupIfNeeded() {
        guard !configuration.hasCompletedInitialSetup else { return }
        defer { configuration.hasCompletedInitialSetup = true }

        let displays = displayController.externalDisplays().filter(\.isOnline)
        if displays.count == 1, let display = displays.first {
            configuration.displayUUID = display.uuid
            configuration.displayName = display.name
        }

        let devices = hidInventory.devices()
        let mice = devices.filter { $0.kind == .mouse }
        let keyboards = devices.filter { $0.kind == .keyboard }
        if mice.count == 1, let mouse = mice.first {
            configuration.selectedUSBKeys.insert(mouse.key)
        }
        if keyboards.count == 1, let keyboard = keyboards.first {
            configuration.selectedUSBKeys.insert(keyboard.key)
        }

        var labels = configuration.usbLabels
        for device in devices where configuration.selectedUSBKeys.contains(device.key) {
            labels[device.key] = "\(device.name)（\(device.kind.rawValue)）"
        }
        configuration.usbLabels = labels

        configuration.automationEnabled = configuration.displayUUID != nil && !configuration.selectedUSBKeys.isEmpty
    }

    private func normalizeSingleDeviceSelection() {
        let selected = configuration.selectedUSBKeys
        guard selected.count > 1 else { return }
        let devices = hidInventory.devices()
        let preferredKey = devices.first(where: { selected.contains($0.key) })?.key
            ?? selected.sorted().first
        if let preferredKey {
            configuration.selectedUSBKeys = [preferredKey]
            record("监控设备已调整为单选")
        }
    }

    private func poll(force: Bool = false) {
        guard configuration.automationEnabled,
              configuration.displayUUID != nil,
              !configuration.selectedUSBKeys.isEmpty,
              Date() >= suppressAutomationUntil else {
            updateStatus()
            return
        }

        let connectedKeys = Set(hidInventory.devices().map(\.key))
        let selected = configuration.selectedUSBKeys
        let presentCount = selected.intersection(connectedKeys).count
        let usbPresent = presentCount > 0
        let previousPresence = lastObservedUSBPresent
        let visibleStateChanged = previousPresence != usbPresent || lastObservedPresentCount != presentCount
        lastObservedPresentCount = presentCount

        if force || lastObservedUSBPresent != usbPresent {
            lastObservedUSBPresent = usbPresent
            if previousPresence != usbPresent {
                record(usbPresent
                    ? "实时检测：绑定 USB 已接入（\(presentCount)/\(selected.count)）"
                    : "实时检测：绑定 USB 已全部离开")
            }
            pendingSync?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.syncToUSBState(expectedPresent: usbPresent)
            }
            pendingSync = work
            let delay = usbPresent ? 0.15 : 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else if !isChangingDisplay {
            // Re-assert after sleep/hotplug only when the selected display is actually present.
            syncIfDisplayStateDrifted(usbPresent: usbPresent)
        }

        updateStatus(presentCount: presentCount, selectedCount: selected.count)
        if visibleStateChanged, popover?.isShown == true {
            popoverController?.refresh()
        }
    }

    private func syncToUSBState(expectedPresent: Bool) {
        guard configuration.automationEnabled,
              let uuid = configuration.displayUUID,
              !configuration.selectedUSBKeys.isEmpty else { return }

        let connectedKeys = Set(hidInventory.devices().map(\.key))
        let actualPresent = !configuration.selectedUSBKeys.intersection(connectedKeys).isEmpty
        guard actualPresent == expectedPresent else {
            poll(force: true)
            return
        }

        applyDisplayState(uuid: uuid, connected: actualPresent, reason: actualPresent ? "绑定的 USB 设备已接入" : "绑定的 USB 设备已离开")
    }

    private func syncIfDisplayStateDrifted(usbPresent: Bool) {
        guard configuration.controlMode == .stopOutput else { return }
        guard let uuid = configuration.displayUUID,
              let display = displayController.display(uuid: uuid),
              display.isOnline != usbPresent else { return }
        setDisplay(uuid: uuid, enabled: usbPresent, reason: "显示器状态与 USB 状态不一致")
    }

    private func applyDisplayState(uuid: String, connected: Bool, reason: String) {
        if configuration.controlMode == .stopOutput {
            setDisplay(uuid: uuid, enabled: connected, reason: reason)
            return
        }

        guard !isChangingDisplay else { return }
        isChangingDisplay = true
        defer {
            isChangingDisplay = false
            if popover?.isShown == true { popoverController?.refresh() }
        }
        do {
            if let display = displayController.display(uuid: uuid), display.disabledByThisApp {
                try displayController.setEnabled(uuid: uuid, enabled: true)
            }
            try ddcController.switchInput(displayUUID: uuid, connected: connected)
            lastStatus = connected ? "设备已连接，屏幕输出中" : "设备已断开，屏幕已切断"
            record("\(reason)：DDC 切换至 \(connected ? "HDMI 2" : "HDMI 1")")
            updateIcon(state: connected ? .linked : .away)
        } catch {
            lastStatus = error.localizedDescription
            record("DDC 操作失败：\(error.localizedDescription)")
            updateIcon(state: .error)
        }
    }

    private func setDisplay(uuid: String, enabled: Bool, reason: String) {
        guard !isChangingDisplay else { return }
        isChangingDisplay = true
        defer {
            isChangingDisplay = false
            if popover?.isShown == true {
                popoverController?.refresh()
            }
        }

        do {
            guard let display = displayController.display(uuid: uuid) else {
                // The exact selected monitor is not attached. Do nothing to every other monitor.
                lastStatus = "绑定的显示器不在这台 Mac 上"
                updateIcon(state: .paused)
                return
            }
            if display.isOnline == enabled {
                lastStatus = enabled ? "USB 已接入，屏幕输出已开启" : "USB 已离开，屏幕输出已断开"
                updateIcon(state: enabled ? .linked : .away)
                return
            }

            try displayController.setEnabled(uuid: uuid, enabled: enabled)
            lastStatus = enabled ? "USB 已接入，已恢复 \(display.name)" : "USB 已离开，已断开 \(display.name)"
            record("\(reason)：\(enabled ? "恢复" : "断开") \(display.name)")
            updateIcon(state: enabled ? .linked : .away)
        } catch {
            lastStatus = error.localizedDescription
            record("操作失败：\(error.localizedDescription)")
            updateIcon(state: .error)
        }
    }

    private enum IconState {
        case linked, away, paused, error
    }

    private func updateIcon(state: IconState) {
        // Keep one stable, compact icon in the menu bar. The detailed state is
        // shown as the first line of the menu instead of changing the symbol.
        statusItem.button?.image = NSImage(systemSymbolName: "link", accessibilityDescription: "KVMLink")
        statusItem.button?.title = ""
    }

    private func updateStatus(presentCount: Int? = nil, selectedCount: Int? = nil) {
        guard configuration.automationEnabled else {
            lastStatus = "自动联动已暂停"
            updateIcon(state: .paused)
            return
        }
        guard configuration.displayUUID != nil, !configuration.selectedUSBKeys.isEmpty else {
            lastStatus = "请选择 USB 设备和外接显示器"
            updateIcon(state: .paused)
            return
        }
        if let presentCount, let selectedCount {
            if presentCount > 0 {
                lastStatus = "USB 已接入（\(presentCount)/\(selectedCount)），屏幕应开启"
                updateIcon(state: .linked)
            } else {
                lastStatus = "绑定的 USB 设备已离开，屏幕应断开"
                updateIcon(state: .away)
            }
        }
    }

    private func record(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        recentEvents.insert("\(formatter.string(from: Date()))  \(message)", at: 0)
        recentEvents = Array(recentEvents.prefix(12))
        NSLog("USBDisplayLink: %@", message)
    }

    private func rebuildMenu() {
        popoverController?.refresh()
        // The current UI is a custom popover. Keep the legacy menu builder
        // below as a fallback for older systems, but do not build it normally.
        guard popover == nil else { return }
        menu.removeAllItems()

        let status = NSMenuItem(title: lastStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let automation = NSMenuItem(title: "自动联动", action: #selector(toggleAutomation(_:)), keyEquivalent: "")
        automation.target = self
        automation.state = configuration.automationEnabled ? .on : .off
        menu.addItem(automation)

        menu.addItem(makeUSBMenuItem())
        menu.addItem(makeDisplayMenuItem())
        menu.addItem(.separator())

        let sync = NSMenuItem(title: "立即按 USB 状态同步", action: #selector(syncNow(_:)), keyEquivalent: "s")
        sync.target = self
        menu.addItem(sync)

        let restore = NSMenuItem(title: "恢复绑定显示器", action: #selector(restoreDisplay(_:)), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = configuration.displayUUID != nil
        menu.addItem(restore)

        let disconnect = NSMenuItem(title: "断开绑定显示器", action: #selector(disconnectDisplay(_:)), keyEquivalent: "")
        disconnect.target = self
        disconnect.isEnabled = configuration.displayUUID != nil
        menu.addItem(disconnect)

        menu.addItem(.separator())
        menu.addItem(makeLoginItem())
        menu.addItem(makeRecentEventsItem())

        let about = NSMenuItem(title: "关于 KVMLink", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "恢复显示器并退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makeUSBMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "绑定的 USB 设备", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "绑定的 USB 设备")
        let devices = hidInventory.devices()
        let liveKeys = Set(devices.map(\.key))
        let selected = configuration.selectedUSBKeys

        if devices.isEmpty && selected.isEmpty {
            let empty = NSMenuItem(title: "没有检测到 USB 鼠标或键盘", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }

        for device in devices {
            let item = NSMenuItem(title: "\(device.name)（\(device.kind.rawValue)）", action: #selector(toggleUSBDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.key
            item.state = selected.contains(device.key) ? .on : .off
            item.toolTip = device.detail
            submenu.addItem(item)
        }

        let missing = selected.subtracting(liveKeys)
        if !missing.isEmpty {
            submenu.addItem(.separator())
            for key in missing.sorted() {
                let label = configuration.usbLabels[key] ?? key
                let item = NSMenuItem(title: "\(label)（当前未连接）", action: #selector(toggleUSBDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = key
                item.state = .on
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let explanation = NSMenuItem(title: "单选一个设备进行实时监控", action: nil, keyEquivalent: "")
        explanation.isEnabled = false
        submenu.addItem(explanation)
        root.submenu = submenu
        return root
    }

    private func makeDisplayMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "绑定的外接显示器", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "绑定的外接显示器")
        let displays = displayController.externalDisplays()
        let selectedUUID = configuration.displayUUID?.uppercased()

        if displays.isEmpty {
            let empty = NSMenuItem(title: "没有检测到外接显示器", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }

        for display in displays {
            var title = display.name
            if display.width > 0 && display.height > 0 {
                title += "（\(display.width)×\(display.height)）"
            }
            if !display.isOnline { title += "（已断开）" }
            let item = NSMenuItem(title: title, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display.uuid
            item.state = selectedUUID == display.uuid.uppercased() ? .on : .off
            submenu.addItem(item)
        }

        if let selectedUUID,
           !displays.contains(where: { $0.uuid.uppercased() == selectedUUID }) {
            submenu.addItem(.separator())
            let label = configuration.displayName ?? "已绑定显示器"
            let missing = NSMenuItem(title: "\(label)（当前未连接，不会操作其他屏幕）", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.state = .on
            submenu.addItem(missing)
        }

        root.submenu = submenu
        return root
    }

    private func makeLoginItem() -> NSMenuItem {
        let item = NSMenuItem(title: "登录时启动", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        item.target = self
        if #available(macOS 13.0, *) {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            item.isEnabled = false
        }
        return item
    }

    private func makeRecentEventsItem() -> NSMenuItem {
        let root = NSMenuItem(title: "最近记录", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "最近记录")
        if recentEvents.isEmpty {
            let empty = NSMenuItem(title: "暂无记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for event in recentEvents {
                let item = NSMenuItem(title: event, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }
        root.submenu = submenu
        return root
    }

    @objc private func toggleAutomation(_ sender: NSMenuItem) {
        configuration.automationEnabled.toggle()
        record(configuration.automationEnabled ? "自动联动已开启" : "自动联动已暂停")
        if configuration.automationEnabled {
            poll(force: true)
        } else if let uuid = configuration.displayUUID {
            suppressAutomationUntil = Date().addingTimeInterval(2)
            applyDisplayState(uuid: uuid, connected: true, reason: "暂停自动联动")
        }
        rebuildMenu()
    }

    @objc private func toggleUSBDevice(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if configuration.selectedUSBKeys == [key] { return }
        var labels = configuration.usbLabels
        if let device = hidInventory.devices().first(where: { $0.key == key }) {
            labels[key] = "\(device.name)（\(device.kind.rawValue)）"
        }
        configuration.selectedUSBKeys = [key]
        configuration.usbLabels = labels
        lastObservedUSBPresent = nil
        record("监控设备已切换")
        poll(force: true)
        rebuildMenu()
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String,
              let display = displayController.display(uuid: uuid),
              !display.isBuiltin else { return }

        if let oldUUID = configuration.displayUUID,
           oldUUID.uppercased() != uuid.uppercased() {
            try? displayController.setEnabled(uuid: oldUUID, enabled: true)
        }
        configuration.displayUUID = uuid
        configuration.displayName = display.name
        lastObservedUSBPresent = nil
        record("已绑定显示器：\(display.name)")
        poll(force: true)
        rebuildMenu()
    }

    private func selectControlMode(_ mode: DisplayControlMode) {
        guard configuration.controlMode != mode else { return }
        pendingSync?.cancel()
        if let uuid = configuration.displayUUID {
            try? displayController.setEnabled(uuid: uuid, enabled: true)
        }
        configuration.controlMode = mode
        lastObservedUSBPresent = nil
        record(mode == .stopOutput ? "控制方式：停止输出" : "控制方式：DDC 输入切换")
        poll(force: true)
        rebuildMenu()
    }

    private func selectLanguage(_ language: AppLanguage) {
        guard configuration.interfaceLanguage != language else { return }
        configuration.interfaceLanguage = language
        record(language == .chinese ? "界面语言：中文" : "Interface language: English")
        popoverController?.refresh()
        rebuildMenu()
    }

    @objc private func syncNow(_ sender: NSMenuItem) {
        suppressAutomationUntil = Date.distantPast
        lastObservedUSBPresent = nil
        poll(force: true)
        rebuildMenu()
    }

    @objc private func restoreDisplay(_ sender: NSMenuItem) {
        guard let uuid = configuration.displayUUID else { return }
        suppressAutomationUntil = Date().addingTimeInterval(5)
        setDisplay(uuid: uuid, enabled: true, reason: "手动恢复")
        rebuildMenu()
    }

    @objc private func disconnectDisplay(_ sender: NSMenuItem) {
        guard let uuid = configuration.displayUUID else { return }
        suppressAutomationUntil = Date().addingTimeInterval(5)
        setDisplay(uuid: uuid, enabled: false, reason: "手动断开")
        rebuildMenu()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                record("已关闭登录时启动")
            } else {
                try SMAppService.mainApp.register()
                record("已开启登录时启动")
            }
        } catch {
            showAlert(title: "无法修改登录项", message: "\(error.localizedDescription)\n\n请先把应用移到“应用程序”文件夹，再重试。")
        }
        rebuildMenu()
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let message = "只监听你单选的 USB 设备，也只控制你选中的外接显示器。\n\n设备离开：断开或切换显示器信号\n设备返回：恢复本机显示\n\n显示器控制使用 macOS 的非公开接口；系统升级后若接口变化，应用会报错而不会操作其他显示器。"
        showAlert(title: "KVMLink", message: message)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        if let uuid = configuration.displayUUID {
            if configuration.controlMode == .stopOutput {
                try? displayController.setEnabled(uuid: uuid, enabled: true)
            } else {
                try? ddcController.switchInput(displayUUID: uuid, connected: true)
            }
        }
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - Command line diagnostics

private func runCommandLine(_ arguments: [String]) -> Int32 {
    let displays = DisplayController()
    let hid = HIDInventory()

    guard let command = arguments.first else {
        fputs("Usage: USBDisplayLink --list | --set-display <uuid> <on|off> | --test-display <uuid>\n", stderr)
        return 2
    }

    switch command {
    case "--list":
        print("Displays:")
        for display in displays.allDisplays() {
            print("  \(display.uuid) id=\(display.id) \(display.isOnline ? "online" : "offline") \(display.isBuiltin ? "builtin" : "external") \(display.name) \(display.width)x\(display.height)")
        }
        print("USB HID devices:")
        for device in hid.devices() {
            print("  \(device.key) | \(device.name) | \(device.detail)")
        }
        return 0

    case "--set-display":
        guard arguments.count == 3 else { return 2 }
        do {
            try displays.setEnabled(uuid: arguments[1], enabled: arguments[2].lowercased() == "on")
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }

    case "--test-display":
        guard arguments.count == 2 else { return 2 }
        do {
            print("Disabling \(arguments[1]) for 2 seconds…")
            try displays.setEnabled(uuid: arguments[1], enabled: false)
            Thread.sleep(forTimeInterval: 2)
            print("All displays while disabled:")
            for display in displays.allDisplays() {
                print("  \(display.uuid) id=\(display.id) \(display.isOnline ? "online" : "offline") \(display.name)")
            }
            try displays.setEnabled(uuid: arguments[1], enabled: true)
            print("Restored.")
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            try? displays.setEnabled(uuid: arguments[1], enabled: true)
            return 1
        }

    default:
        return 2
    }
}

let commandLineArguments = Array(CommandLine.arguments.dropFirst())
let diagnosticCommands: Set<String> = ["--list", "--set-display", "--test-display"]
if let firstArgument = commandLineArguments.first, diagnosticCommands.contains(firstArgument) {
    exit(runCommandLine(commandLineArguments))
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
