import PhotosUI
import SwiftUI
import UIKit

struct ConversationScrollEdges: Equatable {
    var atTop: Bool
    var atFoot: Bool
    var hasOlder: Bool
}

/// Remembers where the conversation is before a new letter arrives, and
/// asks for an older page only when the person returns to the top after
/// moving away from it.
struct ConversationScrollTracking: Equatable {
    private(set) var atFoot = true
    private var movedAwayFromTop = false

    mutating func reset() {
        atFoot = true
        movedAwayFromTop = false
    }

    mutating func update(_ edges: ConversationScrollEdges) -> Bool {
        atFoot = edges.atFoot
        guard !edges.atTop else {
            guard movedAwayFromTop else { return false }
            movedAwayFromTop = false
            return edges.hasOlder
        }
        movedAwayFromTop = true
        return false
    }

    func follows(mine: Bool) -> Bool {
        mine || atFoot
    }
}

// One conversation (design 3.5), pushed onto the crew stack: the name
// in the navigation bar with its state word; the letters oldest first
// with the newest at the foot, the correspondent's the width of the
// screen on no surface and the person's own in a bubble at the right,
// each drawn by its Markdown (`MessageText`); its images under its
// text, opened full on tap; the composer, one box, holding the field
// with the pictures picked for the letter above it, a row of thumbnails
// each with its own cross, and, under them, the plus (a menu: Camera,
// Photos) and the round arrow that sends.
// Scrolling to the oldest letter reads the page before it. The
// yard's notices are drawn the same way, with no field. A chip
// tapped opens its bead as a sheet over the conversation, with an
// Open on the line under the card.
struct ConversationScreen: View {
    @Bindable var model: ConversationModel
    @Bindable var line: LineModel
    var yard: String
    var with: String
    /// A chip tapped: its bead opens in a sheet over the conversation.
    var openBead: (String) -> Void = { _ in }
    /// The sheet's Open on the line: the bead's card opens on the
    /// Lines place, as a chip's tap did before the sheet.
    var openOnLine: (BeadRoute) -> Void = { _ in }
    /// The preview releases its line observer when it closes; the
    /// Lines place keeps it when Open on the line hands off there.
    var beadSheetDismissed: () -> Void = {}
    @State private var field: String = ""
    @State private var scrollTracking = ConversationScrollTracking()
    @State private var showGallery = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var cameraVisit: Int? = nil

    private var canPhoto: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Links in a letter: a chip opens its bead whole, and a web address
    /// opens as before.
    private var letterLinks: OpenURLAction {
        OpenURLAction { url in
            if let id = chippedBead(url) {
                openBead(id)
                return .handled
            }
            return .systemAction
        }
    }

    var body: some View {
        let state = model.state
        ZStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Not lazy (footplate-ios-g0jx): a lazy stack
                        // registers a letter only once it has been laid
                        // out near the reader, so no scroll could name
                        // the foot before it was reached. The letters
                        // arrive a page at a time and an unchanged one
                        // is not read again (MessageText above), so
                        // laying out the pages read costs the parse of
                        // each letter once.
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(state.letters, id: \.seq) { letter in
                                // The beads of the one reading above, not
                                // a reading per bubble: `state` rebuilds
                                // every letter's row, so a reading here
                                // paid it once per letter on screen
                                // (footplate-ios-g0jx).
                                letterBubble(letter, beads: state.knownBeads)
                                    .id(letter.seq)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    // The foot is where a conversation stands when it
                    // opens (footplate-ios-g0jx): the scrolls to it wait
                    // for the stack's first layout, when every letter
                    // of the page stands in it to be named.
                    .onAppear {
                        scrollTracking.reset()
                        if let last = state.letters.last {
                            scrollToFoot(proxy, last.seq, animated: false)
                        }
                    }
                    .onChange(of: state.letters.last?.seq) { before, last in
                        // The first page to land opens at the foot,
                        // whatever the geometry of the empty screen
                        // said a moment before; a later letter is
                        // followed only as the tracking allows.
                        if before == nil, let last {
                            scrollToFoot(proxy, last, animated: false)
                        } else if let last, scrollTracking.follows(mine: state.letters.last?.mine ?? false) {
                            scrollToFoot(proxy, last, animated: true)
                        }
                    }
                    .onScrollGeometryChange(for: ConversationScrollEdges.self) { geometry in
                        let top = -geometry.contentInsets.top
                        let bottom = max(top, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom)
                        return ConversationScrollEdges(
                            atTop: geometry.contentOffset.y <= top + 1,
                            atFoot: geometry.contentOffset.y >= bottom - 64,
                            hasOlder: state.more
                        )
                    } action: { _, edges in
                        // Written only where the edges changed, so a
                        // geometry pass that changes nothing redraws
                        // nothing (footplate-ios-g0jx).
                        var tracked = scrollTracking
                        let older = tracked.update(edges)
                        if tracked != scrollTracking { scrollTracking = tracked }
                        if older {
                            Task { await model.older() }
                        }
                    }
                }
                if let error = state.error {
                    Text(error)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textError.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                }
                if state.writable {
                    Divider().overlay(ThemeColor.borderSubtle.color)
                    // While picked pictures are prepared, the word for them; the
                    // pictures themselves stand inside the composer's box.
                    if let preparing = attachingWords(state.attaching) {
                        Text(preparing)
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 4)
                    }
                    composer(state)
                }
            }
            // The picture opened full, over the conversation: a
            // tap shuts it, as the back control does.
            if let full = state.full {
                FullPicture(image: full) { model.closePicture() }
                    .id(full.hash)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .navigationTitle(state.title)
        .toolbar {
            if let word = state.state {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(word)
                        .themeType(.meta)
                        .foregroundStyle(state.waiting ? ThemeColor.textAccent.color : ThemeColor.textSecondary.color)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            model.open(yard: yard, with: with)
            // The model's draft is the field's: one kept across a leave,
            // or one the bead card's Ask started with the bead's id.
            field = model.draftText
        }
        .onDisappear { model.leave() }
        .photosPicker(isPresented: $showGallery, selection: $pickerItems, maxSelectionCount: maxAttached, selectionBehavior: .ordered, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            guard let visit = model.attachmentVisit(yard: yard, with: with) else { return }
            // In the order the picker numbered them, so that the row keeps
            // that order. Reserve all their places before
            // their asynchronous reads begin; Send joins those reads, and a
            // late read after navigation is rejected by its visit. A pick is
            // named by its number so a failure says which it was.
            for (number, item) in items.enumerated() {
                model.attach(
                    load: { try? await item.loadTransferable(type: Data.self) },
                    name: "photo \(number + 1)", yard: yard, with: with, visit: visit
                )
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in
                if let data, let cameraVisit {
                    model.attach(bytes: data, name: "photo.jpg", yard: yard, with: with, visit: cameraVisit)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(item: sheetBinding, onDismiss: beadSheetDismissed) { route in
            NavigationStack {
                VStack(spacing: 0) {
                    // A chip in the sheet's card hands off to the line,
                    // as Open on the line does: the sheet is no place to
                    // push another card behind.
                    BeadCardScreen(model: line, route: route, openBead: { openOnLine(BeadRoute(yard: route.yard, bead: $0)) })
                    Button("Open on the line") {
                        openOnLine(route)
                    }
                    .buttonStyle(FootplateButtonStyle(primary: false))
                    .accessibilityIdentifier("bead-open-on-line")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// A scroll to the foot, deferred past the stack's first layout:
    /// named before it, a scroll finds no letter to go to and is lost
    /// (footplate-ios-g0jx). The opening scroll jumps: animated over
    /// the whole thread it crawls, where a followed letter's is short.
    private func scrollToFoot(_ proxy: ScrollViewProxy, _ seq: Int64, animated: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if animated {
                withAnimation { proxy.scrollTo(seq, anchor: .bottom) }
            } else {
                proxy.scrollTo(seq, anchor: .bottom)
            }
        }
    }

    /// The chip's bead as a sheet, shut on a swipe down.
    private var sheetBinding: Binding<BeadRoute?> {
        Binding(get: { model.state.sheet }, set: { if $0 == nil { model.closeBeadSheet() } })
    }

    /// The composer (footplate-ios-xb4g, as Android's since
    /// footplate-android-vhzg): one rounded box holding the picked
    /// pictures' row, the field with no border of its own and, under them,
    /// the icon row: the plus at the left, a menu that adds a picture, and
    /// the round arrow at the right that sends. The box wears the field's
    /// old surface and hairline. The arrow is dim by the rule the Send
    /// button it replaces was disabled by.
    private func composer(_ state: ConversationState) -> some View {
        let nothingToSend = (field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.attached.isEmpty) || state.sending || state.attaching > 0
        let box = RoundedRectangle(cornerRadius: 8)
        return VStack(alignment: .leading, spacing: 0) {
            if !state.attached.isEmpty {
                attachedRow(state.attached)
            }
            TextField("Write back", text: $field, axis: .vertical)
                .lineLimit(1...5)
                .accessibilityIdentifier("conversation-field")
                .themeType(.body)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .onChange(of: field) { _, text in
                    if text != model.draftText { model.draft(text) }
                }
                .onChange(of: state.draft) { _, draft in
                    if draft.isEmpty { field = "" }
                }
            HStack(spacing: 0) {
                Menu {
                    if canPhoto {
                        Button("Camera") {
                            cameraVisit = model.attachmentVisit(yard: yard, with: with)
                            showCamera = cameraVisit != nil
                        }
                    }
                    Button("Photos") { showGallery = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20))
                        .foregroundStyle(ThemeColor.textPrimary.color)
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Attach a picture")
                Spacer(minLength: 0)
                Button {
                    Task { await model.send() }
                } label: {
                    sendArrowGlyph(dim: nothingToSend)
                }
                .buttonStyle(SendArrowStyle(dim: nothingToSend))
                .disabled(nothingToSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(ThemeColor.surfaceRaised.color, in: box)
        .overlay { box.strokeBorder(ThemeColor.borderStrong.color, lineWidth: 1) }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The two fixed glyph layers avoid reconfiguring a system symbol as
    /// the arrow changes between its disabled and sendable states.
    private func sendArrowGlyph(dim: Bool) -> some View {
        ZStack {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ThemeColor.textDisabled.color)
                .opacity(dim ? 1 : 0)
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ThemeColor.textOnAccent.color)
                .opacity(dim ? 0 : 1)
        }
        .accessibilityHidden(true)
    }

    /// The pictures picked for the letter, in the order they were picked:
    /// a row of thumbnails that scrolls sideways, each with its own cross.
    private func attachedRow(_ attached: [Attached]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attached, id: \.id) { picture in
                    attachedThumb(picture)
                }
            }
            // Inside the composer's box: the first thumbnail stands on the
            // field's own inset.
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
    }

    /// One picked picture's thumbnail with the cross that takes it back,
    /// over its corner. The cross is drawn small, on a solid dot of the
    /// app's ground that the thumbnail holds whole (so it shows on any
    /// picture, light or dark), while its button keeps the 48 point target;
    /// the thumbnail takes no tap of its own.
    private func attachedThumb(_ attached: Attached) -> some View {
        ZStack(alignment: .topTrailing) {
            if let decoded = attached.bytes.isEmpty ? nil : UIImage(data: attached.bytes) {
                Image(uiImage: decoded)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(attached.name)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeColor.surfaceSunken.color)
                    .frame(width: 64, height: 64)
                    .overlay {
                        Text(attached.name)
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                            .lineLimit(2)
                            .padding(4)
                    }
            }
            Button {
                model.removeAttach(id: attached.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .frame(width: 24, height: 24)
                    .background(ThemeColor.surfaceApp.color, in: Circle())
                    .padding(4)
                    .frame(width: 48, height: 48, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attached.name)")
        }
        .frame(width: 64, height: 64)
    }

    /// The person's own letter is a bubble on the right, kept 60 points
    /// from the left; any other (the crew's, the yard's notices) is
    /// drawn the width of the conversation on no surface.
    private func letterBubble(_ letter: Shown, beads: Set<String>) -> some View {
        let bubble = RoundedRectangle(cornerRadius: 8)
        return VStack(alignment: letter.mine ? .trailing : .leading, spacing: letter.mine ? 2 : 6) {
            VStack(alignment: .leading, spacing: 4) {
                if let copy = copyableMessage(letter) {
                    // Equatable, so a letter whose words and beads are
                    // unchanged is not read into blocks again when
                    // another letter arrives or the draft moves
                    // (footplate-ios-g0jx).
                    MessageText(text: letter.text, beads: beads)
                        .equatable()
                        .environment(\.openURL, letterLinks)
                        .contextMenu {
                            Button("Copy message") {
                                UIPasteboard.general.string = copy
                            }
                        }
                }
                ForEach(letter.images, id: \.hash) { image in
                    pictureRow(image, textAbove: !letter.text.isEmpty)
                }
                if let files = letter.files {
                    Text(files)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
            }
            .frame(maxWidth: letter.mine ? nil : .infinity, alignment: .leading)
            .padding(.horizontal, letter.mine ? 12 : 0)
            .padding(.vertical, letter.mine ? 8 : 0)
            .background(letter.mine ? ThemeColor.surfaceRaised.color : Color.clear, in: bubble)
            .overlay { if letter.mine { bubble.strokeBorder(ThemeColor.borderSubtle.color, lineWidth: 1) } }
            if !letter.time.isEmpty {
                Text(letter.time)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .padding(.horizontal, letter.mine ? 12 : 0)
            }
        }
        .padding(.leading, letter.mine ? 60 : 0)
        .frame(maxWidth: .infinity, alignment: letter.mine ? .trailing : .leading)
    }

    /// One image of a letter under its text, at the
    /// conversation's width; a tap opens it full. A placeholder
    /// box while asked for, and with the file's name where
    /// missed.
    private func pictureRow(_ image: ShownImage, textAbove: Bool) -> some View {
        let decoded = image.bytes.flatMap { UIImage(data: $0) }
        return Group {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { model.openPicture(image.hash) }
                    .accessibilityLabel(image.name.isEmpty ? "Picture" : image.name)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeColor.surfaceSunken.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .overlay {
                        // Asked and answered with nothing (or with
                        // bytes no picture): the file's name. While
                        // asked for, the box alone.
                        if image.missed || image.bytes != nil {
                            Text(image.name.isEmpty ? "Picture" : image.name)
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textSecondary.color)
                                .padding(.horizontal, 12)
                        }
                    }
            }
        }
        .padding(.top, textAbove ? 8 : 0)
    }
}

/// The composer's round arrow that sends: the primary button's fill and
/// its pressed one in a circle of 40 points; `dim` (nothing to send) is a
/// grey circle, the grey one step past the hover's so that it shows on the
/// box in the dark too. The glyph is sized and coloured on the label; the
/// style draws the circle. Its target is 48 points, yardr-design's Phone
/// size, as every other control here.
private struct SendArrowStyle: ButtonStyle {
    var dim: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 40, height: 40)
            .background(
                dim
                    ? ThemeColor.surfacePressed.color
                    : (configuration.isPressed ? ThemeColor.buttonPrimaryPressed.color : ThemeColor.buttonPrimary.color),
                in: Circle()
            )
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
    }
}

/// One picture full screen, over the conversation or, as a note's
/// opens it, over the screen: pinch to zoom, a tap shuts it. A pager
/// around it, a bead's Media, has the swipe while the picture is at its
/// own size and `zoomed` says when it is not.
struct FullPicture: View {
    var image: ShownImage
    var zoomed: Binding<Bool> = .constant(false)
    var onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            ThemeColor.surfaceApp.color.ignoresSafeArea()
            if let decoded = image.bytes.flatMap({ UIImage(data: $0) }) {
                Image(uiImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in scale = min(6, max(1, value.magnification)) }
                            .onEnded { _ in if scale == 1 { offset = .zero } }
                    )
                    // The drag pans a picture zoomed in; at its own size
                    // it is left out, so it cannot take a pager's swipe.
                    .simultaneousGesture(
                        DragGesture().onChanged { value in offset = value.translation },
                        including: scale > 1 ? .all : .subviews
                    )
                    .onChange(of: scale) { _, scale in zoomed.wrappedValue = scale > 1 }
                    .accessibilityLabel(image.name.isEmpty ? "Picture" : image.name)
            } else {
                Text(image.name.isEmpty ? "Picture" : image.name)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .padding(24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
    }
}

/// The camera, drawn by the system: its picture's JPEG bytes,
/// or nil where the person backed out. The system draws it, so
/// the app holds no capture pipeline of its own.
private struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onPick(image?.jpegData(compressionQuality: 0.95))
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onPick(nil)
            parent.dismiss()
        }
    }
}
