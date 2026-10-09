# New-app information requests: developer evidence

Research checked **7 October 2026** using the explicitly invoked [Spike skill](/Users/shan2new/.agents/skills/spike/SKILL.md). Searches included 2026 and focused on the exact limited-review-history wording, physical-device recordings, outcomes and counterexamples. This is research evidence for the release response, not a record that Previously's recording, deletion or resubmission has been completed.

## Findings

1. **A recording and explanatory notes can move an information request forward, but additional review questions can follow.** Tendo's developer reports that its first rejection concerned limited review history; they supplied notes and videos from physical devices, received a subsequent background-audio question, supplied further demonstrations, and were approved. This is a named developer's firsthand account of their app, not Apple's general policy or proof that the exact same binary was retained. The public App Store listing independently confirms the app and matching developer exist. ([Developer account, 26 September 2026](https://itsroglic.com/blog/tendo-is-live-on-the-app-store/), [Apple App Store listing](https://apps.apple.com/at/app/tendo-calm-focus-planner/id6813942909))

2. **Sending the requested information does not establish immediate approval.** Notiz Me's developer reports receiving a limited-history information request on 3 September 2026, replying on 4 September with all six answers and a recording, and adding the answers to Review Notes. At the time of their post, they reported more than a week without a response. The fetched thread has no reply that establishes a resolution. ([Apple Developer Forums, Notiz Me](https://developer.apple.com/forums/thread/845179))

3. **The account-flow recording and resubmission path has a close current iOS analogue.** Yug Purushottam's developer reports the same Guideline 2.1 title and limited-history wording, then supplying a physical iPhone recording showing launch, registration, login, deletion and revocation, alongside purpose, services, regional behavior and Review Notes. They report successful resubmission on 2 October 2026, followed by Waiting for Review. The thread does not establish approval, build continuity or that every claim in the reply was verified by Apple. ([Apple Developer Forums, Yug Purushottam](https://developer.apple.com/forums/thread/849687))

4. **A new binary is not inherently required for a metadata correction.** Apple's current App Store Connect help explicitly permits resubmitting the same build after resolving a metadata issue. It also states that messages and attachments can be exchanged until resubmission. This is authoritative workflow guidance; it is conditional on the issue being metadata-only. It does not guarantee that any particular information reply will be accepted. ([Apple: Reply to App Review messages](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/))

## Evidence table

| Source | Dated evidence | Observable action and outcome | What it cannot establish |
| --- | --- | --- | --- |
| Tendo developer | Article dated 26 September 2026 | Physical-device videos + notes; another question about background audio; more videos; developer reports approval | Exact original build retained; approval rate; repeatable timeline |
| Tendo App Store | Live listing fetched 7 October 2026; publication date not displayed in fetched text | Tendo: Calm Focus Planner, provider David Rok Roglic, available listing | Internal review conversation, submission IDs or binary hashes |
| Notiz Me developer on Apple's forum | Incident 3 September; response 4 September 2026; precise post date not exposed by fetched page | Six answers + recording + Notes; reported no response after more than a week | Present submission status or ultimate outcome |
| Yug Purushottam developer on Apple's forum | Initial submission 27 September; resubmission 2 October 2026; precise post date not exposed by fetched page | Physical launch/account-flow recording + answers + Notes; reported Waiting for Review | Approval, same-build retention or reason for waiting |
| Apple App Store Connect help | Current page fetched 7 October 2026; editorial date not displayed | Same build may be resubmitted for corrected metadata; reply supports attachments | Classification of any specific rejection or acceptance guarantee |

Sources for every table row: [Tendo account](https://itsroglic.com/blog/tendo-is-live-on-the-app-store/), [Tendo listing](https://apps.apple.com/at/app/tendo-calm-focus-planner/id6813942909), [Notiz Me](https://developer.apple.com/forums/thread/845179), [Yug Purushottam](https://developer.apple.com/forums/thread/849687), [Apple workflow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/).

## Brief primary-source excerpts

- Tendo developer: “I also recorded videos showing Tendo running on my real iPhone, iPad and Apple Watch.” ([26 September account](https://itsroglic.com/blog/tendo-is-live-on-the-app-store/))
- Notiz Me developer: “I also added the same information to the App Review Information Notes field” ([Forum post](https://developer.apple.com/forums/thread/845179))
- Yug Purushottam developer: “Account deletion and revocation flow” ([Forum post](https://developer.apple.com/forums/thread/849687))
- Apple: “If your app was rejected for a metadata issue, you can resubmit the same build after resolving the issue.” ([Current help](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/))

Each excerpt remains under 25 quoted words from its source. The App Store listing is used only as an existence cross-check.

## Recommendation and confidence

**Recommended interpretation:** treat explanatory notes and an actual physical-device demonstration as work required to make the current app reviewable. Retain the existing binary if the requested remedy is information/metadata alone and testing exposes no defect; Apple's same-build metadata workflow supports that conditional choice. A recording that leaves a relevant flow unclear may produce another question, as Tendo's reported sequence illustrates. These are recommendations inferred from the sources, not an Apple acceptance commitment. ([Apple workflow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/), [Tendo firsthand account](https://itsroglic.com/blog/tendo-is-live-on-the-app-store/))

**Evidence limits:** the researched developer reports are self-selected firsthand accounts, not a representative sample. They include both a claimed successful outcome and unresolved cases. No independent acceptance-rate data or reliable review-time distribution for this exact limited-history request was identified in this research; do not derive probabilities or a promised completion date from these examples. The same-build conclusion is grounded in Apple's conditional metadata guidance, not in an independently inspected successful developer submission. ([Tendo](https://itsroglic.com/blog/tendo-is-live-on-the-app-store/), [Notiz Me](https://developer.apple.com/forums/thread/845179), [Yug Purushottam](https://developer.apple.com/forums/thread/849687), [Apple workflow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/))

**Source scrutiny:** Apple is authoritative for its submission controls. Tendo's author benefits from promoting their app, so their report is used only as their stated experience and is cross-checked against Apple's listing. Forum authors are reporting their own unresolved submissions; their suspicions about queues or internal review state are not adopted as fact. ([Apple workflow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/), [Tendo account](https://itsroglic.com/blog/tendo-is-live-on-the-app-store/), [Tendo listing](https://apps.apple.com/at/app/tendo-calm-focus-planner/id6813942909), [Notiz Me](https://developer.apple.com/forums/thread/845179), [Yug Purushottam](https://developer.apple.com/forums/thread/849687))
