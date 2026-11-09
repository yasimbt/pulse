import Foundation
@testable import PulseCore
import Testing

private func settings(onBattery: RuleActions = .none, lowPower: RuleActions = .none) -> PulseSettings {
    var settings = PulseSettings.default
    settings.sampleInterval = 1
    settings.rules = RuleSettings(onBattery: onBattery, lowPowerMode: lowPower)
    return settings
}

private let battery = PowerContext(onBattery: true, lowPowerMode: false)
private let mains = PowerContext(onBattery: false, lowPowerMode: false)

@Test func onBatteryRuleSlowsSamplingAndHidesModules() {
    let base = settings(onBattery: RuleActions(sampleInterval: 5, hiddenModules: [.power]))
    let effective = Rules.effective(base, context: battery)
    #expect(effective.sampleInterval == 5)
    #expect(effective.modules.first { $0.kind == .power }?.isEnabled == false)
    #expect(effective.modules.first { $0.kind == .cpu }?.isEnabled == true)
    // On mains power nothing changes.
    #expect(Rules.effective(base, context: mains) == base)
}

@Test func rulesCombineTheSlowestRateAndAllHiddenModules() {
    let base = settings(
        onBattery: RuleActions(sampleInterval: 2, hiddenModules: [.power]),
        lowPower: RuleActions(sampleInterval: 5, hiddenModules: [.network])
    )
    let both = Rules.effective(base, context: PowerContext(onBattery: true, lowPowerMode: true))
    #expect(both.sampleInterval == 5)
    #expect(Set(both.modules.filter { !$0.isEnabled }.map(\.kind)).isSuperset(of: [.power, .network]))
}

@Test func aRuleNeverSpeedsSamplingUp() {
    var base = settings(onBattery: RuleActions(sampleInterval: 2, hiddenModules: []))
    base.sampleInterval = 5
    #expect(Rules.effective(base, context: battery).sampleInterval == 5)
}

@Test func settingsWithoutRulesAreUnchanged() {
    var base = PulseSettings.default
    base.rules = nil
    #expect(Rules.effective(base, context: PowerContext(onBattery: true, lowPowerMode: true)) == base)
}
