import SwiftUI
import UIKit

// A bead's media (design 3.5): every picture its notes carry in one grid,
// the newest note's first, pushed from the bead card's Media row. A tap
// opens one full size over the screen, to swipe from to the next and the
// previous, with who attached it and when under it. Pages and other files
// are not in it, nor the body's pictures, which a body has none of.

/// The grid: square thumbnails of the bead's note pictures, read from the
/// card as it stands, so a picture shows where it arrives. Pull to refresh
/// reads the bead again, which asks once more for the pictures the yard
/// held none of.
struct MediaGridScreen: View {
    @Bindable var model: LineModel
    var route: BeadRoute
    /// The picture opened full size, by its `CardMedia.id`.
    @State private var opened: Int?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        let media = model.card(for: route)?.details.media ?? []
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(media) { item in
                    cell(item)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .refreshable { await model.refresh() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            MediaViewer(media: media, start: opened ?? 0) { opened = nil }
        }
    }

    private func cell(_ item: CardMedia) -> some View {
        let name = item.image.name.isEmpty ? "Picture" : item.image.name
        return Button {
            opened = item.id
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { thumbnail(item.image, name: name) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.caption.isEmpty ? name : "\(name), \(item.caption)")
        .accessibilityHint("Opens the picture full size")
        .accessibilityIdentifier("media-picture")
    }

    /// The picture filling its square, or a box: the file's name where the
    /// yard held none or sent no picture, the box alone while it is asked
    /// for, as a note's own thumbnail has it.
    @ViewBuilder
    private func thumbnail(_ image: ShownImage, name: String) -> some View {
        if let decoded = image.bytes.flatMap({ UIImage(data: $0) }) {
            Image(uiImage: decoded)
                .resizable()
                .scaledToFill()
        } else {
            ThemeColor.surfaceSunken.color
                .overlay {
                    if image.missed || image.bytes != nil {
                        Text(name)
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(8)
                    }
                }
        }
    }
}

/// The grid's pictures one at a time and full size, over the screen: a
/// swipe to the next or the previous, who attached the one shown and when
/// under it, and Close above. A tap on the picture shuts it too, as a
/// conversation's picture does.
struct MediaViewer: View {
    var media: [CardMedia]
    var onClose: () -> Void
    /// The picture shown, by its `CardMedia.id`.
    @State private var shown: Int
    /// The picture shown is zoomed in, and has the swipe then.
    @State private var zoomed = false

    init(media: [CardMedia], start: Int, onClose: @escaping () -> Void) {
        self.media = media
        self.onClose = onClose
        _shown = State(initialValue: start)
    }

    var body: some View {
        let place = media.firstIndex { $0.id == shown }
        VStack(spacing: 0) {
            HStack {
                Button("Close", action: onClose)
                    .themeType(.label)
                    .foregroundStyle(ThemeColor.textAccent.color)
                    .frame(minWidth: 48, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("media-close")
                Spacer()
                if let place {
                    Text("\(place + 1) of \(media.count)")
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                        .accessibilityIdentifier("media-place")
                }
            }
            .padding(.horizontal, 20)
            TabView(selection: $shown) {
                ForEach(media) { item in
                    FullPicture(image: item.image, zoomed: $zoomed, onClose: onClose)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(zoomed)
            if let place {
                HStack(spacing: 8) {
                    Text(media[place].author)
                        .themeType(.label)
                        .foregroundStyle(ThemeColor.textPrimary.color)
                    Text(media[place].at)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("media-caption")
            }
        }
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .onChange(of: shown) { zoomed = false }
    }
}
