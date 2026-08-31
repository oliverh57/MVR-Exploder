import Foundation

/// What's wrong with a patch, given what each fixture occupies.
///
/// The app could always show a fixture's universe and channel; it could
/// never say whether that address was *free*, because it had no idea how
/// wide any fixture was. With a footprint from the GDTF an address becomes
/// a range, and ranges can be checked against each other.
enum MVRPatchCheck {

    /// A fixture placed in DMX space.
    struct Patch: Equatable {
        let fixtureID: String
        let name: String
        let universe: Int
        let channel: Int
        /// Channels occupied, always at least 1.
        let footprint: Int

        /// The last channel this fixture touches. A 40-channel fixture at
        /// 100 ends at 139, not 140 — the address itself is the first
        /// channel, which is the off-by-one every patch tool has to get
        /// right.
        var lastChannel: Int { channel + footprint - 1 }
    }

    enum Finding: Equatable {
        /// Two or more fixtures whose channels overlap.
        case overlap(universe: Int, channels: ClosedRange<Int>, fixtureIDs: [String])
        /// A fixture that runs off the end of its universe.
        case overrun(fixtureID: String, universe: Int, lastChannel: Int)

        var fixtureIDs: [String] {
            switch self {
            case let .overlap(_, _, ids): return ids
            case let .overrun(id, _, _): return [id]
            }
        }
    }

    /// The highest channel in a DMX universe.
    static let universeSize = 512

    /// Every clash and overrun, worst first.
    ///
    /// Fixtures whose footprint isn't known are left out entirely rather
    /// than assumed to be one channel: a guess here reports clashes that
    /// aren't there, and a patch check nobody trusts is worse than none.
    static func findings(in patches: [Patch]) -> [Finding] {
        var findings: [Finding] = []

        for patch in patches where patch.lastChannel > universeSize {
            findings.append(.overrun(
                fixtureID: patch.fixtureID,
                universe: patch.universe,
                lastChannel: patch.lastChannel))
        }

        // Reported per contested *run of channels*, not per pair of
        // fixtures. Pairs look right until a real file turns up with its
        // whole rig sitting on one address: 670 fixtures stacked produced
        // 224,115 findings, which is every pair, all of them true and none
        // of them readable. One finding per run says the same thing once.
        //
        // Counted into a 512-slot tally per universe rather than compared
        // fixture against fixture — a universe is small and fixed, so the
        // sweep costs the same whether two fixtures share it or six
        // hundred.
        for (universe, group) in Dictionary(grouping: patches, by: \.universe) {
            var coverage = [Int](repeating: 0, count: universeSize + 2)
            for patch in group {
                let low = max(1, patch.channel)
                let high = min(universeSize, patch.lastChannel)
                guard low <= high else { continue }
                coverage[low] += 1
                coverage[high + 1] -= 1
            }

            var depth = 0
            var contestedFrom: Int?
            for channel in 1...(universeSize + 1) {
                depth += coverage[channel]
                if depth >= 2, contestedFrom == nil {
                    contestedFrom = channel
                } else if depth < 2, let from = contestedFrom {
                    let channels = from...(channel - 1)
                    let involved = group
                        .filter { $0.channel <= channels.upperBound && $0.lastChannel >= channels.lowerBound }
                        .map(\.fixtureID)
                        .sorted()
                    findings.append(.overlap(
                        universe: universe, channels: channels, fixtureIDs: involved))
                    contestedFrom = nil
                }
            }
        }

        // Overruns first — a fixture off the end of its universe is broken
        // outright, where an overlap may be two things sharing on purpose.
        return findings.sorted { first, second in
            switch (first, second) {
            case (.overrun, .overlap): return true
            case (.overlap, .overrun): return false
            case let (.overrun(_, a, b), .overrun(_, c, d)): return (a, b) < (c, d)
            case let (.overlap(a, b, _), .overlap(c, d, _)):
                return (a, b.lowerBound) < (c, d.lowerBound)
            }
        }
    }

    /// Channels used in each universe, for a sense of how full the rig is.
    static func usage(in patches: [Patch]) -> [(universe: Int, used: Int)] {
        var used: [Int: Set<Int>] = [:]
        for patch in patches {
            let last = min(patch.lastChannel, universeSize)
            guard patch.channel <= last else { continue }
            used[patch.universe, default: []].formUnion(patch.channel...last)
        }
        return used
            .map { (universe: $0.key, used: $0.value.count) }
            .sorted { $0.universe < $1.universe }
    }
}

extension MVRPatchCheck {

    /// A type whose declared footprint contradicts how it is patched.
    struct SuspectFootprint: Equatable {
        let spec: String
        /// What the GDTF in the file says.
        let declared: Int
        /// How far apart these fixtures are actually addressed.
        let spacing: Int
        let fixtureCount: Int
    }

    struct Placement {
        var patches: [Patch] = []
        /// Types with no usable channel count in their GDTF.
        var unknownTypes: Set<String> = []
        /// Types whose GDTF is evidently not the one the rig was patched
        /// with. Left out of the checks, and reported in their own right.
        var suspectTypes: [SuspectFootprint] = []
    }

    /// Types patched more tightly than their own footprint allows.
    ///
    /// A stand-in GDTF is the normal case in these files, and a wrong one
    /// is worse than none: a Sceptron declaring 306 channels, patched every
    /// 30, produced 35 overruns off the end of the universe — all of them
    /// artefacts of a GDTF that isn't the mode the rig uses. Evenly spaced
    /// addresses are the rig telling us what the footprint really is, and
    /// when the two disagree the file is the better witness.
    ///
    /// Needs three fixtures and a clear majority at one spacing, so an
    /// ordinary pair of clashing fixtures is never mistaken for this.
    static func suspectFootprints(
        _ candidates: [(spec: String, address: Int, declared: Int)]
    ) -> [SuspectFootprint] {
        var bySpec: [String: [(address: Int, declared: Int)]] = [:]
        for candidate in candidates {
            bySpec[candidate.spec, default: []].append((candidate.address, candidate.declared))
        }

        var suspects: [SuspectFootprint] = []
        for (spec, entries) in bySpec where entries.count >= 3 {
            guard let declared = entries.first?.declared else { continue }
            let addresses = entries.map(\.address).sorted()
            let gaps = zip(addresses, addresses.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
            guard !gaps.isEmpty else { continue }

            var counts: [Int: Int] = [:]
            for gap in gaps { counts[gap, default: 0] += 1 }
            guard let (spacing, seen) = counts.max(by: { $0.value < $1.value }),
                  Double(seen) / Double(gaps.count) >= 0.6,
                  spacing < declared else { continue }

            suspects.append(SuspectFootprint(
                spec: spec, declared: declared, spacing: spacing, fixtureCount: entries.count))
        }
        return suspects.sorted { $0.fixtureCount > $1.fixtureCount }
    }

    /// Places every fixture that can be placed.
    ///
    /// A fixture is left out when it has no address, or when its GDTF
    /// doesn't say how wide it is. Both are common — an unpatched spare, a
    /// placeholder GDTF — and neither is a clash, so guessing a width for
    /// them would invent findings rather than report them.
    static func placements(
        fixtures: [MVRFixture], footprints: [String: [GDTFFootprint]]
    ) -> Placement {
        var result = Placement()
        var candidates: [(spec: String, address: Int, declared: Int, fixture: MVRFixture)] = []

        for fixture in fixtures {
            guard let address = fixture.currentAddress else { continue }
            let modes = footprints[fixture.gdtfSpec] ?? []
            // The mode the fixture is patched in, falling back to the only
            // mode when a file names one the GDTF doesn't have — which
            // happens, and is better answered with the one candidate than
            // with nothing.
            let match = modes.first { $0.mode == fixture.mode }
                ?? (modes.count == 1 ? modes[0] : nil)

            guard let match, match.isKnown else {
                result.unknownTypes.insert(fixture.gdtfSpec)
                continue
            }
            candidates.append((fixture.gdtfSpec, address, max(match.channels, 1), fixture))
        }

        result.suspectTypes = suspectFootprints(
            candidates.map { ($0.spec, $0.address, $0.declared) })
        let suspect = Set(result.suspectTypes.map(\.spec))

        for candidate in candidates where !suspect.contains(candidate.spec) {
            let split = MVRFixture.universeAndChannel(fromAbsoluteAddress: candidate.address)
            result.patches.append(Patch(
                fixtureID: candidate.fixture.id,
                name: candidate.fixture.name,
                universe: split.universe,
                channel: split.channel,
                footprint: candidate.declared))
        }
        return result
    }
}
