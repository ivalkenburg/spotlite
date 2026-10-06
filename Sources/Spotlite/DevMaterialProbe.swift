import AppKit
import Darwin

/// Opt-in instrumentation, constructed only by SPOTLITE_DEV_MATERIAL_BENCH.
/// Display-link gaps measure main-thread pacing, not GPU presentation time.
@MainActor
final class DevMaterialProbe: NSObject {
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var intervals: [Double] = []

    func start(in view: NSView) {
        intervals.removeAll(keepingCapacity: true)
        lastTick = nil
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if let lastTick { intervals.append((now - lastTick) * 1_000) }
        lastTick = now
    }

    func stop(_ phase: String, extra: [String: Any] = [:]) {
        link?.invalidate()
        link = nil
        let sorted = intervals.sorted()
        var data = extra
        if !sorted.isEmpty {
            data["callback_count"] = sorted.count
            data["callback_p50_ms"] = sorted[sorted.count / 2]
            data["callback_p95_ms"] = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            data["callback_max_ms"] = sorted.last!
            data["callback_gaps_over_25ms"] = sorted.filter { $0 > 25 }.count
        }
        Self.emit(phase, extra: data)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func emit(_ phase: String, extra: [String: Any] = [:]) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var data = extra
        data["phase"] = phase
        data["pid"] = ProcessInfo.processInfo.processIdentifier
        data["material"] = ProcessInfo.processInfo.environment["SPOTLITE_DEV_MATERIAL"] ?? "glass"
        data["theme"] = ProcessInfo.processInfo.environment["SPOTLITE_DEV_THEME"] ?? "dark"
        data["uptime_s"] = ProcessInfo.processInfo.systemUptime
        data["cpu_s"] = cpuSeconds()
        if result == KERN_SUCCESS {
            data["footprint_bytes"] = info.phys_footprint
            data["resident_bytes"] = info.resident_size
            data["compressed_bytes"] = info.compressed
        }
        let json = try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        FileHandle.standardOutput.write(Data("MATERIAL_BENCH ".utf8) + json + Data("\n".utf8))
    }
}
