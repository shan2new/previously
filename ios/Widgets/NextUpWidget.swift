import WidgetKit
import SwiftUI

// The Next up widget (9 Oct 2026): the episode to watch next on the Home Screen — the show's poster
// with its state in a badge, the logo else the name, and the episode; the medium size adds the two
// shows behind it; the Lock Screen's rectangle says the same in words. It draws the snapshot the
// app writes (`NextUpSnapshot`, Shared), re-timed at each airing so "Tonight at 7:30 PM" turns into
// NEW EPISODE the minute it strikes without the app opening. A tap opens the show
// (`previously://show/<id>`).
//
// The extension has no Theme: the brand colours are inlined (`ThemeColor.accent` 0xF0A24E, `news`
// 0xE5262D, `canvas` 0x09090B) and the type is Outfit from the bundled weights (Widgets/Info.plist).

private enum WidgetInk {
    static let accent = Color(red: 240 / 255, green: 162 / 255, blue: 78 / 255)
    static let onAccent = Color(red: 11 / 255, green: 11 / 255, blue: 13 / 255)
    static let news = Color(red: 229 / 255, green: 38 / 255, blue: 45 / 255)
    static let canvas = Color(red: 9 / 255, green: 9 / 255, blue: 11 / 255)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.72)

    /// The poster's hue at canvas depth — the ground the medium widget and the scrim land on.
    static func ground(_ tint: [Double]?) -> Color {
        guard let t = tint, t.count >= 3 else { return canvas }
        // A quarter of the colour over the canvas: hue kept, lightness near the page's.
        return Color(red: 0.035 + t[0] * 0.22, green: 0.035 + t[1] * 0.22, blue: 0.043 + t[2] * 0.22)
    }
}

private enum WidgetType {
    static func outfit(_ weight: String, _ size: CGFloat) -> Font { .custom("Outfit-\(weight)", size: size) }
}

// MARK: - Timeline

struct NextUpEntry: TimelineEntry {
    let date: Date
    let items: [NextUpSnapshot.Item]
    /// The gallery's placeholder: redacted, no real show.
    var placeholder = false
}

struct NextUpProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextUpEntry {
        NextUpEntry(date: Date(), items: NextUpSnapshot.sample.items, placeholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextUpEntry) -> Void) {
        if context.isPreview {
            completion(NextUpEntry(date: Date(), items: NextUpSnapshot.sample.items))
        } else {
            completion(entry(at: Date(), from: NextUpSnapshot.read()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextUpEntry>) -> Void) {
        let snapshot = NextUpSnapshot.read()
        let now = Date()
        var entries = [entry(at: now, from: snapshot)]
        // An airing inside the day flips to NEW EPISODE the minute it strikes.
        let flips = (snapshot?.items ?? []).compactMap(\.airsAt)
            .filter { $0 > now && $0 < now.addingTimeInterval(24 * 3600) }
            .sorted()
        for at in flips.prefix(6) { entries.append(entry(at: at.addingTimeInterval(1), from: snapshot)) }
        // The app rewrites the snapshot as the library changes; an hour is the longest the widget
        // goes without re-reading it on its own.
        let refresh = min(flips.first.map { $0.addingTimeInterval(2) } ?? .distantFuture, now.addingTimeInterval(3600))
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }

    /// The items as they stand at `date`: an airing that has struck is out.
    private func entry(at date: Date, from snapshot: NextUpSnapshot?) -> NextUpEntry {
        let items = (snapshot?.items ?? []).map { item -> NextUpSnapshot.Item in
            var out = item
            if item.kind == .airing, let at = item.airsAt, at <= date {
                out.kind = .out
                out.behind = 1
            }
            return out
        }
        // A drop first, then what airs next, then the queue — the snapshot's order, with a struck
        // airing promoted.
        let ordered = items.sorted { a, b in rank(a) < rank(b) }
        return NextUpEntry(date: date, items: ordered)
    }

    private func rank(_ item: NextUpSnapshot.Item) -> Int {
        switch item.kind {
        case .out, .behind: return 0
        case .airing: return 1
        case .resume: return 2
        }
    }
}

// MARK: - The widget

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NextUpSnapshot.widgetKind, provider: NextUpProvider()) { entry in
            NextUpWidgetView(entry: entry)
        }
        .configurationDisplayName("Next up")
        .description("The episode to watch next, and what airs tonight.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct NextUpWidgetView: View {
    let entry: NextUpEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let lead = entry.items.first {
            switch family {
            case .accessoryRectangular:
                rectangle(lead)
                    .containerBackground(.clear, for: .widget)
                    .widgetURL(link(lead))
            case .systemMedium:
                medium(lead, rest: Array(entry.items.dropFirst().prefix(2)))
                    .containerBackground(for: .widget) { WidgetInk.ground(lead.tint) }
                    .widgetURL(link(lead))
            default:
                // The poster is the CONTAINER's background, so the words can never outgrow the
                // frame: inside the content a filled picture reported its own size and pushed the
                // episode line off the bottom.
                small(lead)
                    .containerBackground(for: .widget) {
                        ZStack {
                            poster(lead)
                            LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                                   .init(color: WidgetInk.ground(lead.tint).opacity(0.86), location: 0.78),
                                                   .init(color: WidgetInk.ground(lead.tint), location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .widgetURL(link(lead))
            }
        } else {
            empty
                .containerBackground(for: .widget) { WidgetInk.canvas }
        }
    }

    private func link(_ item: NextUpSnapshot.Item) -> URL? {
        entry.placeholder ? nil : URL(string: "previously://show/\(item.id)")
    }

    // MARK: Small — the poster, the state, the name, the episode

    private func small(_ item: NextUpSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            badge(item, compact: true)
            name(item, logoHeight: 28, size: 17, lines: 2)
            Text(item.line)
                .font(WidgetType.outfit("Regular", 12))
                .foregroundStyle(WidgetInk.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    // MARK: Medium — the lead with its poster, then the two behind it

    private func medium(_ lead: NextUpSnapshot.Item, rest: [NextUpSnapshot.Item]) -> some View {
        HStack(alignment: .center, spacing: 14) {
            poster(lead)
                .frame(width: 92)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                badge(lead, compact: false)
                name(lead, logoHeight: 34, size: 19, lines: 2)
                    .padding(.top, 5)
                Text(lead.line)
                    .font(WidgetType.outfit("Regular", 13))
                    .foregroundStyle(WidgetInk.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
                if !rest.isEmpty {
                    Spacer(minLength: 6)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(rest) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.title)
                                    .font(WidgetType.outfit("SemiBold", 12))
                                    .foregroundStyle(WidgetInk.text)
                                    .lineLimit(1)
                                Text(stateWord(item))
                                    .font(WidgetType.outfit("Regular", 11))
                                    .foregroundStyle(item.kind == .airing ? WidgetInk.accent : WidgetInk.secondary)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // MARK: Lock Screen — words only

    private func rectangle(_ item: NextUpSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(stateWord(item).uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .lineLimit(1)
            Text(item.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(item.line)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Nothing to watch yet")
                .font(WidgetType.outfit("SemiBold", 15))
                .foregroundStyle(WidgetInk.text)
            Text("Add a show in Previously.")
                .font(WidgetType.outfit("Regular", 12))
                .foregroundStyle(WidgetInk.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Pieces

    @ViewBuilder
    private func poster(_ item: NextUpSnapshot.Item) -> some View {
        if let image = file(item.poster) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            WidgetInk.ground(item.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The state in its badge: NEW EPISODE and a backlog in the app's tags; an airing and the
    /// queue as a quiet label (a tag is for news).
    @ViewBuilder
    private func badge(_ item: NextUpSnapshot.Item, compact: Bool) -> some View {
        switch item.kind {
        case .out, .behind:
            Text(stateWord(item).uppercased())
                .font(.system(size: compact ? 9 : 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(item.kind == .out ? .white : WidgetInk.onAccent)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(item.kind == .out ? WidgetInk.news : WidgetInk.accent,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .airing, .resume:
            Text(stateWord(item).uppercased())
                .font(WidgetType.outfit("SemiBold", compact ? 10 : 11))
                .tracking(0.8)
                .foregroundStyle(item.kind == .airing ? WidgetInk.accent : WidgetInk.secondary)
                .lineLimit(1)
        }
    }

    /// The show's logo on a clean picture, else its name in type.
    @ViewBuilder
    private func name(_ item: NextUpSnapshot.Item, logoHeight: CGFloat, size: CGFloat, lines: Int) -> some View {
        if let logo = file(item.logo) {
            Image(uiImage: logo)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: logoHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(item.title)
        } else {
            Text(item.title)
                .font(WidgetType.outfit("Bold", size))
                .foregroundStyle(WidgetInk.text)
                .lineLimit(lines)
                .minimumScaleFactor(0.85)
        }
    }

    /// "New episode" · "3 episodes behind" · "Tonight at 7:30 PM" / "Tomorrow · 7:30 PM" / "Sunday"
    /// · "Up next" — the app's ladder, said at the entry's date.
    private func stateWord(_ item: NextUpSnapshot.Item) -> String {
        switch item.kind {
        case .out: return "New episode"
        case .behind: return "\(item.behind) episodes behind"
        case .resume: return "Up next"
        case .airing:
            guard let at = item.airsAt else { return "Airing soon" }
            let cal = Calendar.current
            let day: String
            if cal.isDateInToday(at) {
                day = item.dateOnly ? "Today" : (cal.component(.hour, from: at) >= 17 ? "Tonight" : "Today")
            } else if cal.isDateInTomorrow(at) {
                day = "Tomorrow"
            } else {
                day = at.formatted(.dateTime.weekday(.wide))
            }
            if item.dateOnly { return day }
            return "\(day) at \(at.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func file(_ name: String?) -> UIImage? {
        guard !entry.placeholder, let name, let dir = NextUpSnapshot.directory else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(name).path)
    }
}
