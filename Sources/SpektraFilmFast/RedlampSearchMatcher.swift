// SPDX-License-Identifier: MPL-2.0
// pdcgomes/redlamp: packages/RedlampUI/Sources/Model/SearchMatcher.swift
// Commit d8a892a259ccdaa12f1041ff01f88ce8e7ce68af.
// Unchanged word matching, renamed only to coexist with SpektraFilmStudio.
import Foundation

enum RedlampSearchMatcher {
    static func words(_ query: String) -> [String] {
        normalized(query).split(separator: " ").map(String.init)
    }

    static func score(_ words: [String], terms: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        let terms = terms.map(normalized)
        var total = 0
        for word in words {
            guard let best = terms.map({ score(word, $0) }).max(), best > 0 else { return nil }
            total += best
        }
        return total
    }

    static func score(_ word: String, _ term: String) -> Int {
        let termWords = term.split(separator: " ").map(String.init)
        if termWords.contains(word) { return 3 }
        if termWords.contains(where: { $0.hasPrefix(word) }) { return 2 }
        return word.count >= 3 && term.contains(word) ? 1 : 0
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "colour", with: "color")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "·", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
