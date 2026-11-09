# M7 findings: polish and extras

## Decisions (developer, 2026-11-09)
- **Fan control: not built.** It needs a root helper (`SMAppService.daemon`) that writes SMC fan
  keys. This MacBook Air has no fans (no `FNum`, no `F*` keys; docs/m2-findings.md), so nothing could
  be tested, and a wrong write could leave fans at a bad speed. Per CLAUDE.md, it stays out until it
  can be verified on a Mac with fans. The read-only fan RPM from M2 remains.
- **Notarized distribution: not now.** It needs an Apple Developer Program membership. Test builds
  stay ad-hoc signed, with the README's "Open Anyway" steps.

## Floating HUD (`Pulse/Features/HUD/HUDController.swift`)
A borderless, non-activating `NSPanel` at the status-bar level with
`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` and
`ignoresMouseEvents`: above other windows including full-screen apps, on every desktop, never takes
focus, and lets clicks through. Shows CPU, GPU, CPU+GPU watts, chip temperature and memory. Toggled
with ⌃⌥⌘H or in Settings, which also sets the corner; it can't be dragged, because clicks pass
through. While it shows, the sampler adds CPU, memory and power detail (about 1-2% CPU).

`HotKey` now takes a shortcut with its own identifier, and each handler checks the identifier of the
pressed key: Carbon delivers every registered hot key to every handler in the app, so without the
check ⌃⌥⌘H would also have started a recording.

## VoiceOver (`Pulse/Features/Shared/ChartAccessibility.swift`)
Every chart (panel 10-minute charts, history timeline, session charts) is one accessibility element
with a label, a spoken summary of each line's latest value and peak, and an `AXChartDescriptor`
(through `accessibilityChartDescriptor`), so VoiceOver's audio graph can play it and step through its
points. The descriptor uses the same thinned points as the drawing (at most 600 per line) and the
chart's own value formatting. Other checks: icon-only buttons (history earlier/later) have labels,
module tabs carry the selected trait, menu-bar items and the HUD have labels, and metric rows read
as one sentence. Not yet checked by a VoiceOver user on screen.
