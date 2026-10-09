import SwiftUI
import WidgetKit

// The Home Screen widget's snapshot (9 Oct 2026): what Home would put on its billboard and in its
// queue (`HomeCompose.feed`), written into the App Group as `NextUpSnapshot` with a poster and a
// logo per show, whenever the library changes — debounced, so a burst of marks writes once. The
// widget (PreviouslyWidgets/NextUpWidget.swift) reads it and re-times itself at each airing.
extension AppModel {
    /// The library changed: the widget's snapshot follows, a beat later.
    func scheduleWidgetSnapshot() {
        guard NextUpSnapshot.directory != nil, !isIsolated else { return }
        widgetSnapshotTask?.cancel()
        widgetSnapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            await self.writeWidgetSnapshot()
        }
    }

    /// Up to four shows: the billboard's drops, the quiet card's show, then the queue.
    private static let widgetItems = 4
    private static let posterPixels: CGFloat = 480
    private static let logoPixels: CGFloat = 480

    func writeWidgetSnapshot() async {
        guard let directory = NextUpSnapshot.directory else { return }
        let feed = HomeCompose.feed(self)
        var picks: [(franchise: Franchise, part: FranchisePart, episode: Int, kind: NextUpSnapshot.Item.Kind, behind: Int, airsAt: Int64?)] = []
        for hero in feed.heroes {
            switch hero.kind {
            case .outNow(let behind):
                picks.append((hero.franchise, hero.part, hero.episode, behind > 1 ? .behind : .out, behind, nil))
            case .airing(let at):
                picks.append((hero.franchise, hero.part, hero.episode, .airing, 0, at))
            case .resume:
                picks.append((hero.franchise, hero.part, hero.episode, .resume, 0, nil))
            }
        }
        if let quiet = feed.quiet {
            switch quiet.kind {
            case .airing(let at): picks.append((quiet.franchise, quiet.part, quiet.episode, .airing, 0, at))
            case .resume: picks.append((quiet.franchise, quiet.part, quiet.episode, .resume, 0, nil))
            case .outNow(let behind): picks.append((quiet.franchise, quiet.part, quiet.episode, behind > 1 ? .behind : .out, behind, nil))
            }
        }
        for item in feed.queue where picks.count < Self.widgetItems && !picks.contains(where: { $0.franchise.id == item.id }) {
            picks.append((item.franchise, item.part, item.episode, .resume, 0, nil))
        }
        // Room left: what airs next this week, one entry a show — the widget's rows say "Bleach ·
        // Monday at 7:30 PM" where Home's quiet card would.
        for day in scheduleDays where day.id >= 0 && day.id < 7 && picks.count < Self.widgetItems {
            for entry in day.entries where !entry.aired && picks.count < Self.widgetItems
                && !picks.contains(where: { $0.franchise.id == entry.franchise.id }) {
                picks.append((entry.franchise, entry.part, entry.episode, .airing, 0, entry.at))
            }
        }

        var items: [NextUpSnapshot.Item] = []
        for pick in picks.prefix(Self.widgetItems) {
            let f = pick.franchise
            var item = NextUpSnapshot.Item(id: f.id, title: f.displayTitle,
                                           line: f.watchContext(part: pick.part, episode: pick.episode),
                                           kind: pick.kind, behind: pick.behind,
                                           airsAt: pick.airsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                                           dateOnly: f.timeAnchor.isDateOnly)
            // The picture Home would draw: the show's pick, else the catalogue's billboard.
            let art = PosterPick.shared.choice(for: f).map { WideArt.billboard(portrait: $0.url, landscape: nil) } ?? f.billboardArt
            if let url = art.url {
                item.poster = await writeWidgetImage(url, name: "\(f.id).jpg", pixels: Self.posterPixels, png: false, into: directory)
                let color = await PaletteCache.shared.resolve(url: url, maxPixel: 360)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) { item.tint = [Double(r), Double(g), Double(b)] }
            }
            if let logo = f.billboardLogo?.url {
                item.logo = await writeWidgetImage(logo, name: "\(f.id)-logo.png", pixels: Self.logoPixels, png: true, into: directory)
            }
            items.append(item)
        }
        guard !Task.isCancelled else { return }
        do {
            try NextUpSnapshot(writtenAt: Date(), items: items).write()
            WidgetCenter.shared.reloadTimelines(ofKind: NextUpSnapshot.widgetKind)
        } catch {
            // A failed write leaves the widget on its last snapshot; nothing to tell the user.
        }
    }

    /// A picture the widget can draw: fetched through the app's one pipeline, bounded, and written
    /// as a file the extension reads at render time. Nil when it could not be had.
    private func writeWidgetImage(_ string: String, name: String, pixels: CGFloat, png: Bool, into directory: URL) async -> String? {
        guard let url = URL(string: string), let image = try? await ImageLoader.shared.image(for: url, maxPixel: pixels) else { return nil }
        let scale = min(1, pixels / max(image.size.width * image.scale, image.size.height * image.scale, 1))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !png
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = png ? drawn.pngData() : drawn.jpegData(compressionQuality: 0.84) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }
}
