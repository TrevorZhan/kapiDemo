//
//  PerformanceMonitor.swift
//  kapiDemo
//
//  Samples CPU usage, memory footprint, and thermal state on a fixed interval,
//  combining them with externally-provided camera and preview metrics to produce
//  a PerformanceMetrics snapshot for the debug HUD.
//

import UIKit

// MARK: - Metrics snapshot

struct PerformanceMetrics {
    /// Max concurrent captures allowed before taps are dropped.
    var cap: Int = 0
    /// Currently in-flight (queued) captures.
    var queue: Int = 0
    /// Live preview frames per second (1-second rolling window).
    var fps: Double = 0
    /// Percentage of frames in the last second that were late (janky).
    var jankPercent: Double = 0
    /// Aggregate CPU usage across all threads, as a percentage of one core.
    var cpuPercent: Double = 0
    /// Physical memory footprint of the process in megabytes.
    var memoryMB: Double = 0
    /// Milliseconds from shutter tap to image data arriving (last completed capture).
    var captureLatencyMs: Int = 0
    /// Milliseconds from image data arrival to Photos save completing (last capture).
    var postLatencyMs: Int = 0
    /// Device thermal state.
    var thermal: ProcessInfo.ThermalState = .nominal
    /// Total video preview frames dropped since the session started.
    var droppedFrames: Int = 0
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Monitor

final class PerformanceMonitor {

    /// Called on the main queue every `interval` seconds with a fresh snapshot.
    var onUpdate: ((PerformanceMetrics) -> Void)?

    /// The closure the monitor calls to collect the dynamic, caller-owned fields
    /// (cap, queue, fps, jank, latencies, dropped). The monitor fills in
    /// cpu/memory/thermal itself before handing the snapshot to `onUpdate`.
    var metricsProvider: (() -> PerformanceMetrics)?

    private var timer: Timer?

    func start(interval: TimeInterval = 0.5) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        var metrics = metricsProvider?() ?? PerformanceMetrics()
        metrics.cpuPercent  = cpuUsagePercent()
        metrics.memoryMB    = memoryFootprintMB()
        metrics.thermal     = ProcessInfo.processInfo.thermalState
        onUpdate?(metrics)
    }

    // MARK: - CPU

    /// Sums `cpu_usage` across all threads in the current task.
    /// Each thread's value is expressed as a fraction of TH_USAGE_SCALE (1000),
    /// so the result is a percentage of a *single* logical core.
    /// On a 6-core device fully saturating one core this would read ~100%.
    private func cpuUsagePercent() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0

        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let list = threads else { return 0 }

        defer {
            let bytes = vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), bytes)
        }

        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    // MARK: - Memory

    /// Returns the process's physical memory footprint in megabytes.
    /// `phys_footprint` is the same figure Xcode's Memory gauge shows.
    private func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
