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
// text, opened full on tap; the field and Send, with
// a picture picked from the gallery or the camera above it.
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var field: String = ""
    @State private var scrollTracking = ConversationScrollTracking()
    @State private var showGallery = false
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var showCamera = false

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
                    // The picture picked for the letter, above the
                    // field, taken back with the cross; while it
                    // shrinks, the word for it.
                    if let attached = state.attached {
                        attachedRow(attached)
                    }
                    if state.attaching {
                        Text("Shrinking the picture…")
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 4)
                    }
                    // Attach, the field and Send in one row, or the
                    // field's row above a full-width Send where the
                    // text is set to an accessibility size, as the
                    // bead card stacks its buttons: a fixed-width Send
                    // cannot hold its label grown that large.
                    let attach = Menu {
                        Button("Gallery") { showGallery = true }
                        if canPhoto {
                            Button("Camera") { showCamera = true }
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18))
                            .foregroundStyle(ThemeColor.textPrimary.color)
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Attach a picture")
                    let write = TextField("Write back", text: $field, axis: .vertical)
                        .lineLimit(1...5)
                        .accessibilityIdentifier("conversation-field")
                        .themeType(.body)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 48)
                        .background(ThemeColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ThemeColor.borderStrong.color, lineWidth: 1) }
                        .onChange(of: field) { _, text in
                            if text != model.draftText { model.draft(text) }
                        }
                        .onChange(of: state.draft) { _, draft in
                            if draft.isEmpty { field = "" }
                        }
                    let send = Button("Send") {
                        Task { await model.send() }
                    }
                    .buttonStyle(FootplateButtonStyle(primary: true))
                    .disabled((field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.attached == nil) || state.sending || state.attaching)
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .center, spacing: 8) {
                                    attach
                                    write
                                }
                                send
                            }
                        } else {
                            HStack(alignment: .center, spacing: 8) {
                                attach
                                write
                                send.frame(width: 96)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
        .photosPicker(isPresented: $showGallery, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.attach(bytes: data, name: "photo", yard: yard, with: with)
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in
                if let data { model.attach(bytes: data, name: "photo.jpg", yard: yard, with: with) }
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

    /// The picture picked for the letter: its thumbnail, its
    /// name, and the cross that takes it back.
    private func attachedRow(_ attached: Attached) -> some View {
        HStack(spacing: 12) {
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
            Text(attached.name)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .lineLimit(1)
            Spacer()
            Button {
                model.removeAttach()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove the picture")
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
        .padding(.top, 8)
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
