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
/// §6.6 wants an unambiguous override indicator and a "resume auto" action. It
/// is not a separate element. The thing being overridden *is* the zone, so this
/// row restyles — outlined capsule, lock glyph and cause on the label — and
/// tapping it clears the hold.
///
/// There is no countdown, because there is nothing to count: the hold no longer
/// expires. That deleted the five-second ticker that kept a countdown honest,
/// and with it a bug where the number froze whenever heart rate stopped
/// arriving. Nothing on screen changes size or position when an override begins or
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
    let overrideCause: String?
    /// Always-On. Renders the reduced-luminance variant and drops every
    /// interaction, because there are none to have: raising the wrist wakes
    /// the screen before a touch or a Crown turn can land.
    var isDimmed: Bool = false
    let onLock: @MainActor (Zone) -> Void
    let onResume: @MainActor () -> Void

    @State private var isFocused = false
    @State private var crownPosition: Double = 0
    @FocusState private var crownFocus: Bool

    var body: some View {
        if isDimmed {
            dimmed
        } else {
            interactive
        }
    }

    /// §11.2's Always-On zone: **the name in real type, and no capsules.**
    ///
    /// Five thin capsules with one filled in an accent colour is a good
    /// full-brightness affordance and a poor dim one. At reduced luminance and
    /// reduced colour, "filled accent" and "grey" converge toward each other,
    /// and counting position on ~29 pt capsules in low light is the wrong thing
    /// to ask of someone glancing at their wrist. A word is unambiguous at any
    /// brightness.
    private var dimmed: some View {
        HStack(spacing: 4) {
            Text(zone?.label ?? "—")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            if isOverridden {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var interactive: some View {
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
            // Focus is surrendered as soon as a lock lands, so the gate closes
            // behind every use of it. Leaving it open made the gate one-time:
            // after the first tap the row stayed focused indefinitely, and any
            // later Crown bump — a sleeve, a knock — pinned a zone and started
            // a three-minute hold with no further intent from the owner. That
            // is precisely the hazard the doc comment above claims is handled.
            //
            // The cost is one zone per tap. Acceptable: §6.5 already says the
            // system moves one step at a time, and a manual lock is not the
            // place to be looser than the automatic path.
            crownFocus = false
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
                // Handing control back must also close the gate, or resuming
                // leaves a live Crown behind it.
                crownFocus = false
            } else {
                crownFocus = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        // Only a row that can actually do something announces itself as a
        // button. Before the first observation seeds a zone there is nothing
        // to lock and nothing to resume.
        .accessibilityAddTraits(isActionable ? .isButton : [])
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
            }
        }
        .lineLimit(1)
    }

    /// Inert until the first observation seeds a zone: there is nothing to
    /// lock and nothing to resume.
    private var isActionable: Bool { zone != nil }

    private var accessibilityText: String {
        guard isActionable else { return "No zone yet" }

        var parts = [zone?.label ?? "No zone"]
        if isOverridden {
            parts.append("locked")
            if let overrideCause { parts.append(overrideCause) }
            parts.append("double tap to resume automatic control")
        } else {
            parts.append("double tap to choose a zone with the crown")
        }
        return parts.joined(separator: ", ")
    }
}
