import AppKit
import CoreAudio
import Foundation

/// One app currently pushing audio to the speakers, as Core Audio sees it.
struct AudioProcess: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AudioProcessLister {
    /// Apps with an active output stream, newest-looking name first.
    static func processesPlayingAudio() -> [AudioProcess] {
        let runningApps = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first })

        return AudioObjectID.allAudioProcesses()
            .filter { $0.isRunningOutput }
            .compactMap { object -> AudioProcess? in
                let pid = object.processPID
                guard pid > 0 else { return nil }
                let bundleID = object.processBundleID
                let app = runningApps[pid]
                // Skip our own output so the visualizer can't feed on itself.
                guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
                let name = app?.localizedName
                    ?? bundleID?.split(separator: ".").last.map(String.init)
                    ?? "PID \(pid)"
                return AudioProcess(id: object, pid: pid, bundleID: bundleID,
                                    name: name, icon: app?.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
