import SwiftUI
import HRDJCore
import SpotifyKit

/// The M1 screen. SPEC.md §11.2, as much of it as M1 has anything to put in.
///
/// Present: heart rate large, the five zones as a discrete indicator, now
/// playing. Absent because the systems behind them do not exist yet: the next
/// committed track, the override countdown, the blocklist long-press, the
/// Digital Crown zone lock.
///
/// §11.2: no animations that run continuously. A workout screen that spins
/// something for thirty minutes is a workout screen that costs battery for
/// decoration, so the loading states here are text.
struct SessionView: View {
    @ObservedObject private var link: PhoneLink
    @State private var coordinator: WorkoutCoordinator
    private let store: any TokenStore

    init(link: PhoneLink, store: any TokenStore, configuration: ControlConfiguration) {
        _link = ObservedObject(wrappedValue: link)
        _coordinator = State(initialValue: WorkoutCoordinator(configuration: configuration))
        self.store = store
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                heartRate
                ZoneIndicator(zone: coordinator.zone)
                detail
                control

                Divider()

                NowPlayingSection(link: link, store: store)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("bio-rhythm")
    }

    @ViewBuilder
    private var heartRate: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(coordinator.instantaneousBPM.map(String.init) ?? "––")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                // Stale means the number on screen is the last one that
                // arrived, not the current one. Saying so is cheaper than
                // letting the owner trust a frozen figure.
                .foregroundStyle(coordinator.isStale ? .secondary : .primary)
            Text("bpm")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch coordinator.state {
        case .failed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.orange)
        case .paused:
            Text("Workout paused")
                .font(.caption2)
                .foregroundStyle(.secondary)
        default:
            if coordinator.isStale, coordinator.state == .running {
                // §6.2 in the one place the owner can see it: the zone is being
                // held, not recomputed, until samples come back.
                Text("No recent samples — holding zone")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let mean = coordinator.observedHR {
                Text("mean \(Int(mean.rounded())) over \(coordinator.sampleCount) samples")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch coordinator.state {
        case .running, .paused:
            Button("End workout", role: .destructive) {
                Task { await coordinator.stop() }
            }
        case .starting:
            Text("Starting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .idle, .failed:
            Button("Start workout") {
                Task { await coordinator.start() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One discrete step per zone, never a gauge. §11.2 is explicit about this: the
/// system is discrete and a continuous bar would imply a resolution the
/// actuator does not have.
///
/// Driven off `Zone.allCases`, so the meditation zone appears here without a
/// change. On a 41 mm watch five capsules is still legible; if a sixth zone is
/// ever added this wants revisiting rather than another divide.
struct ZoneIndicator: View {
    let zone: Zone?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Zone.allCases, id: \.self) { candidate in
                Capsule()
                    .fill(candidate == zone ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(height: 6)
                    .accessibilityLabel(candidate.label)
            }
        }
        .overlay(alignment: .leading) {
            Text(zone?.label ?? "—")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: 14)
        }
        .padding(.bottom, 14)
    }
}
