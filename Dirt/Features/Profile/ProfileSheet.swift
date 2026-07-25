import Combine
import SwiftUI

/// Account sheet — email OTP sign-in exactly like the web flow, then display
/// name editing and sign out.
struct ProfileSheet: View {
    @Environment(AppEnvironment.self) private var app
    @State private var email = ""
    @State private var displayName = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var resendAvailableAt = Date.distantPast
    @State private var busy = false
    @State private var message: String?
    @State private var now = Date()

    private var supabase: SupabaseService { app.supabase }

    var body: some View {
        NavigationStack {
            Form {
                if supabase.isSignedIn {
                    signedIn
                } else if codeSent {
                    codeEntry
                } else {
                    emailEntry
                }
                if let message {
                    Section {
                        Text(message)
                            .font(.dirtUI(12, weight: .semibold))
                            .foregroundStyle(DirtTheme.danger)
                    }
                }
                if let bootstrapError = supabase.bootstrapError {
                    Section {
                        Text(bootstrapError)
                            .font(.dirtUI(12))
                            .foregroundStyle(DirtTheme.danger)
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { displayName = supabase.displayName }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
                now = date
            }
        }
    }

    @ViewBuilder private var emailEntry: some View {
        Section("Sign in") {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Display name (optional)", text: $displayName)
        }
        Section {
            Button {
                Task { await sendCode() }
            } label: {
                if busy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Email me a code").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(DirtCTAStyle(fill: DirtTheme.orange))
            .listRowBackground(Color.clear)
            .disabled(busy || !email.contains("@"))
        }
    }

    @ViewBuilder private var codeEntry: some View {
        Section("Check your email") {
            Text("We sent a sign-in code to \(email).")
                .font(.dirtUI(13))
                .foregroundStyle(DirtTheme.muted)
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .font(.dirtMono(18, weight: .bold))
        }
        Section {
            Button {
                Task { await verify() }
            } label: {
                if busy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Verify code").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(DirtCTAStyle(fill: DirtTheme.orange))
            .listRowBackground(Color.clear)
            .disabled(busy || code.count < 6)

            let secondsLeft = Int(max(0, resendAvailableAt.timeIntervalSince(now)))
            Button(secondsLeft > 0 ? "Resend code in \(secondsLeft)s" : "Resend code") {
                Task { await sendCode() }
            }
            .disabled(secondsLeft > 0 || busy)
            Button("Use a different email") {
                codeSent = false
                code = ""
            }
        }
    }

    @ViewBuilder private var signedIn: some View {
        Section("Account") {
            LabeledContent("Email", value: supabase.email ?? "—")
            TextField("Display name", text: $displayName)
        }
        Section {
            Button("Save display name") {
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        try await supabase.updateDisplayName(displayName)
                        message = nil
                        app.planner.toast = "Profile updated"
                    } catch {
                        message = "Your profile could not be updated."
                    }
                }
            }
            .buttonStyle(DirtCTAStyle(fill: DirtTheme.orange))
            .listRowBackground(Color.clear)
            .disabled(busy)

            Button("Sign out", role: .destructive) {
                Task { try? await supabase.signOut() }
            }
        }
    }

    private func sendCode() async {
        busy = true
        defer { busy = false }
        do {
            try await supabase.sendEmailCode(email: email, displayName: displayName)
            codeSent = true
            message = nil
            resendAvailableAt = Date().addingTimeInterval(60)
        } catch {
            message = "The code could not be sent. Check the address and try again."
        }
    }

    private func verify() async {
        busy = true
        defer { busy = false }
        do {
            try await supabase.verifyEmailCode(email: email, code: code.trimmingCharacters(in: .whitespaces))
            message = nil
            code = ""
            codeSent = false
            if !displayName.isEmpty {
                try? await supabase.updateDisplayName(displayName)
            }
        } catch {
            message = "That code did not match. Request a fresh one and try again."
        }
    }
}
