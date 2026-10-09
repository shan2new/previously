import WidgetKit
import SwiftUI
import ActivityKit

// The Previously widget extension: the Next up widget (NextUpWidget.swift, 9 Oct) and the
// airing-countdown Live Activity.
// Design system note: extensions don't bundle the Outfit fonts or Theme — colors are inlined
// (accent 0xF0A24E, background 0x0B0B0E) and type is the system font, which is conventional
// for lock-screen surfaces.

private let accent = Color(red: 240 / 255, green: 162 / 255, blue: 78 / 255)
private let backdrop = Color(red: 11 / 255, green: 11 / 255, blue: 14 / 255)

@main
struct PreviouslyWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextUpWidget()
        AiringLiveActivity()
    }
}

struct AiringLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AiringActivityAttributes.self) { context in
            LockScreenAiringView(context: context)
                .activityBackgroundTint(backdrop.opacity(0.9))
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.franchiseTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(episodeLabel(context.attributes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(airsAt: context.state.airsAt)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(accent)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(airLine(context.state.airsAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                AppGlyph(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(accent)
            } compactTrailing: {
                CountdownText(airsAt: context.state.airsAt)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(accent)
                    .frame(maxWidth: 52)
            } minimal: {
                AppGlyph(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(accent)
            }
        }
    }
}

// Lock-screen / banner presentation.
private struct LockScreenAiringView: View {
    let context: ActivityViewContext<AiringActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    AppGlyph(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                    Text(episodeLabel(context.attributes))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
                Text(context.attributes.franchiseTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(airLine(context.state.airsAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            CountdownText(airsAt: context.state.airsAt)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(accent)
        }
        .padding(16)
    }
}

// A self-ticking countdown to the air instant; reads "Out now" once it has passed at render time.
private struct CountdownText: View {
    let airsAt: Date

    var body: some View {
        if airsAt <= Date() {
            Text("Out now")
        } else {
            // The lower bound must not exceed the upper — clamp so a re-render near the boundary
            // can't form an invalid range.
            Text(timerInterval: min(Date(), airsAt)...airsAt, countsDown: true)
                .multilineTextAlignment(.trailing)
        }
    }
}

private func episodeLabel(_ attributes: AiringActivityAttributes) -> String {
    // The app's own notation ("Episode 19", never all caps) — the lock screen is still the app.
    attributes.episodeNumber.map { "Episode \($0)" } ?? "Next episode"
}

private func airLine(_ airsAt: Date) -> String {
    if airsAt <= Date() { return "Aired just now" }
    return "Airs at \(airsAt.formatted(date: .omitted, time: .shortened))"
}
