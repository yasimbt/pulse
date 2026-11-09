# M7 findings: polish and extras

## Decisions (developer, 2026-11-09)
- **Fan control: not built.** It needs a root helper (`SMAppService.daemon`) that writes SMC fan
  keys. This MacBook Air has no fans (no `FNum`, no `F*` keys; docs/m2-findings.md), so nothing could
  be tested, and a wrong write could leave fans at a bad speed. Per CLAUDE.md, it stays out until it
  can be verified on a Mac with fans. The read-only fan RPM from M2 remains.
- **Notarized distribution: not now.** It needs an Apple Developer Program membership. Test builds
  stay ad-hoc signed, with the README's "Open Anyway" steps.
