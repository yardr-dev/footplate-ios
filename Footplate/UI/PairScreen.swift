import SwiftUI

// Pair with a yard, design 3.2: Scan and Type the code; after a
// scan, what was read as three rows and Pair; a refusal in the
// error colour under the button. Type the code shows the address as
// a line of text, the build's edge, with a quiet choice for a yard's
// own address, which opens the address field and hides the yard's.
struct PairScreen: View {
    @Bindable var model: PairModel
    var scannerAvailable: Bool = ScannerAvailability.isAvailable
    var canGoBack: Bool = false
    var onBack: (() -> Void)? = nil
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.state.step != .choose || canGoBack, let onBack {
                    Button("Back", action: onBack)
                        .themeType(.label)
                        .foregroundStyle(ThemeColor.textAccent.color)
                        .frame(minHeight: 48, alignment: .leading)
                }
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
                (Text("Pair this phone with a yard. Its operator opens a code with ")
                    + Text("yardr user device pair").font(ThemeType.code.font))
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                content
                if let error = model.state.error {
                    Text(error)
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textError.color)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .foregroundStyle(ThemeColor.textPrimary.color)
        .background(ThemeColor.surfaceApp.color.ignoresSafeArea())
        .fullScreenCover(isPresented: $scanning) {
            ZStack(alignment: .topTrailing) {
                ScannerView { text in
                    scanning = false
                    model.scanned(text)
                }
                .ignoresSafeArea()
                Button("Close") {
                    scanning = false
                    model.scanFailed(nil)
                }
                .buttonStyle(FootplateButtonStyle(primary: false))
                .frame(width: 120)
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state.step {
        case .choose:
            VStack(spacing: 12) {
                if !scannerAvailable {
                    Text(ScannerAvailability.unavailableLine)
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Scan") {
                    if scannerAvailable {
                        scanning = true
                    } else {
                        model.scanFailed(ScannerAvailability.unavailableLine)
                    }
                }
                .buttonStyle(FootplateButtonStyle(primary: true))
                Button("Type the code") { model.typeCode() }
                    .buttonStyle(FootplateButtonStyle(primary: false))
            }
        case .typing(let yard, let code, let address):
            VStack(alignment: .leading, spacing: 12) {
                // The build's edge, with the quiet choice beside it; a
                // yard's own address opens its field instead, and the
                // yard's field is hidden: no yard's name is needed then.
                if let own = address {
                    TextField("address", text: Binding(
                        get: { own },
                        set: { model.addressed($0) }
                    ))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .themeType(.body)
                    .fieldBox()
                    Text("The yard's own https address")
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                    Button("Use the default address") { model.addressed(nil) }
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textAccent.color)
                } else {
                    HStack(alignment: .center) {
                        FieldRow(label: "address", value: model.edge)
                        Button("Use your own address") { model.addressed("") }
                            .themeType(.meta)
                            .foregroundStyle(ThemeColor.textAccent.color)
                    }
                    TextField("yard", text: Binding(
                        get: { yard },
                        set: { model.typed(yard: $0, code: code) }
                    ))
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .themeType(.body)
                    .fieldBox()
                    Text("Empty for the account's own yard")
                        .themeType(.meta)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                }
                TextField("code", text: Binding(
                    get: { code },
                    set: { model.typed(yard: yard, code: $0) }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .themeType(.code)
                .fieldBox()
                .onSubmit { model.readTyped() }
                Button("Read") { model.readTyped() }
                    .buttonStyle(FootplateButtonStyle(primary: true))
                    .disabled(
                        code.trimmingCharacters(in: .whitespaces).isEmpty
                            || address?.trimmingCharacters(in: .whitespaces).isEmpty == true
                    )
            }
        case .read(let code):
            VStack(alignment: .leading, spacing: 0) {
                FieldRow(label: "address", value: code.address.isEmpty ? model.edge : code.address)
                if code.address.isEmpty {
                    FieldRow(label: "yard", value: code.yard.isEmpty ? "the account's own" : code.yard)
                }
                FieldRow(label: "code", value: code.code, mono: true)
                Button(model.state.busy ? "Pairing…" : "Pair") {
                    Task { await model.pair() }
                }
                .buttonStyle(FootplateButtonStyle(primary: true))
                .disabled(model.state.busy)
                .padding(.top, 20)
            }
        }
    }
}
