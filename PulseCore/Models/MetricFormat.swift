import Foundation

/// Turns SI values into display strings. Pure, so it is shared by the UI and the CLI.
public enum MetricFormat {
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Two decimals, matching Activity Monitor's CPU figures. For panels, not the menu bar.
    public static func precisePercent(_ fraction: Double) -> String {
        String(format: "%.2f%%", fraction * 100)
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
        return fixed(value, digits: index == 0 || value >= 10 ? 0 : 1) + units[index]
    }

    /// Watts with one decimal below 100 W, for panels. For example "18.3 W" or "0.2 W".
    public static func watts(_ value: Double) -> String {
        let clamped = max(0, value)
        return fixed(clamped, digits: clamped < 100 ? 1 : 0) + " W"
    }

    /// Compact watts for the menu bar: "0.4W", "4.2W", "18W".
    public static func compactWatts(_ value: Double) -> String {
        let clamped = max(0, value)
        return fixed(clamped, digits: clamped < 10 ? 1 : 0) + "W"
    }

    /// Energy in watt-hours, or milliwatt-hours below 1 Wh.
    public static func energy(joules: Double) -> String {
        let wattHours = max(0, joules) / 3600
        if wattHours < 1 { return "\(Int((wattHours * 1000).rounded())) mWh" }
        return fixed(wattHours, digits: wattHours < 100 ? 1 : 0) + " Wh"
    }

    public static func rpm(_ value: Double) -> String {
        "\(Int(value.rounded())) rpm"
    }

    public static func temperature(_ celsius: Double) -> String {
        "\(Int(celsius.rounded())) °C"
    }

    public static func frequency(_ hertz: Double) -> String {
        "\(Int((hertz / 1e6).rounded())) MHz"
    }

    /// One core is 100%, matching Activity Monitor's process list.
    public static func cores(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }

    /// Elapsed time as a clock: "2:05", or "1:02:05" past an hour.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        let tail = (rest < 10 ? "0" : "") + String(rest)
        if hours > 0 { return "\(hours):" + (minutes < 10 ? "0" : "") + "\(minutes):" + tail }
        return "\(minutes):" + tail
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
        return fixed(scaled, digits: index == 0 || scaled >= 100 ? 0 : 1) + " " + units[index]
    }

    /// Replaces `String(format:)`, which was a measurable cost when run for every module each sample.
    private static func fixed(_ value: Double, digits: Int) -> String {
        guard digits > 0 else { return String(Int(value.rounded())) }
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}
