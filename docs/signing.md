# Signing and hardened runtime

Findings from M0 (Xcode 27.2, macOS 27.2, Apple M5).

`project.yml` sets `ENABLE_HARDENED_RUNTIME: YES` with an ad-hoc signature
("Sign to Run Locally"). The two only partly work together until a Developer ID
is configured:

| Build | Hardened runtime | Result |
|---|---|---|
| Debug, ad-hoc | Disabled by Xcode ("Disabling hardened runtime with ad-hoc codesigning") | Runs |
| Release, ad-hoc | On (`flags=adhoc,runtime`) | Crashes at launch |
| Release, ad-hoc, `ENABLE_HARDENED_RUNTIME=NO` | Off | Runs |

The Release crash is dyld library validation refusing the embedded
`PulseCore.framework`: "mapping process and mapped file (non-platform) have
different Team IDs". Ad-hoc signatures have no Team ID.

A Developer ID signature gives the app and the framework the same Team ID, which
should resolve this. That is untested until an identity is set up.

To profile an optimised local build before then:

```bash
xcodebuild -scheme Pulse -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/ ENABLE_HARDENED_RUNTIME=NO build
```
