# iPadn + Decrypter integration

This fork is based on **mengangs/ipadn v2.1.3**, commit
`0349a52fe30117f1044385a0f32a69c08928024d`. The vendored Decrypter snapshot is
`w3b32/tetherdecrypt` commit `bbb5e9c326811e8f5d06ce2106865acfb37c7eb8`.
The upstream GPL-2.0 license and credits are retained.

## User flow

1. Download an original IPA with iPadn, or use its existing IPA import flow.
2. Open the completed task's details or long-press its download card.
3. Choose **Prepare decryption runner** (iOS 17.4+).
4. Prepare and share `AppName.Version.runner.ipa` to the signing tool.
5. Sign/install that runner on the iPhone and open it to decrypt.
6. Share `AppName.Version-decrypted.ipa` from the installed runner.

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
- `Decrypter/Core` and the runner source/resources match the working snapshot
  byte-for-byte. `Decrypter/PROVENANCE.json` records the original hashes.
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
python3 scripts/verify_ipa.py build/iPadn-lite-unsigned.ipa
```

The original Go/Rust bridge build steps remain required for a full-feature IPA.
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
versioned names, the concurrency gate and failure cleanup. **The complete
upstream XCTest/UI suite, a normal Xcode main-app build with both Go/Rust bridges,
and real-device behavior have not been run in this Linux environment.** The
existing macOS workflow retains those build/test stages and now also runs the
portable Decrypter checks. Do not treat the Linux checks as a passing full
release pipeline.

DeepSeek specialist calls supplied source/build reviews, the preparation-screen
draft, a code review and localization drafts. The coordinating agent reviewed
and corrected the results, integrated the code, and ran the checks above. No
API credentials or account data belong in the repository or build artifacts.

## Publication status

GitHub returned **403 Resource not accessible by integration** for both the fork
endpoint and new-repository creation endpoint. No new GitHub repo or release was
created. The integration is prepared locally as a separate branch, with a
source archive/patch for review. Create/fork `w3b32/ipadn-decrypter`, grant the
OpenAI integration access, and provide its URL so the branch can be pushed and
the macOS build/test workflow run.
