import Foundation

/// Turns SI values into display strings. Pure, so it is shared by the UI and the CLI.
public enum MetricFormat {
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// 1000-based, matching Finder and Activity Monitor's disk and network columns.
    public static func bytes(_ value: Double) -> String {
        scaled(value, base: 1000)
    }

    /// 1024-based, matching how Activity Monitor reports memory.
    public static func memory(_ value: Double) -> String {
        scaled(value, base: 1024)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    /// Compact form for the menu bar, for example "1.2M".
    public static func compactRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = max(0, bytesPerSecond)
        var index = 0
        while value >= 999.5, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let digits = index == 0 || value >= 10 ? 0 : 1
        return String(format: "%.\(digits)f%@", value, units[index])
    }

    /// One core is 100%, matching Activity Monitor's process list.
    public static func cores(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes)m" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    private static func scaled(_ value: Double, base: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var scaled = max(0, value)
        var index = 0
        while scaled >= base, index < units.count - 1 {
            scaled /= base
            index += 1
        }
        let digits = index == 0 ? 0 : (scaled >= 100 ? 0 : 1)
        return String(format: "%.\(digits)f %@", scaled, units[index])
    }
}
