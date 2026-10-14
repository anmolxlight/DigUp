import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// When the big first pass (backfill) may run: with the Mac cool (thermal state nominal or fair), not in Low Power
/// Mode, and on AC power if indexing on battery is off (it's on by default). A few new files always index right away;
/// they take seconds.
///
/// Event-driven: power-source, thermal and Low Power Mode changes call `onChange`; nothing polls. (On Linux there are
/// no such notifications to subscribe to without D-Bus: the power supply and power profile are read once a minute.)
final class PowerPolicy {
    private var indexOnBattery: Bool
    private let onChange: (String?) -> Void
    #if canImport(IOKit)
    nonisolated(unsafe) private var powerSource: CFRunLoopSource?   // main thread, and deinit
    #else
    nonisolated(unsafe) private var timer: DispatchSourceTimer?
    #endif
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private(set) var blocker: String?

    /// `onChange` gets why the backfill has to wait, or nil when it may run.
    init(indexOnBattery: Bool, onChange: @escaping (String?) -> Void) {
        self.indexOnBattery = indexOnBattery
        self.onChange = onChange
        blocker = Self.backfillBlocker(indexOnBattery: indexOnBattery)

        #if canImport(IOKit)
        let me = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(powerSourceChanged, me)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        #else
        // ponytail: a 60 s poll of sysfs; UPower's D-Bus signals if a minute's delay on unplugging ever matters.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reevaluate() } }
        timer.resume()
        self.timer = timer
        #endif
        #if os(macOS)
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            })
        }
        #endif
    }

    deinit {
        #if canImport(IOKit)
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        #else
        timer?.cancel()
        #endif
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The "index on battery too" setting changed.
    func setIndexOnBattery(_ on: Bool) {
        indexOnBattery = on
        reevaluate()
    }

    fileprivate func reevaluate() {
        let now = Self.backfillBlocker(indexOnBattery: indexOnBattery)
        guard now != blocker else { return }
        blocker = now
        log("power: backfill \(now.map { "waits (\($0))" } ?? "may run")")
        onChange(now)
    }

    nonisolated static func backfillBlocker(indexOnBattery: Bool) -> String? {
        let info = ProcessInfo.processInfo
        #if os(macOS)
        if info.isLowPowerModeEnabled { return "Low Power Mode" }
        switch info.thermalState {
        case .serious, .critical: return "Mac is warm"
        default: break
        }
        #else
        // Linux has no thermal state to ask for; Power Saver is its Low Power Mode.
        _ = info
        if powerSaver() { return "Power Saver mode" }
        #endif
        if !indexOnBattery, !onACPower() { return "on battery" }
        return nil
    }

    nonisolated static func onACPower() -> Bool {
        #if os(Linux)
        // A laptop's "Mains" (or USB-C) supply says whether it's plugged in; no battery at all is a desktop.
        let supplies = "/sys/class/power_supply"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: supplies)) ?? []
        func read(_ name: String, _ field: String) -> String? {
            (try? String(contentsOfFile: "\(supplies)/\(name)/\(field)", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard names.contains(where: { read($0, "type") == "Battery" }) else { return true }
        return names.contains { ["Mains", "USB"].contains(read($0, "type")) && read($0, "online") == "1" }
        #else
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }   // no power-source info: a desktop Mac
        return type == kIOPMACPowerKey
        #endif
    }

    #if os(Linux)
    /// power-profiles-daemon's Power Saver: what Low Power Mode is on a Mac.
    nonisolated static func powerSaver() -> Bool {
        guard let tool = ["/usr/bin/powerprofilesctl", "/bin/powerprofilesctl"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["get"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let profile = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return profile.trimmingCharacters(in: .whitespacesAndNewlines) == "power-saver"
    }
    #endif
}

#if canImport(IOKit)
/// IOKit calls this on the main run loop when the power source changes.
private nonisolated func powerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        Unmanaged<PowerPolicy>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue().reevaluate()
    }
}
#endif
