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
