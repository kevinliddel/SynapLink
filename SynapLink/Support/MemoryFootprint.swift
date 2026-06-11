//
//  MemoryFootprint.swift
//  SynapLink
//
//  Jetsam-relevant memory readings. `footprint` (phys_footprint) is the
//  number the kernel compares against the ~2.1 GB per-app limit on
//  iPhone 11; `available` (os_proc_available_memory) is the remaining
//  headroom before jetsam.
//

import Foundation

enum MemoryFootprint {

    /// Current phys_footprint in bytes, or nil if the kernel call fails.
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Remaining jetsam budget in bytes (iOS only; 0 elsewhere).
    static func available() -> Int {
        #if os(iOS)
        return os_proc_available_memory()
        #else
        return 0
        #endif
    }

    static func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
