//
// M3UTrackMatcher
//
// Matches M3U entries whose paths no longer exist to the files that replaced them, such as
// an album whose files were renamed after the playlist was written. Pure logic: callers
// supply the entries and the candidate files with their tags and durations.
//

import Foundation

enum M3UTrackMatcher {
    /// Below this share of resolved entries a playlist is treated as not belonging to the
    /// files it was opened against, and is not played.
    static let minimumResolvedShare = 0.8

    /// An entry as written in the playlist, with its `#EXTINF` details when present.
    struct Entry: Equatable {
        let location: String
        var duration: Double?
        var title: String?
    }

    /// A file an entry may be matched to.
    struct Candidate {
        let filename: String
        var title: String?
        var trackNumber: Int?
        var discNumber: Int?
        var duration: Double?

        /// A duration of zero or less, as unreadable files report, counts as unknown.
        init(filename: String, title: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, duration: Double? = nil) {
            self.filename = filename
            self.title = title
            self.trackNumber = trackNumber
            self.discNumber = discNumber
            self.duration = duration.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    // MARK: - Parsing

    /// Entries in playlist order. `#EXTINF:<seconds>,<title>` applies to the next location.
    static func parseEntries(_ content: String) -> [Entry] {
        var entries: [Entry] = []
        var pendingDuration: Double?
        var pendingTitle: String?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard !line.isEmpty else { continue }

            if line.uppercased().hasPrefix(M3UFormat.infoPrefix) {
                let info = line.dropFirst(M3UFormat.infoPrefix.count)
                let parts = info.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                let seconds = parts.first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                pendingDuration = seconds.flatMap { $0 > 0 ? $0 : nil }
                pendingTitle = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces).nilIfEmpty : nil
                continue
            }
            guard !line.hasPrefix(M3UFormat.commentPrefix) else { continue }

            entries.append(Entry(location: line, duration: pendingDuration, title: pendingTitle))
            pendingDuration = nil
            pendingTitle = nil
        }
        return entries
    }

    // MARK: - Matching

    /// Lengths within this many seconds agree; `#EXTINF` only carries whole seconds.
    static let durationTolerance = 1.5

    /// Number-and-length matches without an agreeing title are kept only when at least this
    /// many entries of the group matched, making up at least `weakGroupShare` of it.
    static let weakGroupMinimum = 3
    static let weakGroupShare = 0.5

    /// Pairs entries with candidates one to one. A pair needs two agreeing signals among
    /// track number, duration and title, or an identical title, and no contradiction. An
    /// entry is matched only once a single candidate is left for it and no other entry is
    /// left with that same one.
    ///
    /// A pair whose title does not agree rests on track number and length alone, which two
    /// unrelated tracks share often enough by chance. Such pairs are dropped unless the
    /// group matched as a whole, as a renamed album does.
    /// - Returns: candidate index for each matched entry index.
    static func match(_ entries: [Entry], to candidates: [Candidate]) -> [Int: Int] {
        let entryKeys = entries.map(EntryKey.init)
        let candidateKeys = candidates.map(CandidateKey.init)
        // A track number only tells tracks apart where it is unique on its side: folders of
        // loose songs often tag every file as track 1.
        let distinctEntryNumbers = distinctNumbers(entryKeys.map { NumberKey(disc: $0.discNumber, track: $0.trackNumber) })
        let distinctCandidateNumbers = distinctNumbers(
            candidateKeys.map { NumberKey(disc: $0.discNumber, track: $0.trackNumber) }
        )

        var accepted: [Int: Set<Int>] = [:]
        var weakPairs = Set<[Int]>()
        for (entryIndex, entry) in entryKeys.enumerated() {
            for (candidateIndex, candidate) in candidateKeys.enumerated() {
                let numbersCount = distinctEntryNumbers.contains(entryIndex)
                    && distinctCandidateNumbers.contains(candidateIndex)
                guard let strength = evidence(entry, candidate, numbersCount: numbersCount) else { continue }
                accepted[entryIndex, default: []].insert(candidateIndex)
                if strength == .weak { weakPairs.insert([entryIndex, candidateIndex]) }
            }
        }

        // A weak pair only stands in where no title agrees: an entry or candidate that has a
        // pair with an agreeing title drops its weak ones, such as a stray track that shares
        // the number and length of the entry's real, renamed file.
        let strongPairs = accepted.flatMap { entry, options in options.map { [entry, $0] } }
            .filter { !weakPairs.contains($0) }
        let strongEntries = Set(strongPairs.map { $0[0] })
        let strongCandidates = Set(strongPairs.map { $0[1] })
        for pair in weakPairs where strongEntries.contains(pair[0]) || strongCandidates.contains(pair[1]) {
            accepted[pair[0]]?.remove(pair[1])
            weakPairs.remove(pair)
        }

        // Settle unique pairs first; taking a candidate can leave another entry with a
        // single remaining partner, so repeat until nothing changes.
        var result: [Int: Int] = [:]
        var taken = Set<Int>()
        var progressed = true
        while progressed {
            progressed = false
            var claimants: [Int: [Int]] = [:]
            for (entryIndex, options) in accepted where result[entryIndex] == nil {
                let open = options.subtracting(taken)
                if open.count == 1, let candidateIndex = open.first {
                    claimants[candidateIndex, default: []].append(entryIndex)
                }
            }
            // Two entries left with the same single candidate are ambiguous; both stay out.
            for (candidateIndex, entryIndexes) in claimants where entryIndexes.count == 1 {
                result[entryIndexes[0]] = candidateIndex
                taken.insert(candidateIndex)
                progressed = true
            }
        }

        let groupMatched = result.count >= weakGroupMinimum
            && Double(result.count) / Double(entries.count) >= weakGroupShare
        if !groupMatched {
            result = result.filter { !weakPairs.contains([$0.key, $0.value]) }
        }
        return result
    }

    private struct NumberKey: Hashable {
        let disc: Int?
        let track: Int?
    }

    /// Indexes whose track number can be trusted. Numbering looks like an album's when the
    /// distinct numbers make up a good share of the items and none repeats more often than
    /// an album has discs (discs untagged, "01" once per disc). A folder of loose songs
    /// tagging most files as track 1 fails both.
    private static func distinctNumbers(_ keys: [NumberKey]) -> Set<Int> {
        let numbered = keys.indices.filter { keys[$0].track != nil }
        guard !numbered.isEmpty else { return [] }
        let counts = Dictionary(numbered.map { (keys[$0], 1) }, uniquingKeysWith: +)
        guard Double(counts.count) / Double(keys.count) >= 0.4 else { return [] }
        return Set(numbered.filter { counts[keys[$0]] ?? 0 <= 4 })
    }

    private enum Evidence {
        /// The titles agree.
        case strong
        /// Track number and length agree, the titles don't.
        case weak
    }

    private static func evidence(_ entry: EntryKey, _ candidate: CandidateKey, numbersCount: Bool) -> Evidence? {
        if numbersCount, let entryNumber = entry.trackNumber, let candidateNumber = candidate.trackNumber,
           entryNumber != candidateNumber {
            return nil
        }
        if let entryDisc = entry.discNumber, let candidateDisc = candidate.discNumber, entryDisc != candidateDisc {
            return nil
        }
        if let entryDuration = entry.duration, let candidateDuration = candidate.duration,
           abs(entryDuration - candidateDuration) > 5 {
            return nil
        }

        let numberAgrees = numbersCount && entry.trackNumber != nil && entry.trackNumber == candidate.trackNumber
        let lengthGap = entry.duration.flatMap { entryDuration in candidate.duration.map { abs(entryDuration - $0) } }
        let durationAgrees = lengthGap.map { $0 <= durationTolerance } ?? false
        // Songs share titles across artists; an identical title needs the lengths to be close
        // too, when both are known.
        let titleIsIdentical = !entry.titles.isDisjoint(with: candidate.titles) && (lengthGap ?? 0) <= 3
        let titleAgrees = titleIsIdentical || entry.titles.contains { entryTitle in
            candidate.titles.contains { similarity(entryTitle, $0) >= 0.8 }
        }

        if titleIsIdentical || (titleAgrees && (numberAgrees || durationAgrees)) {
            return .strong
        }
        if numberAgrees && durationAgrees {
            return .weak
        }
        return nil
    }

    // MARK: - Normalised Keys

    private struct EntryKey {
        let trackNumber: Int?
        let discNumber: Int?
        let duration: Double?
        let titles: Set<String>

        init(_ entry: Entry) {
            let stem = M3UTrackMatcher.stem(of: entry.location)
            let numbering = M3UTrackMatcher.leadingNumbering(in: stem)
            trackNumber = numbering?.track
            discNumber = numbering?.disc
            duration = entry.duration

            var titles = [numbering?.rest ?? stem]
            if let title = entry.title {
                titles.append(title)
                // "#EXTINF:...,Artist - Title"
                if let range = title.range(of: " - ") {
                    titles.append(String(title[range.upperBound...]))
                }
            }
            self.titles = Set(titles.map(M3UTrackMatcher.normalize).filter { !$0.isEmpty })
        }
    }

    private struct CandidateKey {
        let trackNumber: Int?
        let discNumber: Int?
        let duration: Double?
        let titles: Set<String>

        init(_ candidate: Candidate) {
            let stem = M3UTrackMatcher.stem(of: candidate.filename)
            let numbering = M3UTrackMatcher.leadingNumbering(in: stem)
            trackNumber = candidate.trackNumber ?? numbering?.track
            discNumber = candidate.trackNumber != nil ? candidate.discNumber : numbering?.disc
            duration = candidate.duration

            var titles = [numbering?.rest ?? stem]
            if let title = candidate.title {
                titles.append(title)
            }
            self.titles = Set(titles.map(M3UTrackMatcher.normalize).filter { !$0.isEmpty })
        }
    }

    /// File name without folders or extension; accepts both `/` and `\` separators.
    static func stem(of location: String) -> String {
        let name = location.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? location
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// "03 Title", "03 - Title", "03. Title" and "1-03 Title" (disc 1, track 3). Up to three
    /// digits, so a leading year such as "2010 Title" is not taken for a track number.
    static func leadingNumbering(in stem: String) -> (disc: Int?, track: Int, rest: String)? {
        let scalars = Array(stem.trimmingCharacters(in: .whitespaces))
        var index = 0
        func readNumber() -> Int? {
            let start = index
            while index < scalars.count, scalars[index].isASCII, scalars[index].isNumber { index += 1 }
            guard index > start, index - start <= 3 else { return nil }
            return Int(String(scalars[start..<index]))
        }

        guard let first = readNumber() else { return nil }
        var disc: Int?
        var track = first
        if index + 1 < scalars.count, scalars[index] == "-" || scalars[index] == ".",
           scalars[index + 1].isASCII, scalars[index + 1].isNumber {
            let save = index
            index += 1
            if let second = readNumber(), index < scalars.count, !scalars[index].isNumber {
                disc = first
                track = second
            } else {
                index = save
            }
        }
        // A number must be followed by a separator, not run into a word ("4Minutes").
        guard index < scalars.count, !scalars[index].isLetter else { return nil }
        let rest = String(scalars[index...]).trimmingCharacters(in: CharacterSet(charactersIn: " -._)]").union(.whitespaces))
        return (disc, track, rest)
    }

    /// Case-, width- and compatibility-insensitive form with punctuation removed and the
    /// wave dashes (~, 〜, ～) unified. Diacritics are kept: folding them would merge
    /// distinct kana such as か and が.
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        var output = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !output.isEmpty { output.append(" ") }
                pendingSpace = false
                output.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return output
    }

    /// Share of words the two titles have in common (Jaccard index).
    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsWords = Set(lhs.split(separator: " "))
        let rhsWords = Set(rhs.split(separator: " "))
        let union = lhsWords.union(rhsWords)
        guard !union.isEmpty else { return 0 }
        return Double(lhsWords.intersection(rhsWords).count) / Double(union.count)
    }
}
