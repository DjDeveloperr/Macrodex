import SwiftUI

struct ChatGPTLoginWallView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var isWorking = false
    @State private var authError: String?
    @State private var isRestartingLocalServer = false
    @State private var googleAPIKey = ""
    @State private var isSavingGoogleKey = false

    private var localServer: AppServerSnapshot? {
        appModel.snapshot?.servers.first(where: \.isLocal)
    }

    private var isLocalServerConnected: Bool {
        localServer?.isConnected == true
    }

    private var hasChatGPTAccount: Bool {
        if case .chatgpt? = localServer?.account {
            return true
        }
        return false
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("MacrodexAppIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 82, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Macrodex")
                        .font(.system(.largeTitle, design: .default, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Sign in with ChatGPT or add a Google AI key to use Macrodex on your iPhone")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await loginWithChatGPT() }
                } label: {
                    HStack(spacing: 10) {
                        if isWorking {
                            ProgressView()
                                .tint(buttonForeground)
                                .controlSize(.small)
                        }
                        Text(isWorking ? "Signing in..." : "Sign in with ChatGPT")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(buttonForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(buttonBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isWorking || !isLocalServerConnected)
                .opacity(isLocalServerConnected ? 1 : 0.45)
                .accessibilityLabel("Sign in with ChatGPT")

                VStack(spacing: 10) {
                    SecureField("Google AI API key", text: $googleAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())

                    Button {
                        Task { await saveGoogleKey() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSavingGoogleKey {
                                ProgressView()
                                    .tint(buttonForeground)
                                    .controlSize(.small)
                            }
                            Text(isSavingGoogleKey ? "Saving..." : "Use Google AI")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(buttonForeground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(buttonBackground.opacity(0.9), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingGoogleKey || !isLocalServerConnected || googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(isLocalServerConnected ? 1 : 0.45)
                    .accessibilityLabel("Use Google AI")
                }

                if let authError {
                    Text(authError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !isLocalServerConnected {
                    VStack(spacing: 8) {
                        Text("Starting agent...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(isRestartingLocalServer ? "Starting..." : "Retry") {
                            Task { await restartLocalServer() }
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .disabled(isRestartingLocalServer)
                    }
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 380)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .task(id: localServer?.serverId) {
            guard let localServer else { return }
            guard !hasChatGPTAccount else { return }
            do {
                _ = try await appModel.client.refreshAccount(
                    serverId: localServer.serverId,
                    params: AppRefreshAccountRequest(refreshToken: false)
                )
                await appModel.refreshSnapshot()
            } catch {
                // Keep the wall visible and let the explicit login action recover.
            }
        }
    }

    private var buttonBackground: Color {
        colorScheme == .dark ? .white : .black
    }

    private var buttonForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    private func loginWithChatGPT() async {
        guard let localServer else {
            authError = "The local agent server is not ready yet."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            authError = nil
            let tokens = try await ChatGPTOAuth.login()
            _ = try await appModel.client.loginAccount(
                serverId: localServer.serverId,
                params: .chatgptAuthTokens(
                    accessToken: tokens.accessToken,
                    chatgptAccountId: tokens.accountID,
                    chatgptPlanType: tokens.planType
                )
            )
            await appModel.refreshSnapshot()
        } catch ChatGPTOAuthError.cancelled {
            return
        } catch {
            authError = error.localizedDescription
        }
    }

    private func restartLocalServer() async {
        guard !isRestartingLocalServer else { return }
        isRestartingLocalServer = true
        defer { isRestartingLocalServer = false }

        do {
            authError = nil
            try await appModel.restartLocalServer()
        } catch {
            authError = error.localizedDescription
        }
    }

    private func saveGoogleKey() async {
        guard let localServer else {
            authError = "The local server is not ready yet."
            return
        }
        let trimmed = googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSavingGoogleKey = true
        defer { isSavingGoogleKey = false }

        do {
            authError = nil
            try GoogleAIApiKeyStore.shared.save(trimmed)
            _ = try await appModel.client.refreshAccount(
                serverId: localServer.serverId,
                params: AppRefreshAccountRequest(refreshToken: false)
            )
            googleAPIKey = ""
            await appModel.refreshSnapshot()
        } catch {
            authError = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview("Login Wall") {
    MacrodexPreviewScene(includeBackground: false) {
        ChatGPTLoginWallView()
    }
}
#endif
