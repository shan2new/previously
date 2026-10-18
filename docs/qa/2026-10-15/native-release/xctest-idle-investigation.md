# XCTest animation-idle investigation

Read-only review, 2026-10-15T19:01:52.141452+00:00. Installed Xcode 27A266a public SDK headers and current Apple documentation were checked. No tests, builds, UI actions, tools installation, source/configuration changes or private APIs were used.

**No supported public switch to disable or shorten XCTest’s animation-quiescence waits was found in the inspected API surface.** This is a bounded negative finding, not a claim about undocumented internals. Apple documents synchronous `typeText(_:)` without a timeout, typing-frequency or cancellation parameter. The public `XCUIApplication` surface includes app-state waits, but no quiescence setting; the installed app/element headers agree. Element-existence and expectation timeouts describe their own waits and provide no documented cancellation mechanism for an already-running `typeText`. [Apple typeText](https://developer.apple.com/documentation/xcuiautomation/xcuielement/typetext(_:)), [XCUIApplication](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication), [XCUIElement](https://developer.apple.com/documentation/xcuiautomation/xcuielement), [expectation wait](https://developer.apple.com/documentation/xctest/xctestcase/wait(for:timeout:)).

## What this run establishes

The primary all-run ledger ended **failed**, third seed `38654705664` exit **124**, because the external native-command budget reached **1,800 seconds**. That phase has no verified named result, final coverage summary or completed closing oracle/relaunch. The same ledger retains **75/75 directed** and **two completed monkey seeds**. They cannot be assembled into a completed full qualification. [Exact ledger](../../../../ios/Tools/qa/.runs/20261015T175438622566Z/ledger.json).

The third-seed raw log contains **28** animation-completion-notification warnings. The first appears at test time **101.22s**, before the later archive began. Eight `typeText` actions for the 120-character query start at **585.14, 706.09, 827.12, 948.57, 1069.88, 1191.45, 1312.32 and 1433.25 seconds**: seven 16-character chunks and one 8-character chunk. These are observed action-start times, not a measured text-event speed. Pre/post action waits repeatedly last about **60 seconds**; no public contract for that observed value was located. The log ends during another idle wait at **1735.83s** and has no final `QA_SUMMARY`. The absence of a reported product assertion is not a pass. [Raw log](/Users/shan2new/Library/Developer/XcodeBuildMCP/workspaces/previously-2bd4c895d527/logs/test_sim_2026-10-15T18-27-40-658Z_pid58655_205fc48a.log).

The source explains why nominal duration does not cap this sequence: `PreviouslyMonkeyTests` checks `Date() < deadline` only at the outer action loop; `QADriver.replaceText` synchronously types every 16-character chunk and checks each exact prefix before returning. There is no deadline check inside that chunk loop. Thus an action admitted before the 300-second deadline can continue far beyond it. This is static control-flow evidence, not evidence that a specific application animation caused the warning. [Monkey loop](../../../../ios/UITests/PreviouslyMonkeyTests.swift), [text driver](../../../../ios/UITests/QASupport.swift).

## Supported options and limits

| Option | What it can establish | Limit |
|---|---|---|
| XCTest `executionTimeAllowance`, with test timeouts enabled | Fails a test that exceeds its allowance and captures diagnostics; Apple rounds the allowance up to a minute. | Whole-test failure, not successful cancellation/resumption of one interaction. |
| Check an operation deadline before and after each chunk | Prevents issuing the remaining chunks after an overrun is observed. | Cannot interrupt the synchronous chunk already in flight. An unfinished 120-character input or final oracle must fail, never count as completed coverage. |
| Explicit element/property/expectation waits | Bounds the requested condition wait. | Does not document replacing or suppressing event-synthesis quiescence. |
| MCP `type_text` | Official pinned 2.7.0 implementation uses AXe typing. | It is a separate automation path, exposes no XCTest idle setting, and rejects non-US-keyboard characters. Replacing in-test actions would change the harness and lose existing Unicode coverage; it is not a drop-in remedy. |

Sources: [Apple executionTimeAllowance](https://developer.apple.com/documentation/xctest/xctestcase/executiontimeallowance), [Apple element wait](https://developer.apple.com/documentation/xcuiautomation/xcuielement/waitforexistence(timeout:)), [official MCP 2.7.0 type_text source](https://raw.githubusercontent.com/getsentry/XcodeBuildMCP/v2.7.0/src/mcp/tools/ui-automation/type_text.ts). The installed `XCTestCase.h` also explicitly describes spindump capture and process restart after the allowance is exceeded.

For a future authorized diagnostic rerun, a **900-second whole-test ceiling** is a proposed local budget, not an Apple recommendation or product performance target: the two completed seed cases took **503.417s** and **471.365s**, whereas the third command exhausted 1,800s. Public controls include `-test-timeouts-enabled YES`, `-default-test-execution-time-allowance 900` and `-maximum-test-execution-time-allowance 900`, or the corresponding test-plan setting plus `executionTimeAllowance`. Keep the external process budget longer so XCTest can finish recording failure and diagnostics. These controls were not enabled or executed by this review. All three flags are documented in the installed Apple `xcodebuild(1)` manual at lines 471–478. [Apple allowance contract](https://developer.apple.com/documentation/xctest/xctestcase/executiontimeallowance), [installed Apple manual](/Applications/Xcode.app/Contents/Developer/usr/share/man/man1/xcodebuild.1:471), [existing runner](../../../../ios/Tools/qa/run-native-qa.py).

## Mac lock and next useful experiment

**Unlocking as the remedy remains a hypothesis.** The reviewed run ledger and raw test log contain no timestamped lock/unlock transition or controlled comparison. The warnings identify missing animation-completion notifications, not their cause. An app animation, simulator/rendering behavior, host condition or test-framework problem cannot be distinguished from these records alone. The first warnings also precede archive preparation, so that later compilation does not explain their onset; its concurrent effect on later elapsed time was not measured. [Ledger](../../../../ios/Tools/qa/.runs/20261015T175438622566Z/ledger.json), [raw log](/Users/shan2new/Library/Developer/XcodeBuildMCP/workspaces/previously-2bd4c895d527/logs/test_sim_2026-10-15T18-27-40-658Z_pid58655_205fc48a.log), [archive invocation](../consumer-release/archive17-attempt1/invocation.json).

After an actual unlock and an authorized runtime window, first reproduce the exact 120-character search on the same frozen build and QA simulator with existing prefix assertions, dismissal, canonical state and relaunch checks intact. Record lock state and action start/end times. A focused successful run would show that scenario can complete unlocked; it would not alone prove lock causality or replace the required complete all-run. If it still stalls, use XCTest’s public timeout diagnostics to distinguish application activity from runner/simulator waiting. Do not introduce private selectors, disable application animations/security, accept truncated input or remove the closing oracle to obtain a pass.

## Reviewed bytes

SHA-256 hashes below pin the local evidence and public headers used; no runtime mutation was performed.

```
2e8e0525b35f3a8850a9d4e383dcffc09ae401de1eb15a70fd3250f4fa827fa1  ios/UITests/PreviouslyMonkeyTests.swift
7f59c706888e980cf32800077dd4dd441ae2b14122685eb206d48abaa955a536  ios/UITests/QASupport.swift
8e09a2cfc4281c64d8184f1171d445918ceb42d24f18244933b7ba81c5eac0d6  ios/Tools/qa/run-native-qa.py
5543e262c6ac83724881ec68bf3d6ee94af4cf2c7432fd216faa2ab4f8128434  ios/Tools/qa/.runs/20261015T175438622566Z/ledger.json
ec506ad568f7ebf59992373e6d78e4cc6f03f03529ba15c519e9c7d988776b72  /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCUIAutomation.framework/Headers/XCUIApplication.h
2279cc5f76043ff8ccbdeefc6b0966f3c6c64330cc93904fa03b9fbbbaad01e3  /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCUIAutomation.framework/Headers/XCUIElement.h
3495ba29de18055dec5feec3b96339ed8454551ae404584d543988988ad5b25e  /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCTest.framework/Headers/XCTestCase.h
13e98f5f7e1257570087843a95a8594cdf1b9e0bed99b11aa5b13e62a92dd863  /Users/shan2new/Library/Developer/XcodeBuildMCP/workspaces/previously-2bd4c895d527/logs/test_sim_2026-10-15T18-27-40-658Z_pid58655_205fc48a.log
```
