import SwiftUI
import SpotifyKit

@MainActor
@Observable
final class OnboardingModel {
    enum Stage: Equatable {
        case ready
        case authorizing
        case sending
        case done
        case failed(String)
    }

    private(set) var stage: Stage = .ready
    private let link: WatchLink

    init(link: WatchLink) {
        self.link = link
    }

    func authorizeAndSend() async {
        stage = .authorizing
        do {
            let configuration = try AppConfiguration.spotifyAuth()
            let service = SpotifyAuthorizationService(configuration: configuration)
            let grant = try await service.authorize()

            guard let refreshToken = grant.refreshToken else {
                // Without one the watch cannot refresh on its own, which is
                // the entire point of the phone step (G3).
                stage = .failed("Spotify returned no refresh token. Re-run authorization.")
                return
            }

            stage = .sending
            try link.send(refreshToken: refreshToken)
            stage = .done
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}

struct OnboardingView: View {
    @State private var model: OnboardingModel
    @ObservedObject private var link: WatchLink

    init(link: WatchLink) {
        _link = ObservedObject(wrappedValue: link)
        _model = State(initialValue: OnboardingModel(link: link))
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("bio-rhythm")
                    .font(.largeTitle.weight(.semibold))
                Text("Connect Spotify once. The watch handles the rest.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            status

            Button {
                Task { await model.authorizeAndSend() }
            } label: {
                Text(isBusy ? "Working…" : "Connect Spotify")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)

            if link.pendingTransfers > 0 {
                Text("Waiting for the watch to pick it up (\(link.pendingTransfers) queued). It can stay in the background.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(24)
    }

    private var isBusy: Bool {
        model.stage == .authorizing || model.stage == .sending
    }

    @ViewBuilder
    private var status: some View {
        switch model.stage {
        case .ready:
            Label("Premium required — playback control has always needed it.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .authorizing:
            ProgressView("Authorizing…")
        case .sending:
            ProgressView("Sending to watch…")
        case .done:
            Label("Sent. Open bio-rhythm on the watch.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }
}
