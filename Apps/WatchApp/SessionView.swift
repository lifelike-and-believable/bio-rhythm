import SwiftUI
import HRDJCore
import SpotifyKit

/// SPEC.md §11.2 — two horizontally-paged screens.
///
/// **The glance page does not scroll**, so the Digital Crown can be the zone
/// lock; it cannot be both that and the scroll gesture. Horizontal paging is
/// what frees it — *vertical* paging would consume the Crown in turn.
///
/// **The controls page does scroll.** Neither reason for the rule applies
/// there: the Crown has no job on it, and nobody reads it mid-effort. It also
/// has to, since three buttons and a diagnostics block do not fit a 42 mm
/// screen.
///
/// The reorganisation earns its place beyond the Crown: every action now has a
/// labelled home on the controls page, which retires the two gestures nobody
/// could discover. The cost is that ending a workout is one swipe away rather
/// than immediate, which is exactly the idiom Apple's Workout app uses.
///
/// Present in M1: heart rate, the zone row with its override state, the
/// decision line, now playing, and the controls page. Absent because the
/// systems behind them do not exist yet: the committed next track, the
/// blocklist, the activity picker and visible startup (both PR 2), and the
/// Always-On variant (PR 3).
struct SessionView: View {
    @ObservedObject private var link: PhoneLink
    @State private var coordinator: WorkoutCoordinator
    @State private var page: Page = .glance
    private let store: any TokenStore

    private enum Page: Hashable {
        case glance
        case controls
    }

    init(link: PhoneLink, store: any TokenStore, configuration: ControlConfiguration) {
        _link = ObservedObject(wrappedValue: link)
        _coordinator = State(initialValue: WorkoutCoordinator(configuration: configuration))
        self.store = store
    }

    var body: some View {
        TabView(selection: $page) {
            glance
                .tag(Page.glance)
            controls
                .tag(Page.controls)
        }
        .tabViewStyle(.page)
    }

    // MARK: - The glance page

    /// Read-only. That is what makes it the right thing to show in Always-On,
    /// and it is why nothing here can end the session by accident.
    @ViewBuilder
    private var glance: some View {
        VStack(alignment: .leading, spacing: 10) {
            heartRate

            ZoneRow(
                zone: coordinator.zone,
                pendingZone: coordinator.pendingZone,
                isOverridden: coordinator.isOverridden,
                overrideRemaining: coordinator.overrideRemaining,
                overrideCause: coordinator.overrideCause?.label,
                onLock: { coordinator.lockZone($0) },
                onResume: { coordinator.resumeAuto() }
            )

            decisionLine

            if coordinator.state == .idle {
                startButton
            } else {
                Divider()
                NowPlayingSection(link: link, store: store)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// §11.2's decision line: one row that always says something.
    ///
    /// It replaced two elements — "next committed track / deciding / warning"
    /// and the HR-window diagnostics — because as separate fields the first was
    /// empty for roughly 90 % of every track and the second was never glance
    /// content. The M2 states (`Next:`, `Missed`, `Offline`) arrive with the
    /// controller; M1 has no commits, so it carries the observation states only.
    @ViewBuilder
    private var decisionLine: some View {
        Group {
            switch coordinator.state {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .paused:
                Text("Workout paused")
                    .foregroundStyle(.secondary)
            case .idle:
                Text("Ready")
                    .foregroundStyle(.secondary)
            case .starting:
                Text("Starting…")
                    .foregroundStyle(.secondary)
            case .running:
                if coordinator.isStale {
                    // §6.2 in the one place the owner can see it: the zone is
                    // being held, not recomputed, until samples come back.
                    Text("No samples — holding zone")
                        .foregroundStyle(.orange)
                } else if let pending = coordinator.pendingZone {
                    // §6.4's dwell, made visible. Without this the screen is
                    // silent for twenty seconds while the system is in fact
                    // deciding, which reads as nothing happening.
                    Text("Settling → \(pending.label)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Observing")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption2)
        .lineLimit(2)
    }

    @ViewBuilder
    private var startButton: some View {
        Button("Start workout") {
            Task { await coordinator.start() }
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - The controls page

    /// Everything that acts, and the diagnostics that are not glance content.
    ///
    /// This page is why the two undiscoverable gestures in §11.2's first draft
    /// could be retired: blocklisting and "resume auto" have labels here, so
    /// neither depends on a long-press nobody would find.
    @ViewBuilder
    private var controls: some View {
        ScrollView {
            VStack(spacing: 10) {
                if coordinator.state == .idle {
                    Text("No session running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("End workout", role: .destructive) {
                        Task { await coordinator.stop() }
                    }

                    Button("Resume auto") {
                        coordinator.resumeAuto()
                    }
                    .disabled(!coordinator.isOverridden)

                    // R-11. Needs the pools that arrive with M3, so it is
                    // present and inert rather than absent — the layout it
                    // sits in is what PR 2 and PR 3 are built against.
                    Button("Block this track") {}
                        .disabled(true)

                    diagnostics
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let mean = coordinator.observedHR {
                Text("mean \(Int(mean.rounded())) bpm")
            }
            Text("\(coordinator.sampleCount) samples in window")
            if let remaining = ZoneRow.coarse(coordinator.overrideRemaining) {
                Text("override \(remaining)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}
