import Foundation
import ZIPFoundation

/// How many DMX channels a fixture occupies, read from its GDTF.
///
/// Nothing in the app knew this before. The patch table showed a universe
/// and a channel per fixture and stopped there, which meant the mistake a
/// patch most often carries — two fixtures whose channel ranges overlap —
/// looked like two perfectly ordinary rows. A footprint is what turns an
/// address into a range, and a range is what can be checked.
///
/// The count is per *mode*: the same fixture is 42 channels in one mode and
/// 15 in another, and the MVR names the mode each instance is patched in.
struct GDTFFootprint: Equatable {
    /// The mode this describes, as GDTF spells it.
    let mode: String
    /// Channels used on each DMX break, keyed by break number.
    ///
    /// Nearly every fixture is one break. The ones that aren't — an LED
    /// batten addressed as a head plus a pixel string — take a separate
    /// address per break, and MVR lists one `<Address break="…">` for each.
    let channelsByBreak: [Int: Int]

    /// The first break's count, which is what a single-address fixture
    /// occupies and what the patch check works from. Zero means the GDTF
    /// didn't say — see `isKnown`.
    var channels: Int { channelsByBreak[primaryBreak] ?? 0 }

    /// False when every channel in the mode carries an empty `Offset`.
    ///
    /// Real files do this: a placeholder GDTF declares its channels but
    /// never addresses them. A footprint of zero is the honest reading, and
    /// treating it as a zero-width fixture would have it overlap nothing
    /// and be overlapped by everything — so callers must skip it instead.
    var isKnown: Bool { channels > 0 }

    /// GDTF numbers breaks from 1, but files in the wild use 0 for the only
    /// break often enough that assuming 1 would silently read them as
    /// having no channels at all.
    var primaryBreak: Int { channelsByBreak.keys.min() ?? 1 }
}

/// Reads every fixture type's footprints straight out of an MVR.
///
/// Takes a file URL and re-opens the archive itself, so it carries no
/// main-actor state and can run on a background task — the same shape as
/// the scene-geometry loader, and for the same reason: a .gdtf is a zip
/// full of meshes, and pulling seven of them out of one real file measured
/// 765 ms, which is a visible stall if it happens on the main thread.
enum GDTFFootprintLoader {

    /// Footprints per GDTF spec, as the spec is written in the file.
    nonisolated static func load(mvrURL url: URL, specs: [String]) -> [String: [GDTFFootprint]] {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return [:] }

        var result: [String: [GDTFFootprint]] = [:]
        for spec in Set(specs) {
            let name = (spec as NSString).lastPathComponent.lowercased()
            let wanted: Set<String> = [name, name.hasSuffix(".gdtf") ? name : name + ".gdtf"]
            guard let entry = archive.first(where: {
                wanted.contains(($0.path as NSString).lastPathComponent.lowercased())
            }) else { continue }

            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            let modes = GDTFFootprintParser.modes(packageData: data)
            if !modes.isEmpty { result[spec] = modes }
        }
        return result
    }
}

enum GDTFFootprintParser {

    /// Every mode in a .gdtf package, with its channel count.
    ///
    /// Empty when the package can't be read — a missing or dummy GDTF,
    /// which is common in these files — and the caller is expected to treat
    /// that as "unknown", never as zero channels.
    static func modes(packageData data: Data) -> [GDTFFootprint] {
        guard let archive = try? Archive(data: data, accessMode: .read),
              let entry = archive.first(where: {
                  ($0.path as NSString).lastPathComponent == "description.xml"
              }) else { return [] }

        var xmlData = Data()
        _ = try? archive.extract(entry) { xmlData.append($0) }
        guard let document = try? XMLDocument(data: xmlData, options: []) else { return [] }
        return modes(description: document)
    }

    static func modes(description document: XMLDocument) -> [GDTFFootprint] {
        let nodes = (try? document.nodes(forXPath: "//DMXModes/DMXMode")) ?? []
        return nodes.compactMap { node in
            guard let mode = node as? XMLElement,
                  let name = mode.attribute(forName: "Name")?.stringValue else { return nil }
            return GDTFFootprint(mode: name, channelsByBreak: channels(in: mode))
        }
    }

    /// The highest offset any channel reaches, per break.
    ///
    /// A channel's `Offset` is a list — "12,13" is a 16-bit channel with its
    /// coarse byte at 12 and its fine byte at 13 — so the footprint is the
    /// largest number mentioned anywhere, not the channel count. Channels
    /// with no offset are virtual: they exist in the fixture's logic and
    /// take no DMX, and counting them would overstate the patch.
    private static func channels(in mode: XMLElement) -> [Int: Int] {
        var byBreak: [Int: Int] = [:]
        for case let channel as XMLElement in (try? mode.nodes(forXPath: ".//DMXChannel")) ?? [] {
            let offsets = (channel.attribute(forName: "Offset")?.stringValue ?? "")
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let highest = offsets.max() else { continue }

            let dmxBreak = channel.attribute(forName: "DMXBreak")?.stringValue
                .flatMap(Int.init) ?? 1
            byBreak[dmxBreak] = max(byBreak[dmxBreak] ?? 0, highest)
        }
        return byBreak
    }
}
