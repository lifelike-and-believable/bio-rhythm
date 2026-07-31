import SwiftUI
import HRDJCore
import SpotifyKit

/// The now-playing half of the §11.2 screen: title and artist, truncated.
///
/// Read-only, and deliberately so. Nothing here can pause, skip, or seek —
/// the manual transport controls of §11.2 arrive with the override work in M4,
/// and until then the watch cannot interrupt a track even by accident.
@MainActor
@Observable
final class NowPlayingModel {
    enum State: Equatable {
        case idle
        case loading
        case playing(title: String, artist: String)
        case nothingPlaying
        case needsOnboarding
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastRefreshed: Date?

    private let stack: SpotifyStack?
    private let configurationError: String?

    init(store: any TokenStore) {
        do {
            let configuration = try AppConfiguration.spotifyAuth()
            self.stack = SpotifyStack(configuration: configuration, store: store)
            self.configurationError = nil
        } catch {
            self.stack = nil
            self.configurationError = error.localizedDescription
        }
    }

    func refresh() async {
        if let configurationError {
            state = .failed(configurationError)
            return
        }
        guard let stack else { return }

        state = .loading
        do {
            let playback = try await stack.player.playbackState()
            lastRefreshed = Date()

            if let track = playback.track {
                state = .playing(title: track.title, artist: track.primaryArtist)
            } else {
                state = .nothingPlaying
            }
        } catch SpotifyError.notAuthenticated, SpotifyError.reauthorizationRequired {
            state = .needsOnboarding
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? SpotifyError else { return error.localizedDescription }
        switch error {
        case .forbidden:
            // §11.4 wants this one distinct: it usually means the Premium
            // subscription lapsed, and no amount of retrying will fix it.
            return "Spotify refused the request. Check that Premium is active."
        case .notFound:
            return "No active Spotify device."
        case .rateLimited:
            return "Rate limited by Spotify. Backing off."
        case .unauthorized:
            return "Authorization failed. Re-run onboarding on the phone."
        case .server(let status, _):
            return "Spotify error \(status)."
        case .transport:
            return "No network."
        default:
            return "Could not read playback state."
        }
    }
}

struct NowPlayingSection: View {
    @ObservedObject private var link: PhoneLink
    @State private var model: NowPlayingModel

    init(link: PhoneLink, store: any TokenStore) {
        _link = ObservedObject(wrappedValue: link)
        _model = State(initialValue: NowPlayingModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if link.hasToken {
                content
            } else {
                waitingForOnboarding
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard link.hasToken else { return }
            await model.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            Text("Reading playback…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .playing(let title, let artist):
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .nothingPlaying:
            Text("Nothing playing")
                .font(.headline)
            Text("Start a track anywhere and pull to refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsOnboarding:
            Text("Not connected")
                .font(.headline)
            Text("Open bio-rhythm on the phone and connect Spotify.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Button("Refresh") {
            Task { await model.refresh() }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var waitingForOnboarding: some View {
        Text("Waiting for the phone")
            .font(.headline)
        Text("Open bio-rhythm on the phone and connect Spotify. This happens once.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let error = link.lastError {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}
