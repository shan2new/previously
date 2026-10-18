import SwiftUI

/// Home's last shelves in the directions (`Experience.doors`, 16 Oct — the owner's answer: two
/// shelves, always, under their own shows): the recommender's first two groups ("Because you
/// watched Slime", "More like Frieren"), in Discover's tile — the Library's poster card — with the
/// header opening Discover for the rest. Discovery sits where people land, and leads the moment
/// Home has nothing of theirs to show.
struct HomeForYou: View {
    /// The first section under the billboard sits close to it, as Home's others do.
    let leading: Bool
    /// A title already on the page (the caught-up stage's), kept off the shelves.
    var excluding: String? = nil
    /// The calm Home (19 Oct, "greeted with overwhelm", owner): ONE shelf, headed "For you ›" with
    /// its reason as the line under the title — two shelves under 20-pt reasons were the heaviest
    /// words and the biggest block on a page that is meant to be about your own shows.
    var compact = false
    let onOpen: (RecommendationItem) -> Void
    let onSeeAll: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    static let shelves = 2

    /// The calm Home's posters (19 Oct, "For you too big", owner): 112 pt, three and a peek across
    /// the screen, where the Library's 150 made the shelf the page's biggest block — a suggestion is
    /// the last and least of what Home says. The accessibility sizes keep the Library's.
    static func compactWidth(_ typeSize: DynamicTypeSize) -> CGFloat? {
        typeSize.isAccessibilitySize ? nil : 112
    }

    /// The caught-up stage's show: the first recommendation with art worthy of the stage.
    static func lead(_ appModel: AppModel) -> RecommendationItem? {
        let recs = appModel.visibleRecommendations
        return recs.first(where: \.hasBillboardArt) ?? recs.first
    }

    var body: some View {
        let recs = appModel.visibleRecommendations.filter { $0.key != excluding }
        let groups = Array(ForYouGroup.build(recs, reason: { appModel.spokenReason($0) }).prefix(compact ? 1 : Self.shelves))
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: ThemeMetrics.sectionGap) {
                ForEach(groups) { g in shelf(g) }
            }
            .padding(.top, leading ? ThemeSpace.x4 : ThemeMetrics.sectionGap)
        }
    }

    private func shelf(_ g: ForYouGroup) -> some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            Group {
                if compact {
                    HomeSectionHeader(title: Copy.Home.forYou, subline: g.seed == nil ? nil : g.title, action: onSeeAll)
                } else {
                    SectionHeaderRow(g.title, action: onSeeAll)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    ForEach(g.items) { r in
                        ForYouShelfTile(item: r, reason: appModel.spokenReason(r),
                                        width: compact ? Self.compactWidth(typeSize) : nil) { onOpen(r) }
                            // Home's shelves' one depth: a card entering from the edge grows into place.
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.94, anchor: .bottom)
                                    .opacity(phase.isIdentity ? 1 : 0.72)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, ThemeMetrics.gutter, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}
