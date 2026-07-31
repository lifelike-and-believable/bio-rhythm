import SwiftUI
import HRDJCore

/// The zone indicator, and — per §11.2 — the override indicator too.
///
/// One discrete step per zone, never a gauge: the system is discrete and the UI
/// must not imply otherwise. Driven off `Zone.allCases`, so the meditation zone
/// appears without a change here.
///
/// ## It is also the override indicator, and the button
///
/// §6.6 wants an unambiguous override indicator with remaining time and a
/// "resume auto" action. It is not a separate element. The thing being
/// overridden *is* the zone, so this row restyles — outlined capsule, lock
/// glyph, cause and coarse countdown on the label — and tapping it clears the
/// hold. Nothing on screen changes size or position when an override begins or
/// ends, which is the point: a row that appears and displaces everything below
/// it is worse than one that simply looks different.
///
/// ## The Crown is focus-gated, deliberately
///
/// An always-live Crown that pins a zone and starts a three-minute hold is a
/// hazard — watches get knocked, sleeves catch. `digitalCrownRotation` only
/// delivers to a focused view, so the platform supplies the safety: the row
/// does nothing until it is tapped into focus.
struct ZoneRow: View {
    let zone: Zone?
    let pendingZone: Zone?
    let isOverridden: Bool
    let overrideRemaining: Duration?
    let overrideCause: String?
    let onLock: @MainActor (Zone) -> Void
    let onResume: @MainActor () -> Void

    @State private var isFocused = false
    @State private var crownPosition: Double = 0
    @FocusState private var crownFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            capsules
            label
        }
        .contentShape(Rectangle())
        .focusable(zone != nil)
        .focused($crownFocus)
        .digitalCrownRotation(
            $crownPosition,
            from: 0,
            through: Double(Zone.allCases.count - 1),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownPosition) { _, new in
            guard crownFocus, let picked = Zone(rawValue: Int(new.rounded())) else { return }
            guard picked != zone else { return }
            onLock(picked)
        }
        .onChange(of: crownFocus) { _, focused in
            isFocused = focused
            // Seed the crown at the current zone so the first notch moves one
            // step from where the owner already is, not from zero.
            if focused, let zone { crownPosition = Double(zone.rawValue) }
        }
        .onTapGesture {
            if isOverridden {
                onResume()
            } else {
                crownFocus = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var capsules: some View {
        HStack(spacing: 4) {
            ForEach(Zone.allCases, id: \.self) { candidate in
                Capsule()
                    .strokeBorder(
                        candidate == zone && isOverridden ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
                    .background(Capsule().fill(fill(for: candidate)))
                    .frame(height: isFocused ? 8 : 6)
            }
        }
        .animation(nil, value: zone)
    }

    /// Outlined when overridden, filled when the system chose it. That is the
    /// whole distinction §6.6 calls "unambiguous", and it is carried by the
    /// same pixels either way.
    private func fill(for candidate: Zone) -> Color {
        guard candidate == zone else {
            return candidate == pendingZone
                ? Color.accentColor.opacity(0.25)
                : Color.gray.opacity(0.3)
        }
        return isOverridden ? .clear : .accentColor
    }

    @ViewBuilder
    private var label: some View {
        HStack(spacing: 4) {
            Text(zone?.label ?? "—")
                .font(.caption2)
                .foregroundStyle(zone == nil ? .tertiary : .secondary)

            if isOverridden {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                if let overrideCause {
                    Text(overrideCause)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let countdown = Self.coarse(overrideRemaining) {
                    Text(countdown)
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.7))
                }
            }
        }
        .lineLimit(1)
    }

    /// §11.2's coarse countdown: four updates across a three-minute hold rather
    /// than 180.
    ///
    /// Not primarily a battery decision — heart rate already redraws at roughly
    /// 1 Hz while the screen is on. A ticking second hand pulls the eye during
    /// effort, and the only question it is ever asked is "is this nearly over?",
    /// which does not need second precision.
    static func coarse(_ remaining: Duration?) -> String? {
        guard let remaining, remaining > .zero else { return nil }
        let minutes = Int(remaining.inSeconds / 60)
        return minutes >= 1 ? "~\(minutes) min" : "under a minute"
    }

    private var accessibilityText: String {
        var parts = [zone?.label ?? "No zone"]
        if isOverridden {
            parts.append("locked")
            if let overrideCause { parts.append(overrideCause) }
            if let countdown = Self.coarse(overrideRemaining) { parts.append(countdown) }
            parts.append("double tap to resume automatic control")
        } else {
            parts.append("double tap to choose a zone with the crown")
        }
        return parts.joined(separator: ", ")
    }
}
