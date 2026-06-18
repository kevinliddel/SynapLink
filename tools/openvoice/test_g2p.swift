// Desktop validation: G2P (Swift) vs melo's reference phones/tones/langs AND the
// BERT alignment (word2ph_doubled, input_ids) that drives ja_bert.
// Build: swiftc SynapLink/Data/DataSources/Audio/G2P.swift tools/openvoice/test_g2p.swift -o build/g2p-test
// Run from repo root.
import Foundation

let base = URL(fileURLWithPath: "tools/openvoice/g2p_assets")
guard let g2p = G2P(symbolsURL: base.appendingPathComponent("symbols.txt"),
                    lexiconURL: base.appendingPathComponent("lexicon.txt"),
                    metaURL: base.appendingPathComponent("meta.json"),
                    bertVocabURL: base.appendingPathComponent("bert_vocab.txt")) else {
    print("FAIL: could not load g2p assets"); exit(1)
}
guard g2p.hasBert else { print("FAIL: bert vocab not loaded"); exit(1) }

let data = try! Data(contentsOf: base.appendingPathComponent("bert_refs.json"))
let refs = (try! JSONSerialization.jsonObject(with: data)) as! [[String: Any]]

func check(_ name: String, _ got: [Int64], _ exp: [Int]) -> Bool {
    let ok = got == exp.map(Int64.init)
    if !ok {
        let n = min(40, max(got.count, exp.count))
        print("  \(name) got \(Array(got.prefix(n)))")
        print("  \(name) exp \(Array(exp.prefix(n)).map(Int64.init))")
    }
    return ok
}

var allPass = true
for ref in refs {
    let text = ref["text"] as! String
    let e = g2p.encode(text)
    var ok = check("phones", e.phones, ref["phones"] as! [Int])
    ok = check("tones", e.tones, ref["tones"] as! [Int]) && ok
    ok = check("langs", e.langs, ref["langs"] as! [Int]) && ok
    ok = check("input_ids", e.inputIds, ref["input_ids"] as! [Int]) && ok
    ok = check("word2ph", e.word2ph.map(Int64.init), ref["word2ph_doubled"] as! [Int]) && ok
    allPass = allPass && ok
    print("\(ok ? "PASS" : "FAIL"): \(text)")
}
print(allPass ? "ALL PASS" : "FAILURES")
exit(allPass ? 0 : 1)
