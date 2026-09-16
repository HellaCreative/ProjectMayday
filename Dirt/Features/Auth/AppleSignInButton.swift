import AuthenticationServices
import CryptoKit
import SwiftUI

/// One-tap "Sign in with Apple" wired to Supabase. Owns nonce generation so the
/// caller only receives the verified identity token + name components.
struct AppleSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    var onFinished: (Result<AppleCredential, Error>) -> Void

    @State private var currentNonce = AppleNonce.random()

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            currentNonce = AppleNonce.random()
            request.requestedScopes = [.fullName]
            request.nonce = AppleNonce.sha256(currentNonce)
        } onCompletion: { result in
            switch result {
            case let .success(authorization):
                guard
                    let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                    let tokenData = credential.identityToken,
                    let idToken = String(data: tokenData, encoding: .utf8)
                else {
                    onFinished(.failure(AppleSignInError.missingToken))
                    return
                }
                onFinished(.success(AppleCredential(
                    idToken: idToken,
                    rawNonce: currentNonce,
                    fullName: credential.fullName
                )))
            case let .failure(error):
                onFinished(.failure(error))
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AppleCredential {
    let idToken: String
    let rawNonce: String
    let fullName: PersonNameComponents?
}

enum AppleSignInError: LocalizedError {
    case missingToken

    var errorDescription: String? {
        "Apple did not return a sign-in token. Try again."
    }
}

/// Shared presentation policy for every Sign in with Apple entry point.
/// Cancellation is intentional and should stay silent; real failures must not
/// be swallowed because Groups and Profile may be the rider's only sign-in UI.
enum AppleSignInFailure {
    static func message(from error: Error) -> String? {
        if let authError = error as? ASAuthorizationError,
           authError.code == .canceled {
            return nil
        }
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty || detail == "The operation couldn’t be completed." {
            return "Sign-in couldn't be completed. Please try again."
        }
        return detail
    }
}

/// Nonce utilities for Sign in with Apple (raw value sent to Supabase, SHA-256
/// sent to Apple).
enum AppleNonce {
    static func random(_ length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status != errSecSuccess { random = UInt8.random(in: 0...255) }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
