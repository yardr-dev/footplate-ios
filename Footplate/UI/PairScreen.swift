import SwiftUI

struct PairScreen: View {
    private let edge = Bundle.main.object(forInfoDictionaryKey: "EDGE_URL") as? String ?? "https://my.yardr.dev"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image("YardrMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("yardr")
                    Text("footplate")
                        .themeType(.title)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(alignment: .leading, spacing: 8) {
                    (Text("Pair this phone with a yard. Its operator opens a code with ")
                        + Text("yardr user device pair").font(ThemeType.code.font))
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                    if edge != "https://my.yardr.dev" {
                        Text(URL(string: edge)?.host ?? edge)
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textSecondary.color)
                    }
                }
                VStack(spacing: 12) {
                    Button("Scan") {}
                        .buttonStyle(PairButtonStyle(primary: true))
                    Button("Type the code") {}
                        .buttonStyle(PairButtonStyle(primary: false))
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
    }
}

private struct PairButtonStyle: ButtonStyle {
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

#Preview("Dark") { PairScreen().preferredColorScheme(.dark) }
#Preview("Light") { PairScreen().preferredColorScheme(.light) }
