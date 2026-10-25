import SwiftUI
import UIKit

// Phone roles from yardr-design/tokens/typography.css. Keep the bundled face
// while allowing the system's Dynamic Type size to scale both type and leading.
enum ThemeType: String, CaseIterable {
    case title, section, label, body, meta, code

    var face: String {
        switch self {
        case .title, .section: "IBMPlexSans-SemiBold"
        case .label: "IBMPlexSans-Medium"
        case .body, .meta: "IBMPlexSans-Regular"
        case .code: "IBMPlexMono-Regular"
        }
    }

    var size: CGFloat {
        switch self {
        case .title: 20
        case .section, .body: 16
        case .label, .code: 14
        case .meta: 13
        }
    }

    var leading: CGFloat {
        switch self {
        case .title: 28
        case .section, .body: 24
        case .label, .code: 20
        case .meta: 18
        }
    }

    var weight: Int {
        switch self {
        case .title, .section: 600
        case .label: 500
        default: 400
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .title: .title3
        case .section: .headline
        case .label: .subheadline
        case .body: .body
        case .meta: .caption
        case .code: .callout
        }
    }

    var font: Font { .custom(face, size: size, relativeTo: textStyle) }
}

private struct ThemeTypeModifier: ViewModifier {
    let role: ThemeType
    @ScaledMetric private var extraLeading: CGFloat

    init(role: ThemeType) {
        self.role = role
        _extraLeading = ScaledMetric(wrappedValue: max(0, role.leading - (UIFont(name: role.face, size: role.size)?.lineHeight ?? role.size)), relativeTo: role.textStyle)
    }

    func body(content: Content) -> some View {
        content.font(role.font).lineSpacing(extraLeading)
    }
}

extension View {
    func themeType(_ role: ThemeType) -> some View {
        modifier(ThemeTypeModifier(role: role))
    }
}
