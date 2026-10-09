import SwiftUI
import UniformTypeIdentifiers

// "Bring your history" — the import sheet (the why is in `AppModel+Import.swift`).
//
// One sheet, one question at a time: where the list is → the name or the file → what was found →
// done. The step that matters is the third: before anything is written the sheet says, in counts,
// what will be added — how many shows, how many episodes, on which shelves — and which titles it
// could not place. Then one button, which says the number.

@MainActor
@Observable
final class ImportModel {
    enum Source: String, CaseIterable, Identifiable {
        case anilist, mal, tvtime
        var id: String { rawValue }

        var name: String {
            switch self {
            case .anilist: Copy.Import.anilist
            case .mal: Copy.Import.mal
            case .tvtime: Copy.Import.tvtime
            }
        }

        var detail: String {
            switch self {
            case .anilist: Copy.Import.anilistDetail
            case .mal: Copy.Import.malDetail
            case .tvtime: Copy.Import.tvtimeDetail
            }
        }
    }

    enum Stage: Equatable {
        case sources
        case entry(Source)
        case reading
        case preview
        case done
    }

    private(set) var stage: Stage = .sources
    private(set) var source: Source?
    var username = ""
    private(set) var preview: ImportPreview?
    private(set) var result: ImportProgress?
    /// What went wrong, in the viewer's words; shown on the entry screen it happened on.
    private(set) var failure: String?
    private(set) var adding = false

    @ObservationIgnored private unowned let appModel: AppModel
    @ObservationIgnored private var readingTask: Task<Void, Never>?

    init(appModel: AppModel) {
        self.appModel = appModel
        appModel.resumeImport()
        if let progress = appModel.importProgress {
            result = progress
            stage = .done
        }
    }

    func startAnother() {
        result = nil
        preview = nil
        failure = nil
        stage = .sources
    }

    /// The sources in the order the viewer's audience makes likely.
    var sources: [Source] {
        switch appModel.audience {
        case .anime: [.anilist, .mal, .tvtime]
        case .tv: [.tvtime, .anilist, .mal]
        case .both: [.anilist, .tvtime, .mal]
        }
    }

    func choose(_ source: Source) {
        self.source = source
        failure = nil
        withAnimation(ThemeMotion.uiSettle) { stage = .entry(source) }
    }

    func back() {
        failure = nil
        withAnimation(ThemeMotion.uiSettle) {
            switch stage {
            case .preview: stage = source.map(Stage.entry) ?? .sources
            default: stage = .sources
            }
        }
    }

    var canGoBack: Bool {
        switch stage {
        case .entry, .preview: true
        default: false
        }
    }

    // MARK: Reading

    func findAniList() {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, stage != .reading else { return }
        readingTask = Task { await run(.anilist) { .anilist(username: name) } }
    }

    /// A picked file: read here, off the main actor; only its watch history goes on.
    func read(file url: URL, as source: Source) {
        guard stage != .reading else { return }
        readingTask = Task { await run(source) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            return try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                switch source {
                case .mal: return ImportRequest.mal(rows: try MalExport.parse(data))
                case .tvtime: return ImportRequest.tvtime(shows: try TvTimeExport.parse(data, fileName: name))
                case .anilist: throw ImportFileError.unrecognised
                }
            }.value
        } }
    }

    func cancelReading() {
        readingTask?.cancel()
        readingTask = nil
    }

    private func run(_ source: Source, _ make: () async throws -> ImportRequest) async {
        self.source = source
        failure = nil
        withAnimation(ThemeMotion.uiGentle) { stage = .reading }
        let epoch = appModel.accountEpoch
        do {
            let request = try await make()
            try Task.checkCancellation()
            let found = try await appModel.api.importPreview(request)
            guard !Task.isCancelled, epoch == appModel.accountEpoch else { return }
            preview = found
            withAnimation(ThemeMotion.uiSettle) { stage = .preview }
        } catch {
            guard !Task.isCancelled, epoch == appModel.accountEpoch else { return }
            failure = Self.words(for: error)
            withAnimation(ThemeMotion.uiGentle) { stage = .entry(source) }
        }
    }

    // MARK: Writing

    func add() async {
        guard let preview, !adding else { return }
        adding = true
        failure = nil
        let epoch = appModel.accountEpoch
        defer { adding = false }
        do {
            let progress = try await appModel.api.importApply(id: preview.id)
            guard epoch == appModel.accountEpoch else { return }
            result = progress
            FeedbackCoordinator.fire(.success)
            await appModel.importApplied(progress)
            withAnimation(ThemeMotion.uiSettle) { stage = .done }
        } catch {
            guard epoch == appModel.accountEpoch else { return }
            failure = Self.words(for: error)
            if (error as? APIError)?.status == 410 {
                withAnimation(ThemeMotion.uiGentle) { stage = source.map(Stage.entry) ?? .sources }
            }
        }
    }

    /// The live count while the sheet stays up: the app's, while it is about THIS import.
    var progress: ImportProgress? {
        if let live = appModel.importProgress, live.id == result?.id { return live }
        return result
    }

    static func words(for error: Error) -> String {
        if let file = error as? ImportFileError {
            switch file {
            case .unrecognised: return Copy.Import.unrecognised
            case .encrypted: return Copy.Import.encrypted
            case .empty: return Copy.Import.emptyFile
            }
        }
        if let api = error as? APIError {
            if case .rateLimited = api { return Copy.Import.rateLimited }
            if case let .http(status, body) = api {
                if body.contains("import_not_found") { return Copy.Import.notFound }
                if body.contains("import_private") { return Copy.Import.privateList }
                if body.contains("import_busy") { return Copy.Import.busy }
                if status == 410 { return Copy.Import.expired }
            }
            return Copy.Import.unavailable
        }
        return Copy.Import.unrecognised
    }
}

struct ImportView: View {
    /// Closed; `imported` when shows were added.
    var onFinished: (_ imported: Bool) -> Void

    @State private var model: ImportModel
    @State private var pickingFile = false
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appModel: AppModel, onFinished: @escaping (_ imported: Bool) -> Void) {
        _model = State(initialValue: ImportModel(appModel: appModel))
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                switch model.stage {
                case .sources: sources.transition(.opacity)
                case .entry(let source): entry(source).transition(.opacity)
                case .reading: reading.transition(.opacity)
                case .preview: found.transition(.opacity)
                case .done: done.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ThemeColor.canvas.ignoresSafeArea())
        .tint(ThemeColor.interactive)
        .interactiveDismissDisabled(model.adding)
        .onDisappear { model.cancelReading() }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: Self.fileTypes) { result in
            guard case .success(let url) = result, let source = model.source else { return }
            model.read(file: url, as: source)
        }
    }

    /// The exports: a zip, a CSV, an XML, the `.xml.gz` MyAnimeList downloads — and plain data,
    /// since a `.gz` has no type every provider agrees on.
    private static let fileTypes: [UTType] = [.zip, .commaSeparatedText, .xml, .gzip, .json, .data]

    // MARK: The bar

    private var bar: some View {
        HStack {
            if model.canGoBack {
                Button { model.back() } label: {
                    AppGlyph(systemName: "arrow.left", decorative: true)
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Copy.Action.back)
                .disabled(model.adding)
            }
            Spacer()
            if model.stage != .done {
                Button { model.cancelReading(); onFinished(false) } label: {
                    AppGlyph(systemName: "xmark", decorative: true)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Copy.FirstRun.close)
                .qaIdentifier("qa.import.cancel")
                .disabled(model.adding)
            }
        }
        .foregroundStyle(ThemeColor.interactive)
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x2)
        .frame(minHeight: 52)
    }

    // MARK: Where the list is

    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeSpace.x5) {
                FirstRunHeading(title: Copy.Import.title, lede: Copy.Import.lede)
                VStack(spacing: ThemeSpace.x2 + 2) {
                    ForEach(model.sources) { source in
                        Button { model.choose(source) } label: { sourceRow(source) }
                            .qaIdentifier("qa.import.source.\(String(describing: source))")
                            .buttonStyle(OverArtPressStyle())
                    }
                }
                Text(Copy.Import.privacy)
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x3)
            .padding(.bottom, ThemeSpace.x8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func sourceRow(_ source: ImportModel.Source) -> some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.row, style: .continuous)
        return HStack(spacing: ThemeSpace.x3) {
            // A monogram on a lit tile — the source by its initial, never by its logo.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(ThemeColor.textPrimary.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ThemeGradient.litEdge, lineWidth: 1))
                .overlay {
                    Text(String(source.name.prefix(1)))
                        .type(ThemeType.sectionTitle)
                        .foregroundStyle(ThemeColor.textPrimary)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .type(ThemeType.rowTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                Text(source.detail)
                    .type(ThemeType.rowMeta)
                    .foregroundStyle(ThemeColor.textSecondary)
            }
            Spacer(minLength: ThemeSpace.x2)
            AppGlyph(systemName: "chevron.forward", decorative: true)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ThemeColor.textTertiary)
        }
        .padding(ThemeSpace.x3 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColor.textPrimary.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(ThemeGradient.litEdge, lineWidth: 1).opacity(0.6))
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: The name, or the file

    @ViewBuilder
    private func entry(_ source: ImportModel.Source) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeSpace.x5) {
                switch source {
                case .anilist:
                    FirstRunHeading(title: Copy.Import.anilistTitle, lede: Copy.Import.anilistNote)
                    nameField
                case .mal:
                    FirstRunHeading(title: Copy.Import.malTitle)
                    steps(Copy.Import.malSteps)
                case .tvtime:
                    FirstRunHeading(title: Copy.Import.tvtimeTitle, lede: Copy.Import.privacy)
                    steps(Copy.Import.tvtimeSteps)
                    Text(Copy.Import.filmsNote)
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textTertiary)
                }
                if let failure = model.failure {
                    InlineNotice(failure)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x3)
            .padding(.bottom, ThemeSpace.x8)
            .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: model.failure)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FirstRunFoot {
                if source == .anilist {
                    Button(Copy.Import.find) {
                        nameFocused = false
                        model.findAniList()
                    }
                    .buttonStyle(PrimaryButtonStyle2())
                    .disabled(model.username.trimmingCharacters(in: .whitespaces).isEmpty)
                    .qaIdentifier("qa.import.preview")
                } else {
                    Button(Copy.Import.chooseFile) { pickingFile = true }
                        .buttonStyle(PrimaryButtonStyle2())
                }
            }
        }
        .onAppear { if source == .anilist { nameFocused = true } }
    }

    private var nameField: some View {
        @Bindable var model = model
        return TextField("", text: $model.username,
                         prompt: Text(Copy.Import.anilistPrompt).foregroundStyle(ThemeColor.textTertiary))
            .qaIdentifier("qa.import.anilist.username")
            .type(ThemeType.body)
            .foregroundStyle(ThemeColor.textPrimary)
            .tint(ThemeColor.interactive)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // No `.textContentType(.username)`: it raised the Passwords bar over a field that
            // has nothing to do with this app's account.
            .submitLabel(.search)
            .focused($nameFocused)
            .onSubmit { self.model.findAniList() }
            .padding(.horizontal, ThemeSpace.x4)
            .frame(minHeight: 52)
            .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeRadius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ThemeRadius.row, style: .continuous)
                .strokeBorder(ThemeGradient.litEdge, lineWidth: 1).opacity(0.7))
    }

    private func steps(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x3) {
                    AppGlyph(systemName: "\(index + 1).circle.fill", decorative: true)
                        .font(.system(size: 20))
                        .foregroundStyle(ThemeColor.textSecondary)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                    Text(line)
                        .type(ThemeType.body)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var reading: some View {
        VStack(spacing: ThemeSpace.x4) {
            ProgressView()
                .controlSize(.large)
                .tint(ThemeColor.textSecondary)
            Text(Copy.Import.reading)
                .type(ThemeType.callout)
                .foregroundStyle(ThemeColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: What was found

    @ViewBuilder private var found: some View {
        if let preview = model.preview {
            if preview.listed == 0 {
                EmptyState(EmptyStateCopy(symbol: "magnifyingglass", title: Copy.Import.nothingFound,
                                          supporting: emptyPreviewSupporting(preview)))
                    .padding(.horizontal, ThemeMetrics.gutter)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: ThemeSpace.x5) {
                        VStack(alignment: .leading, spacing: ThemeSpace.x1) {
                            Text(Copy.Import.found(preview.listed, entries: preview.countsEntries))
                                .type(ThemeType.displayXL)
                                .foregroundStyle(ThemeColor.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            if preview.episodes > 0 {
                                Text(Copy.Import.episodes(preview.episodes))
                                    .type(ThemeType.body)
                                    .foregroundStyle(ThemeColor.textSecondary)
                            }
                        }
                        if !preview.sample.isEmpty { wall(preview.sample) }
                        if preview.ready > 0 {
                            VStack(alignment: .leading, spacing: ThemeSpace.x2 + 2) {
                                // The shelves count SHOWS; said, wherever the headline counts
                                // something else or more is still to come.
                                if preview.countsEntries || preview.toFetch > 0 {
                                    SectionLabel(text: Copy.Import.ready(preview.ready, more: preview.toFetch > 0))
                                }
                                shelves(preview)
                            }
                        }
                        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                            if preview.toFetch > 0 { note(Copy.Import.fetching(preview.toFetch)) }
                            if preview.countsEntries { note(Copy.Import.grouped) }
                            if preview.source == "tvtime" { note(Copy.Import.tvProgressNote) }
                            note(Copy.Import.preserved)
                            if let line = unmatchedLine(preview) { note(line) }
                            if preview.adultSkipped > 0 { note(Copy.Import.adultSkipped(preview.adultSkipped)) }
                            if let failure = model.failure { InlineNotice(failure) }
                        }
                    }
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.top, ThemeSpace.x3)
                    .padding(.bottom, ThemeSpace.x8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    FirstRunFoot {
                        Button { Task { await model.add() } } label: {
                            ZStack {
                                Text(Copy.Import.add(preview.listed, entries: preview.countsEntries))
                                    .opacity(model.adding ? 0 : 1)
                                if model.adding { ProgressView().tint(ThemeColor.onAccent) }
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle2())
                        .disabled(model.adding)
                    }
                }
            }
        }
    }

    private func unmatchedLine(_ preview: ImportPreview) -> String? {
        preview.unmatched.count > 0 ? Copy.Import.unmatched(preview.unmatched.count, titles: preview.unmatched.titles) : nil
    }

    private func emptyPreviewSupporting(_ preview: ImportPreview) -> String {
        let lines = [unmatchedLine(preview),
                     preview.adultSkipped > 0 ? Copy.Import.adultSkipped(preview.adultSkipped) : nil].compactMap { $0 }
        return lines.isEmpty ? Copy.Import.nothingFoundDetail : lines.joined(separator: "\n")
    }

    /// The first few of their shows, as posters: the list, recognised.
    private func wall(_ sample: [FranchiseSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ThemeSpace.x2 + 2) {
                ForEach(sample) { item in
                    let shape = RoundedRectangle(cornerRadius: ThemeRadius.poster, style: .continuous)
                    Color.clear
                        .frame(width: 92, height: 138)
                        .overlay { RemoteImageView(url: item.portraitArt, maxPixel: 300) }
                        .clipShape(shape)
                        .background(ThemeColor.surfaceRaised, in: shape)
                        .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
                        .accessibilityLabel(item.title)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
        }
        .padding(.horizontal, -ThemeMetrics.gutter)
    }

    /// Which shelf each show lands on, in the library's own words.
    private func shelves(_ preview: ImportPreview) -> some View {
        let order: [WatchStatus] = [.watching, .completed, .paused, .planned, .dropped]
        let rows = order.compactMap { status -> (WatchStatus, Int)? in
            let n = preview.byStatus[status.rawValue] ?? 0
            return n > 0 ? (status, n) : nil
        }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(Copy.Status(row.0))
                        .type(ThemeType.body)
                        .foregroundStyle(ThemeColor.textPrimary)
                    Spacer()
                    Text(row.1.formatted(.number))
                        .type(ThemeType.time)
                        .foregroundStyle(ThemeColor.textSecondary)
                }
                .padding(.horizontal, ThemeSpace.x4)
                .frame(minHeight: 48)
                .overlay(alignment: .top) {
                    if index > 0 { ThemeColor.separatorQuiet.frame(height: 1).padding(.leading, ThemeSpace.x4) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .surface(.plate, radius: ThemeRadius.row)
        .opacity(rows.isEmpty ? 0 : 1)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .type(ThemeType.metadata)
            .foregroundStyle(ThemeColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Done

    private var done: some View {
        let progress = model.progress
        let adultSkipped = progress?.skipped?.adultCount ?? model.preview?.adultSkipped ?? 0
        return VStack(spacing: ThemeSpace.x4) {
            Spacer()
            SelectedBadge(size: 64)
            Text(Copy.Import.added(progress?.shows ?? model.preview?.ready ?? 0))
                .type(ThemeType.displayL)
                .foregroundStyle(ThemeColor.textPrimary)
                .contentTransition(.numericText())
                .multilineTextAlignment(.center)
            if let progress, progress.remaining > 0 || progress.failed > 0 {
                Text(progress.remaining > 0 ? Copy.Import.onTheirWay(progress.remaining)
                                            : Copy.Import.missed(progress.failed))
                    .type(ThemeType.body)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if adultSkipped > 0 {
                Text(Copy.Import.adultSkipped(adultSkipped))
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if progress?.isDone == true {
                Button(Copy.Import.another) { model.startAnother() }
                    .buttonStyle(InlineLinkButtonStyle())
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, ThemeSpace.x8)
        .animation(ThemeMotion.pick(ThemeMotion.uiNumeric, reduceMotion: reduceMotion), value: progress)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FirstRunFoot {
                Button(Copy.Import.done) { onFinished(true) }
                    .buttonStyle(PrimaryButtonStyle2())
            }
        }
    }
}
