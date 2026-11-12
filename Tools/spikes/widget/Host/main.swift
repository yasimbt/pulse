// Writes the time into the App Group container, prints where that is, then exits.
import Foundation

let group = "group.com.pulse.spike"
guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
    print("host: no container for \(group)")
    exit(1)
}
let file = container.appending(path: "spike.txt")
let text = "written by host at \(Date().formatted(date: .omitted, time: .standard))"
do {
    try text.write(to: file, atomically: true, encoding: .utf8)
    print("host: wrote \(file.path)")
} catch {
    print("host: write failed: \(error)")
}
