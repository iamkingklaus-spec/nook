# iOS baseline and personal signing

The reviewed baseline is commit `ebd5ee670ffb578edcc0bb32d41dee5515ae4beb`.
The signing change and CI workflow do not modify reader functionality, Plus
code, package versions, deployment targets, or the paired background-task IDs.

## Personal signing

In the project's Build Settings, set these User-Defined values for **both Debug
and Release** before running on a physical device:

- `NOOK_IOS_BUNDLE_ID`: your unique app identifier. `com.example.nook.ios` is a
  placeholder, not a provisioned identifier.
- `NOOK_SIGNING_TEAM`: your actual Apple development Team ID. It is intentionally
  empty by default.

The main app uses that bundle ID, and the three iOS extensions append `.share`,
`.share-save`, and `.share-discover`. All four targets use the same team variable.
Check the resolved values in Signing & Capabilities for every target. The
NookiOS scheme's Run action uses **Release**, so checking only Debug is insufficient.

Both app configurations use `Config/NookiOS-Personal.entitlements`, an empty
dictionary without the author's associated domain. The original
`NookiOS/NookiOS.entitlements` is retained. This removes the associated-domain
request from personal signing; it does not disable Plus network access or remove
the Plus build dependency. System-generated signing entitlements still apply.
No additional App Groups or Keychain Sharing capability is introduced.

This configuration still needs physical-device verification with your team and
provisioning profiles. The three embedded extensions must also sign successfully.
Installing alongside the original app may conflict over the existing `nook://`
URL scheme; use an isolated test installation. No URL scheme is changed here.

## GitHub Actions

`.github/workflows/ios-baseline.yml` runs on branch pushes, pull requests, and
manual dispatch. Push it to a repository you control and enable Actions there.
It is separate from the existing tag-triggered macOS release workflow and does
not publish a release, sign an app, or use Apple, Gemini, or signing secrets.
The workflow only requests read access to repository contents.

The runner is `macos-26`, using the explicitly selected Xcode 26.5 installation.
The [official runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
listed that installation when this workflow was prepared. Images can change:
the workflow prints installed Xcodes, macOS, Swift, SDKs, and simulator runtimes,
then fails explicitly if the selected toolchain is unavailable or insufficient.
It does not lower platform targets or install a different Xcode silently.

The job runs, in order:

1. Checkout source and build assets (marketing assets are excluded).
2. Record and validate macOS/Xcode/Swift/SDK versions.
3. Resolve Xcode packages and the standalone NookKit package dependencies.
4. Build the iOS Simulator Debug configuration with `CODE_SIGNING_ALLOWED=NO`.
5. Build the iOS Simulator Release configuration with `CODE_SIGNING_ALLOWED=NO`.
6. Run `swift test --package-path NookKit` on the macOS host.
7. Check working-tree whitespace and committed changes since the reviewed baseline.

GitHub's explicit `bash` shell uses `-e -o pipefail`, so piping output to `tee`
does not turn a failed build into a successful step. Failures stop the remaining
build/test steps; the diagnostic, summary, and artifact steps still run. Skipped
steps are reported as skipped, never as successful.

The artifact `nook-phase0-<run ID>-<attempt>` contains unfiltered command logs,
available Xcode result bundles, resolved dependency files, and a summary of
actual step outcomes. The test summary preserves the test runner's count lines
rather than counting tests from source or treating XCTest's zero-test message as
proof that Swift Testing ran. If tests never start, there is no test count.

Nook Plus is currently an unconditional dependency of NookKit. The lockfile pins
`nook-plus-protocol` to 0.4.1. A failure to fetch or compile it can block ordinary
RSS builds even when nobody signs in. Preserve the entire error and stop for
review if that happens. Do not remove Plus or rewrite the package as an automatic
recovery step. Both Xcode and SwiftPM resolution logs are saved because their
lockfile locations can differ. The job records lockfile changes; it never commits
them or updates package declarations.

## Validation boundary

Preparing or statically validating this workflow does **not** mean it ran on
GitHub. Only a run URL for the pushed commit and its recorded outcomes establish
CI results. Simulator builds do not establish Personal Team signing or iPhone
installation success. A missing runner, organization approval, or Actions
permission is an infrastructure blocker, not a passing build.

Stop after phase 0 results are reviewed. This workflow and signing setup do not
authorize or implement any V1 news or bilingual features.
