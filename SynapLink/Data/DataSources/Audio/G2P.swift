//
//  G2P.swift
//  SynapLink
//
//  English grapheme-to-phoneme for the cloned-voice TTS, mirroring melo's
//  front-end: text_normalize → BERT BasicTokenizer word split → CMUdict lexicon
//  lookup (refine_syllables, baked offline) → post_replace_ph → pad "_" →
//  cleaned_text_to_sequence (ids, tone+tone_start, lang_id) → intersperse(0).
//  OOV words (not in the 129k-word lexicon) fall back to per-char UNK for now
//  (melo uses an LSTM; baking more words or porting it is a later improvement).
//  Assets: g2p_symbols.txt, g2p_lexicon.txt, g2p_meta.json (bundled).
//

import Foundation

final class G2P {

    private let symbols: [String]
    private let symbolToId: [String: Int32]
    private let lexicon: [String: ([String], [Int32])]
    private let toneStart: Int32
    private let langId: Int32
    private let repMap: [String: String]
    private let unkId: Int32

    init?(symbolsURL: URL, lexiconURL: URL, metaURL: URL) {
        guard let symText = try? String(contentsOf: symbolsURL, encoding: .utf8),
              let lexText = try? String(contentsOf: lexiconURL, encoding: .utf8),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else { return nil }

        symbols = symText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var s2i: [String: Int32] = [:]
        for (i, s) in symbols.enumerated() where !s.isEmpty { s2i[s] = Int32(i) }
        symbolToId = s2i
        unkId = s2i["UNK"] ?? 0

        var lex: [String: ([String], [Int32])] = [:]
        lex.reserveCapacity(130_000)
        for line in lexText.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let phones = parts[1].split(separator: " ").map(String.init)
            let tones = parts[2].split(separator: " ").compactMap { Int32($0) }
            lex[String(parts[0])] = (phones, tones)
        }
        lexicon = lex
        toneStart = Int32(meta["en_tone_start"] as? Int ?? 7)
        langId = Int32(meta["en_lang_id"] as? Int ?? 2)
        repMap = (meta["rep_map"] as? [String: String]) ?? [:]
    }

    convenience init?() {
        guard let s = Bundle.main.url(forResource: "g2p_symbols", withExtension: "txt"),
              let l = Bundle.main.url(forResource: "g2p_lexicon", withExtension: "txt"),
              let m = Bundle.main.url(forResource: "g2p_meta", withExtension: "json") else { return nil }
        self.init(symbolsURL: s, lexiconURL: l, metaURL: m)
    }

    /// text → (phones, tones, lang_ids) int64 sequences, matching melo exactly.
    func encode(_ text: String) -> (phones: [Int64], tones: [Int64], langs: [Int64]) {
        var phones: [String] = []
        var tones: [Int32] = []
        for token in tokenize(normalize(text)) {
            if let (p, t) = lexicon[token] {
                phones += p
                tones += t
            } else {
                for ch in token {  // punctuation / OOV → per-char (post_replace maps it)
                    phones.append(String(ch))
                    tones.append(0)
                }
            }
        }
        phones = phones.map(postReplace)
        phones = ["_"] + phones + ["_"]
        tones = [0] + tones + [0]

        let phoneIds = phones.map { symbolToId[$0] ?? unkId }
        let toneIds = tones.map { $0 + toneStart }
        let langIds = [Int32](repeating: langId, count: phoneIds.count)
        return (intersperse(phoneIds), intersperse(toneIds), intersperse(langIds))
    }

    // MARK: - Steps

    private func normalize(_ text: String) -> String {
        // melo: lower → expand_time → normalize_numbers → expand_abbreviations.
        // MVP ports lowercase only; number/time/abbrev expansion is a TODO (the
        // validation refs contain none). Digits left as-is for now.
        text.lowercased()
    }

    /// BERT BasicTokenizer: strip accents, split on whitespace, split each
    /// punctuation char into its own token.
    private func tokenize(_ text: String) -> [String] {
        let cleaned = text.folding(options: .diacriticInsensitive, locale: nil)
        var tokens: [String] = []
        var buf = ""
        for ch in cleaned {
            if ch == " " || ch.isWhitespace {
                if !buf.isEmpty { tokens.append(buf); buf = "" }
            } else if isPunctuation(ch) {
                if !buf.isEmpty { tokens.append(buf); buf = "" }
                tokens.append(String(ch))
            } else {
                buf.append(ch)
            }
        }
        if !buf.isEmpty { tokens.append(buf) }
        return tokens
    }

    private func isPunctuation(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let u = ch.unicodeScalars.first else {
            return ch.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
            }
        }
        let v = u.value
        if (v >= 33 && v <= 47) || (v >= 58 && v <= 64) || (v >= 91 && v <= 96) || (v >= 123 && v <= 126) {
            return true  // BERT treats all ASCII punctuation ranges as punctuation
        }
        return CharacterSet.punctuationCharacters.contains(u) || CharacterSet.symbols.contains(u)
    }

    private func postReplace(_ ph: String) -> String {
        let mapped = repMap[ph] ?? ph
        return symbolToId[mapped] != nil ? mapped : "UNK"
    }

    private func intersperse(_ values: [Int32]) -> [Int64] {
        var result = [Int64](repeating: 0, count: values.count * 2 + 1)
        for (i, v) in values.enumerated() { result[i * 2 + 1] = Int64(v) }
        return result
    }
}
