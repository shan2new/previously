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
    let onOpen: (RecommendationItem) -> Void
    let onSeeAll: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let shelves = 2

    /// The caught-up stage's show: the first recommendation with art worthy of the stage.
    static func lead(_ appModel: AppModel) -> RecommendationItem? {
        let recs = appModel.visibleRecommendations
        return recs.first(where: \.hasBillboardArt) ?? recs.first
    }

    var body: some View {
        let recs = appModel.visibleRecommendations.filter { $0.key != excluding }
        let groups = Array(ForYouGroup.build(recs, reason: { appModel.spokenReason($0) }).prefix(Self.shelves))
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: ThemeMetrics.sectionGap) {
                ForEach(groups) { g in shelf(g) }
            }
            .padding(.top, leading ? ThemeSpace.x4 : ThemeMetrics.sectionGap)
        }
    }

    private func shelf(_ g: ForYouGroup) -> some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(g.title, action: onSeeAll)
                .padding(.horizontal, ThemeMetrics.gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    ForEach(g.items) { r in
                        ForYouShelfTile(item: r, reason: appModel.spokenReason(r)) { onOpen(r) }
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
