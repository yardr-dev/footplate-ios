import SwiftUI
import UIKit

// The controls the screens share, in yardr's tokens on SwiftUI's
// shapes: 48-point targets (yardr-design's Phone section), radius 6.

struct FootplateButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .themeType(.label)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .foregroundStyle(primary ? ThemeColor.textOnAccent.color : ThemeColor.textPrimary.color)
            .background(
                primary
                    ? (configuration.isPressed ? ThemeColor.buttonPrimaryPressed.color : ThemeColor.buttonPrimary.color)
                    : (configuration.isPressed ? ThemeColor.surfacePressed.color : ThemeColor.surfaceApp.color),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(ThemeColor.borderStrong.color, lineWidth: 1)
                }
            }
    }
}

extension View {
    /// The box of a text field: 48 points high, a raised surface and a
    /// strong hairline, radius 6.
    func fieldBox() -> some View {
        padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(ThemeColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ThemeColor.borderStrong.color, lineWidth: 1) }
    }
}

/// A sentence the person is told once, with its dismissal: over the
/// places and the Pair screen.
struct NoticeRow: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(text)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: onDismiss)
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textAccent.color)
                .frame(minWidth: 48, minHeight: 48)
                .contentShape(Rectangle())
        }
    }
}

/// A line of someone's words: the web addresses in it are links that
/// the system opens, underlined and in the accent, so no colour alone
/// says what is a link; the bead ids of `beads` are chips that open the
/// bead whole, in the accent on the sunken surface, in mono, with no
/// underline. A decision's question; every longer prose draws through
/// `MessageText`.
func linkedText(_ line: String, beads: Set<String> = []) -> Text {
    var words = linked(line, beads: beads)
    styleLinks(&words)
    return Text(words)
}

/// Links in prose drawn through `MessageText`: a chip opens its bead
/// through `openBead`, and a web address opens as before.
@MainActor
func proseLinks(openBead: @escaping (String) -> Void) -> OpenURLAction {
    OpenURLAction { url in
        if let id = chippedBead(url) {
            openBead(id)
            return .handled
        }
        return .systemAction
    }
}

/// The links and the chips of `words` drawn as `linkedText` draws them.
func styleLinks(_ words: inout AttributedString) {
    for run in words.runs {
        if let link = run.link, chippedBead(link) != nil {
            words[run.range].swiftUI.foregroundColor = ThemeColor.textAccent.color
            words[run.range].swiftUI.backgroundColor = ThemeColor.surfaceSunken.color
            words[run.range].swiftUI.font = codeFont()
        } else if run.link != nil {
            words[run.range].swiftUI.underlineStyle = .single
            words[run.range].swiftUI.foregroundColor = ThemeColor.textAccent.color
        }
    }
}

/// The face of a chip and of code in a line of words: Plex Mono at the
/// size of `role`, the body's by default, scaled with the system's text
/// size.
func codeFont(in role: ThemeType = .body) -> Font {
    Font.custom(ThemeType.code.face, size: role.size, relativeTo: role.textStyle)
}

/// A label and its value, one row of what was read.
struct FieldRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .center) {
            Text(label)
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .themeType(mono ? .code : .label)
                .foregroundStyle(ThemeColor.textPrimary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// One note of a bead, on its card and in a decision's details: who
/// wrote it, when where the card says so, its words drawn as a
/// letter's are with their links and chips, selectable with a copy of
/// them as written, then the pictures and files it carries.
struct NoteRow: View {
    var note: CardNote
    var beads: Set<String> = []
    var openBead: (String) -> Void = { _ in }
    /// The bead card says when each note was written; a decision's
    /// details say whose alone.
    var showTime: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(note.author)
                    .themeType(.label)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                if showTime, !note.at.isEmpty {
                    Text(note.at)
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
            }
            MessageText(text: note.text, beads: beads)
                .environment(\.openURL, proseLinks(openBead: openBead))
                .textSelection(.enabled)
                .contextMenu {
                    if let copy = copyableProse(note.text) {
                        Button("Copy note") {
                            UIPasteboard.general.string = copy
                        }
                    }
                }
            if note.carriesFiles {
                NoteFiles(note: note)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a note carries, under its words on the bead card and in a
/// decision's details: each picture a thumbnail no higher than 240
/// points, as the desktop's, a tap opening it full screen; each page or
/// file one line by its name, nothing fetched for it. A box stands where
/// a picture is asked for, and the picture's name where the yard held
/// none.
struct NoteFiles: View {
    var note: CardNote
    @State private var full: ShownImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // By place, not by hash: a note may carry one file twice.
            ForEach(Array(note.images.enumerated()), id: \.offset) { _, image in
                thumbnail(image)
            }
            ForEach(Array(note.files.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .themeType(.meta)
                    .foregroundStyle(ThemeColor.textSecondary.color)
            }
        }
        .fullScreenCover(item: $full) { image in
            FullPicture(image: image) { full = nil }
        }
    }

    private func thumbnail(_ image: ShownImage) -> some View {
        let name = image.name.isEmpty ? "Picture" : image.name
        return Group {
            if let decoded = image.bytes.flatMap({ UIImage(data: $0) }) {
                Image(uiImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { full = image }
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the picture full size")
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeColor.surfaceSunken.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .overlay {
                        // Asked and answered with nothing (or with bytes
                        // no picture): the file's name. While asked for,
                        // the box alone.
                        if image.missed || image.bytes != nil {
                            Text(name)
                                .themeType(.meta)
                                .foregroundStyle(ThemeColor.textSecondary.color)
                                .padding(.horizontal, 12)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("note-picture")
    }
}

extension ShownImage: Identifiable {
    var id: String { hash }
}

extension CardNote {
    /// It carries a picture, a page or a file: `NoteFiles` has something
    /// to draw under its words.
    var carriesFiles: Bool { !images.isEmpty || !files.isEmpty }
}
