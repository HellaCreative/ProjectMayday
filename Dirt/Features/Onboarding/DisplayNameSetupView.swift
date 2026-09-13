import SwiftUI

/// Shown once, right after the first Apple sign-in, to capture a screen name
/// before the map loads.
struct DisplayNameSetupView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var name = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        (2...24).contains(trimmed.count)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(dirtHex: 0x0B0C0E), Color(dirtHex: 0x1A1408)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Spacer()

                Text("Pick your screen name")
                    .font(.dirtUI(26, weight: .heavy))
                    .foregroundStyle(.white)
                Text("This is how your crew sees you on the map and in group rides. You can change it later in Profile.")
                    .font(.dirtUI(13))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)

                TextField("", text: $name, prompt: Text("e.g. GravelGoblin").foregroundStyle(.white.opacity(0.35)))
                    .font(.dirtUI(18, weight: .bold))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { if isValid { Task { await save() } } }
                    .padding(14)
                    .background(.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    )

                HStack {
                    Text("\(trimmed.count)/24")
                        .font(.dirtMono(10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.dirtUI(11, weight: .semibold))
                            .foregroundStyle(DirtTheme.orange)
                    }
                }

                Button {
                    Task { await save() }
                } label: {
                    if busy {
                        ProgressView().tint(DirtTheme.onOrange).frame(maxWidth: .infinity)
                    } else {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(DirtCTAStyle.brand())
                .disabled(!isValid || busy)
                .padding(.top, 4)

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            name = app.supabase.displayName
            focused = true
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await app.supabase.updateDisplayName(trimmed)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save that name. Try again."
        }
    }
}
