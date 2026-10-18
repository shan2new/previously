# Billboard readiness repair

Prepared from the failed 15 October run `20261015T171508872199Z`: 64/75 directed cases passed, 11 failed, and no monkey seed started. The repair is **pending runtime verification**. This evidence does not establish that every failure has the same cause.

The first account-isolation case recorded a tap on the real `qa.progress.mark.1001` button at 17:15:58 UTC. No domain write reached the fixture before the next test reset. Its final accessibility hierarchy shows progress **3**, journal count **0**, no Add to Library alert, and the still-uncommitted “Mark episode 4 as watched” control. The final screenshot shows that control visibly present later.

The original XCTest video is preserved in the run's attachments. These are directly decoded frames, without cropping, compositing or retouching:

- [9.4 seconds](actual-before-mark-9.4s.png): navigation is still arriving; the action is not visible.
- [10.1 seconds](actual-after-mark-10.1s.png): the billboard's title and action area are blank.
- [11.5 seconds](actual-later-11.5s.png): that arrival area remains blank.

These are media offsets in a variable-frame-rate recording. They support the observed arrival mismatch; they do not establish subframe synchronization of the injected event. Original artifact paths and hashes are in [receipt.json](receipt.json).

Source review found that the stage reuses `pinnedAction`, including its real mark button, inside `HomeArrival.line(4)`. `HomeArrival` previously changed opacity and offset without hiding its children from accessibility or hit testing. For the fixture's missing artwork, `ShowBillboard.settle()` selected the fallback but did not signal `artLoaded()`. `ArtHeader` calls its image callback only for a nonempty URL, leaving this fallback to the three-second safety timer.

Only [ShowBillboard.swift](/Users/shan2new/Projects/previously/ios/Sources/DesignSystem/ShowBillboard.swift) changed:

- A settled nil **or empty** artwork URL signals that its fallback is ready, after the settled art callback. No nonexistent image download is awaited.
- The existing arrival state controls hit testing and accessibility as well as opacity/offset. Reduce Motion remains immediately visible.
- The three-second safety timer for actual image failure is retained. Progress logic, network operations, test assertions, action selection, and all 75 selected test cases are unchanged.

Scoped `git diff --check` passed. No build, simulator interaction or native test was run by this agent. Root owns the focused account-isolation rerun, then all 75 directed cases and the three 300-second monkey seeds against the frozen source.
