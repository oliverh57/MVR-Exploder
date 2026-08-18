import Foundation

enum MatchMode: String, CaseIterable, Identifiable {
    case uuid = "UUID"
    case fixtureID = "Fixture ID"

    var id: String { rawValue }
}

enum ComparisonStatus: Equatable {
    case matched
    case leftOnly
    case rightOnly
}

struct MVRComparisonRow: Identifiable {
    let id: String
    let leftFixture: MVRFixture?
    let rightFixture: MVRFixture?
    let status: ComparisonStatus

    // MARK: - Sorting
    // KeyPathComparator needs non-optional Comparable values, so these give
    // sortable table columns something to key off when one side is empty.
    var leftNameSort: String { leftFixture?.name ?? "" }
    var leftFixtureIDSort: Int { leftFixture?.sortableFixtureID ?? Int.min }
    var leftUUIDSort: String { leftFixture?.currentUUID ?? "" }
    var leftAddressSort: Int { leftFixture?.sortableAddress ?? Int.min }
    var leftLayerSort: String { leftFixture?.layerName ?? "" }

    var rightNameSort: String { rightFixture?.name ?? "" }
    var rightFixtureIDSort: Int { rightFixture?.sortableFixtureID ?? Int.min }
    var rightUUIDSort: String { rightFixture?.currentUUID ?? "" }
    var rightAddressSort: Int { rightFixture?.sortableAddress ?? Int.min }
    var rightLayerSort: String { rightFixture?.layerName ?? "" }
}

enum MVRComparator {
    /// Pairs up fixtures from two documents by the chosen key. Unmatched
    /// fixtures on either side still appear as rows, with the other side
    /// left empty.
    static func compare(left: [MVRFixture], right: [MVRFixture], matchMode: MatchMode) -> [MVRComparisonRow] {
        func key(_ fixture: MVRFixture) -> String? {
            switch matchMode {
            case .uuid:
                return fixture.currentUUID
            case .fixtureID:
                return fixture.currentFixtureID.map(String.init)
            }
        }

        var rightByKey: [String: MVRFixture] = [:]
        for fixture in right {
            if let k = key(fixture) {
                rightByKey[k] = fixture
            }
        }

        var rows: [MVRComparisonRow] = []
        var matchedRightKeys = Set<String>()

        for leftFixture in left {
            guard let k = key(leftFixture) else {
                rows.append(MVRComparisonRow(id: leftFixture.id, leftFixture: leftFixture, rightFixture: nil, status: .leftOnly))
                continue
            }
            if let rightFixture = rightByKey[k] {
                rows.append(MVRComparisonRow(id: leftFixture.id, leftFixture: leftFixture, rightFixture: rightFixture, status: .matched))
                matchedRightKeys.insert(k)
            } else {
                rows.append(MVRComparisonRow(id: leftFixture.id, leftFixture: leftFixture, rightFixture: nil, status: .leftOnly))
            }
        }

        for rightFixture in right {
            guard let k = key(rightFixture), !matchedRightKeys.contains(k) else { continue }
            rows.append(MVRComparisonRow(id: rightFixture.id, leftFixture: nil, rightFixture: rightFixture, status: .rightOnly))
        }

        return rows
    }
}
