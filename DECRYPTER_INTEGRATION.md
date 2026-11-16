# iPadn + Decrypter integration

This fork is based on **mengangs/ipadn v2.1.3**, commit
`0349a52fe30117f1044385a0f32a69c08928024d`. The vendored Decrypter snapshot is
`w3b32/tetherdecrypt` commit `bbb5e9c326811e8f5d06ce2106865acfb37c7eb8`.
The upstream GPL-2.0 license and credits are retained.

## User flow

1. Open the **Decrypter** bottom tab (or iPad sidebar).
2. Choose **Select IPA**, or choose an app under **Completed downloads**.
3. Choose **Prepare runner** (iOS 17.4+). The action also remains available in completed download details and menus.
4. Prepare and share `AppName.Version.runner.ipa` to the signing tool.
5. Sign/install that runner on the iPhone and open it to decrypt.
6. Share `AppName.Version-decrypted.ipa` from the installed runner.

Completed IPA cards also expose **Prepare runner** next to **Install**, without
opening task details. The controls wrap vertically at large text sizes or on
narrow screens. The dedicated Decrypter tab supports importing an IPA directly.

Build 35 applies a FastSign-inspired theme throughout the main app: charcoal
surfaces, adaptive lime accents, monospaced text, thin borders and compact
rectangular controls. Light/dark appearance settings, Dynamic Type, Reduce
Motion and the existing navigation and account/download/install features remain
available. This is a native adaptation of the reference, not an embedded website.

Downloading and preparation now live in the same main app. Stock iOS still
requires a separately signed and installed per-app runner before decryption.
The original account-matching IPA/licenses and App Store authorization remain
necessary. Mac, Apple TV and Watch packages are not supported by this runner.

## Scope and preservation

- Existing search, accounts, background downloads, import, native installation,
  Mac package support, pairing, Live Activities and widgets keep their paths.
- The additions to DownloadsView are a completed-task menu action and details
  destination. DownloadManager, Apple authentication and installation logic are
  not changed.
- iPadn retains its iOS 16 deployment target. The preparation screen and runner
  require iOS 17.4. Unsupported package platforms are checked from IPA metadata.
- The decryption/signature algorithms and runner source/resources retain the
  working snapshot. Payload preparation canonicalizes /var and /private/var
  before deriving inventory keys. `Decrypter/PROVENANCE.json` records original
  hashes and these integration adaptations.
- Preparation runs off the main thread; a main-actor gate prevents overlapping
  calls to the core's process-global progress callback. FIFO UI log delivery,
  dismissal controls and failure handling preserve the source and previous
  successful files.
- The existing 11-language catalog has translations for the new labels.
- App update checks use `IPADNUpdateRepository` in Info.plist, currently
  `w3b32/ipadn-decrypter`, so updates do not replace this fork with upstream.
  Update that value if the final repository has another name. Existing feed
  tests now use the configured repository rather than a hardcoded upstream URL.

## Building

Regenerate the Xcode project after adding/changing sources:

```sh
cd iPadn-iOS
python3 scripts/generate_project.py
IPADN_REQUIRE_MACPKG=1 IPADN_REQUIRE_NATIVE=1 bash scripts/build_unsigned_ipa.sh
python3 scripts/verify_ipa.py build/iPadn-unsigned.ipa
python3 scripts/make_lite_ipa.py build/iPadn-unsigned.ipa build/iPadn-lite-unsigned.ipa
```

The original Go/Rust bridge build steps remain required for a full-feature IPA.
The standard-package verifier expects the Live Activity extension. The workflow
checks the lite package separately; it removes that extension and retains the
runner template and all other app files.
The Xcode main target depends on an **unsigned**, `SKIP_INSTALL=YES`
DecrypterRunner target. A final device-build phase packages that product into
`HelperTemplate.ipa` inside iPadn. It is a ZIP resource, not a nested installed
app, and it survives the standard-to-lite conversion. Simulator builds omit
the device template; FairPlay decryption cannot be verified in a simulator.

## Validation

The Linux workspace completed these checks:

- 15 production C/runner-packaging tests passed.
- Production Swift payload/import/manifest tests passed.
- Project references, deployment settings, localization catalogs, icon
  resources, lexical checks and vendored runtime hashes passed.
- The original local SAP/Store signing-runtime smoke test passed.
- Original reveal-animation source verification passed.
- ZIPFoundation and the combined iPadn iPhoneOS Swift sources type-checked with
  the available Swift 6.2/iOS 26.5 export. A temporary external WebKit interface
  overlay removed an unsupported `@_expose(!Cxx)` annotation from the newer SDK
  interface for this check; project source and the SDK export were not changed.
- The actual vendored runner compiled/linked for physical arm64 iOS 17.4 and
  its unsigned IPA package verified (entry point, platform, cryptid, resources).

New XCTest coverage checks completed-task eligibility, actual package platform,
versioned names, the concurrency gate and failure cleanup.

The [macOS validation run](https://github.com/w3b32/ipadn-decrypter/actions/runs/43903925657)
for source `5de9cb58ec3c37d109e9598b13f804a3d0ee3bee` passed. It ran the 15
native/packaging tests, all Swift payload checks, and the complete unsigned
device build with the original Go/Rust bridges. Its IPA verifier passed ZIP CRC,
runner-template, runtime-hash, native bridge, icon and unsigned-package checks.
Downloaded diagnostics confirm iPadn 2.1.3 build 35 and the iOS 27.2 SDK.

[Download the standard/lite unsigned IPAs](https://github.com/w3b32/ipadn-decrypter/actions/runs/43903925657/artifacts/14245671197).
The workflow runs no simulator build or tests, as requested. Real-device
integration remains untested. The [validation report](docs/decrypter-validation.json)
records the source, run and artifact digest.

DeepSeek specialist calls supplied source/build reviews, the preparation-screen
draft, a code review and localization drafts. The coordinating agent reviewed
and corrected the results, integrated the code, and ran the checks above. No
API credentials or account data belong in the repository or build artifacts.

## Publication status

The integration repository is https://github.com/w3b32/ipadn-decrypter. It was
created by the user after automated repository creation was blocked. The source
is imported from the exact upstream v2.1.3 commit with its original history and
license; this standalone repository is not registered in GitHub's fork network.

The original `xcode-27` GitHub-hosted runner image provides Xcode 27.2 and iOS
27.2 SDKs for the physical-device build.
GitHub Actions artifacts provide unsigned standard and lite IPAs after a passing
device build. Full CI status is available on the repository's Actions tab.
Real-device validation remains necessary after installing a generated runner.

At the user's request, the IPA workflow contains no simulator builds, simulator
tests or screenshot steps. It builds and verifies the physical-device IPA,
uploads standard/lite packages, and keeps the fast host Decrypter checks.
