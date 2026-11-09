# Ports and chargers: IORegistry findings (M5 MacBook Air, macOS 27.2)

Spike: `Tools/spikes/ports` (`ports-spike <label>` prints a summary and saves the raw properties to
`build/spikes/ports/<label>.plist`). Everything below is readable without root.

## Ports: `AppleHPMInterfaceType10` (USB-C) and `AppleHPMInterfaceType11` (MagSafe 3)
One service per physical port: `Port-USB-C@1`, `Port-USB-C@2` and `Port-MagSafe 3@1`.
- `ConnectionActive` (0/1) is the reliable "something is plugged in" flag.
- `TransportsActive` lists what's in use: `CC` alone for a charger; the USB-C ports also support
  `USB2`, `USB3`, `CIO` (Thunderbolt/USB4) and `DisplayPort` (`TransportsSupported`).
  MagSafe supports power in only.
- Also: `IOAccessoryUSBConnectString`, `IOAccessoryUSBSuperSpeedActive`, `ActiveCable`, `OpticalCable`,
  `PlugOrientation`, `Pin Configuration`, `HPDAsserted` (DisplayPort hot-plug detect).
- **Stale values:** with nothing plugged in, `Port-USB-C@2` still showed `HPDAsserted` = 1, a non-zero
  `PortControllerActiveContractRdo` and `FedExternalConnected` = 1, all left from earlier
  connections. Only `ConnectionActive` tells whether a port is in use now.
- `IOPortTransportState` services (`.../CC`, ...) carry the partner's USB vendor ID in their
  `Metadata` when active: the UGREEN charger reported `Vendor ID (SOP)` 11911 (0x2E87).

## Charger: `AppleSmartBattery`
- `ExternalConnected`, `IsCharging`, `FullyCharged`.
- `AdapterDetails` (and the same in `AppleRawAdapterDetails`): `Watts` (advertised), `Description`
  ("pd charger" for a third-party USB-C PD charger), `AdapterVoltage` (mV) and `Current` (mA) of
  the selected offer, and `UsbHvcMenu`: **every power offer (PDO)** as `MaxVoltage` (mV) and
  `MaxCurrent` (mA), with `UsbHvcHvcIndex` the selected one. `{FamilyCode=0}` alone when unplugged.
- `ChargerData`: `IsCharging`, `NotChargingReason` (128 for a short time right after plugging in,
  then 0), `SlowChargingReason`, `TimeChargingThermallyLimited`.
- `PowerTelemetryData`, in mW, mV and mA: `SystemPowerIn`, `SystemVoltageIn`, `SystemCurrentIn`
  (from the charger), `SystemLoad` (the Mac's use), `BatteryPower` (positive into the battery,
  negative out), `AdapterEfficiencyLoss`. Updated only every few tens of seconds: values were
  identical across 10 s of reads.
- `PortControllerInfo` (one per port controller): `PortControllerPortPDO`, the raw PD offers as
  32-bit words, and `PortControllerMaxPower` (mW). Decoding the words with the USB PD layout matches
  `UsbHvcMenu` and adds a PPS (programmable) range that the menu doesn't list.
  `PortControllerActiveContractRdo` is **stale** (unchanged from before the charger was plugged in)
  and isn't used.

### UGREEN "60 W" USB-C charger on `Port-USB-C@2`
| Field | Value |
|---|---|
| Advertised | 65 W (`Watts`; 20 V x 3.25 A) |
| Offers | 5 V 3 A, 9 V 3 A, 12 V 3 A, 15 V 3 A, 20 V 3.25 A; PPS 3.3-21 V up to 3 A |
| Selected | 20 V, 3.25 A (index 4) |
| Charging | power in 59.4 W (18.92 V x 3.138 A); Mac 7.7 W; battery +51.6 W; loss 1.75 W |
| Check | battery's own 12.03 V x 4.385 A = 52.8 W, against telemetry's 51.6 W |

Still to record: a second charger (MagSafe or another USB-C) and a hub or dock with devices.

## Status (2026-11-09): M5 left open
The developer chose to start M6 and finish M5 when the hardware is at hand. Done: port and charger
readouts, every PD offer, measured input against the rating, and the charger-shortfall alert,
tested on the UGREEN charger. Still to do before tagging v0.5.0:
- A second charger (MagSafe or another USB-C) through `Tools/spikes/ports`.
- A hub or dock with a device attached, to build the per-port device tree (USB and Thunderbolt
  devices with link speed) and the "linked at USB 2 speed on a Thunderbolt port" alert.
- Acceptance: a correct readout with 2 chargers and 1 dock or hub.
