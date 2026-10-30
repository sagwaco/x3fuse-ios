import Foundation
import Darwin

final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        peak = Self.footprint()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.sagwa.X3Fuse.native.memory"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let value = Self.footprint()
            self.lock.withLock { self.peak = max(self.peak, value) }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() -> UInt64 {
        timer?.cancel()
        timer = nil
        return lock.withLock { max(peak, Self.footprint()) }
    }
}

extension AssetLibrary {
    func prepareDocuments() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["Exports", "Benchmarks"] {
            let directory = documents.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if name == "Exports" {
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where file.lastPathComponent.hasPrefix(".") && file.pathExtension == "partial" {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func benchmarkFixture(arguments: [String]) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Benchmarks", isDirectory: true)
        if let index = arguments.firstIndex(of: "--benchmark"), arguments.indices.contains(index + 1),
           !arguments[index + 1].hasPrefix("-") {
            let name = arguments[index + 1]
            guard name == URL(fileURLWithPath: name).lastPathComponent, ["x3f", "x3i"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return directory.appendingPathComponent(name)
        }
        guard let first = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ ["x3f", "x3i"].contains($0.pathExtension.lowercased()) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Place an X3F or X3I fixture in Documents/Benchmarks before launching with --benchmark."])
        }
        return first
    }

    func writeBenchmarkReport(_ report: [String: Any]) throws {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Benchmarks/report.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
