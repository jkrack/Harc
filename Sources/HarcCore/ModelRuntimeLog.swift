import Foundation
import os
import Darwin

public enum ModelRuntimeLog {
    private static let logger = Logger(subsystem: "com.harc.app", category: "ModelRuntime")

    public static func event(
        _ event: String,
        modelID: String,
        reason: String? = nil,
        residentBytes: UInt64? = residentMemoryBytes()
    ) {
        let resident = residentBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "unknown"
        let reasonText = reason ?? "none"
        logger.info("model_runtime event=\(event, privacy: .public) model=\(modelID, privacy: .public) reason=\(reasonText, privacy: .public) rss=\(resident, privacy: .public)")
    }

    public static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}
