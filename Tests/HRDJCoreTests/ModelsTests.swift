import Foundation
import Testing
import HRDJCore

@Suite("Core models")
struct ModelsTests {
    @Test("Zones order by energy and carry the §6.1 labels")
    func zoneOrdering() {
        #expect(Zone.allCases == [.meditation, .z1, .z2, .z3, .z4])
        #expect(Zone.meditation < Zone.z1)
        #expect(Zone.z1 < Zone.z4)
        #expect(Zone.z3 > Zone.z2)
        #expect(Zone.meditation.label == "Meditation")
        #expect(Zone.z1.label == "Recovery")
        #expect(Zone.z2.label == "Aerobic")
        #expect(Zone.z3.label == "Tempo")
        #expect(Zone.z4.label == "Hard")
    }

    @Test("Raw values are the zone indices the control law arithmetic uses")
    func zoneIndices() {
        // §6.3 indexes `boundaries` by zone and §6.5 clamps on zone ± 1, so
        // the raw values have to be 0...4 contiguous, not decorative. The
        // meditation zone sits at the bottom rather than being bolted on at
        // -1, so every existing index calculation keeps working unchanged.
        #expect(Zone.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
        #expect(Zone.allCases == Zone.allCases.sorted())
    }

    @Test("Each zone maps to its pool and back")
    func poolRoundTrip() {
        for zone in Zone.allCases {
            #expect(zone.poolID.zone == zone)
        }
        #expect(Zone.meditation.poolID == .z0)
        #expect(PoolID.z0.rawValue == "Z0")
        #expect(Zone.z3.poolID == .z3)
        #expect(PoolID.z3.rawValue == "Z3")

        // §8 configures one playlist per pool. Every zone needs one or
        // selection has nowhere to go.
        #expect(PoolID.allCases.count == Zone.allCases.count)
    }

    @Test(
        "Sample plausibility follows §6.2 bounds",
        arguments: [
            (29, false), (30, true), (60, true), (240, true), (241, false), (0, false), (-5, false),
        ]
    )
    func plausibility(bpm: Int, expected: Bool) {
        let sample = HRSample(at: .reference, bpm: bpm)
        #expect(sample.isPlausible == expected)
    }

    @Test("Decision encodes with the §11.3 wire names")
    func decisionWireFormat() throws {
        var decision = Decision(at: .reference, event: .commit)
        decision.trackID = "abc123"
        decision.trackRemainingMillis = 19_400
        decision.estimatedEndDriftMillis = 340
        decision.selectedURI = "spotify:track:xyz"
        decision.selectedFromPool = .z3
        decision.currentZone = .z2
        decision.targetZone = .z3
        decision.attempt = 1
        decision.outcome = .success
        decision.httpStatus = 204

        let data = try JSONEncoder().encode(decision)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])

        // The log is the tuning instrument for §6.7 and gets compared across
        // sessions, so these names are part of the contract.
        #expect(json["trackId"] as? String == "abc123")
        #expect(json["trackRemainingMs"] as? Int == 19_400)
        #expect(json["estimatedEndDriftMs"] as? Int == 340)
        #expect(json["selectedUri"] as? String == "spotify:track:xyz")
        #expect(json["selectedFromPool"] as? String == "Z3")
        #expect(json["event"] as? String == "commit")
        #expect(json["outcome"] as? String == "success")
        // Zone encodes as its raw index. Z2 is 2, not 1: adding the meditation
        // zone at the bottom shifted every zone up by one. Pinned as a literal
        // because that shift is exactly the kind of change a log reader has to
        // know about, and no §11.3 log has been recorded yet — after M2 starts
        // producing traces, renumbering here breaks comparability across
        // sessions and is no longer free.
        #expect(json["currentZone"] as? Int == 2)

        // `t` is a wall-clock stamp and HRDJCore has no wall clock; the
        // logging layer adds it. The monotonic instant must not leak into the
        // encoded record under any name.
        #expect(json.keys.contains("t") == false)
        #expect(json.keys.contains("at") == false)
    }

    @Test("Absent decision fields are omitted rather than encoded as null")
    func sparseDecision() throws {
        let decision = Decision(at: .reference, event: .hrSampleGap)
        let data = try JSONEncoder().encode(decision)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        #expect(json.keys.sorted() == ["event"])
    }
}
