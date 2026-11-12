# Simulator CI execution budget

26 October 2026.

The release metadata run `40365400869` passed on retry, including build, lint, contracts, unit/transport tests and artifact preservation. Its first attempt passed the tests but could not reach GitHub's artifact service.

The later documentation-only main run `40369942762` hit a different limit: the combined simulator compilation/test step began at 17:45:24 UTC, but XCTest did not start until 18:02:54 UTC. GitHub terminated the step at its 20-minute limit while tests were still passing. The log contains no failed assertion. The same application source had passed the complete suite in the release run.

Run `40380015274` verified the compilation split, then exposed a separate cold-start cost: the test command began at 18:56:22 UTC but XCTest did not start until 19:04:16 UTC. The 10-minute step ended after 469 passing tests, without a failed assertion. Its incomplete result bundle was preserved successfully. This run is not a passing regression result.

The workflow now uses `build-for-testing` with a 30-minute compilation budget, an explicit `simctl bootstatus -b` readiness step with a 15-minute startup budget, then `test-without-building` with a separate 10-minute execution budget. All three use the same selected iOS 26 simulator; compilation and execution share an explicit derived-data directory. Both test bundles, sequential execution, result-bundle preservation and the required build/lint/contracts gate are retained. This change does not modify the shipped application or any test assertion.

Local validation: workflow YAML, every embedded shell script and whitespace checks pass; the installed Xcode manual confirms both actions and scheme-based compiled-bundle lookup, and `simctl help bootstatus` confirms its readiness behavior. The new full GitHub run must complete before this CI correction is considered verified. Its result is recorded in the local continuation log under `build/parity-validation/`.

## 12 November — privacy publication and practice execution

Native PR 69's CI run `43167091327`, job `131011369240`, failed when
`ProcessInfoPlistFile` read the embedded provider privacy manifest while the
post-build script replaced that file in place. The original upstream and our
replacement declarations are both parseable. A controlled copy interruption
reproduces a partial-plist parse failure with the old implementation.

The build now validates and writes a temporary file in the same bundle directory,
then replaces the manifest atomically. Invalid input preserves the existing
manifest. Four actual-script tests cover a concurrent reader, invalid input,
repeat builds and the existing absent-bundle behavior. A signed simulator test
build passes; its embedded SDK manifest exactly matches the existing
provider declarations. No privacy declaration or package pin changed.

Control-practice run `43167091303`, iPhone job `131011368962`, exceeded its
20-minute test-step budget after four passing cases and during the fifth launch.
There was no failed assertion. The existing seven practice/preparation scenarios
now run as journey, accessibility and invitation groups on both iPhone and iPad.
A selector-coverage test requires every original test exactly once per form.
Assertions, screenshot captures and individual waits are unchanged.

The workflow builds an ad-hoc-signed simulator bundle once on the Apple Silicon
runner, then verifies the source revision and Xcode version before restoring it
for each group. Each group retains its 20-minute execution budget, separate boot
budget and result artifact. Local validation covers all shell blocks, YAML,
selector coverage and the manifest regression. Hosted results remain required;
local iOS 27.2 execution does not establish hosted iOS 26.2 acceptance.

The three execution groups subsequently passed on the signed local iPhone
simulator: **seven tests, zero failures**. Their result bundles are separately
retained as `Practice-journey.xcresult`, `Practice-accessibility.xcresult` and
`Practice-invitations.xcresult`. This validates selector execution and unchanged
flows; hosted phone/tablet results are still pending.
