import SwiftUI

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
/// underline. The asker's words on a decision, a bead's on its card, mail
/// in a conversation.
func linkedText(_ line: String, beads: Set<String> = []) -> Text {
    var words = linked(line, beads: beads)
    for run in words.runs {
        if let link = run.link, chippedBead(link) != nil {
            words[run.range].swiftUI.foregroundColor = ThemeColor.textAccent.color
            words[run.range].swiftUI.backgroundColor = ThemeColor.surfaceSunken.color
            words[run.range].swiftUI.font = chipFont()
        } else if run.link != nil {
            words[run.range].swiftUI.underlineStyle = .single
            words[run.range].swiftUI.foregroundColor = ThemeColor.textAccent.color
        }
    }
    return Text(words)
}

/// A chip's face: Plex Mono at the body's size, scaled with the system's
/// text size.
private func chipFont() -> Font {
    Font.custom(ThemeType.code.face, size: ThemeType.body.size, relativeTo: ThemeType.body.textStyle)
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
