// Desktop validation: G2P (Swift) vs melo's reference phone/tone/lang ids.
// Build: swiftc SynapLink/Data/DataSources/Audio/G2P.swift tools/openvoice/test_g2p.swift -o build/g2p-test
// Run from repo root.
import Foundation

let base = URL(fileURLWithPath: "tools/openvoice/g2p_assets")
guard let g2p = G2P(symbolsURL: base.appendingPathComponent("symbols.txt"),
                    lexiconURL: base.appendingPathComponent("lexicon.txt"),
                    metaURL: base.appendingPathComponent("meta.json")) else {
    print("FAIL: could not load g2p assets"); exit(1)
}

let data = try! Data(contentsOf: base.appendingPathComponent("refs.json"))
let refs = ((try! JSONSerialization.jsonObject(with: data)) as! [String: Any])["refs"] as! [[String: Any]]

var allPass = true
for ref in refs {
    let text = ref["text"] as! String
    let expP = (ref["phone_ids"] as! [Int]).map(Int64.init)
    let expT = (ref["tone_ids"] as! [Int]).map(Int64.init)
    let expL = (ref["lang_ids"] as! [Int]).map(Int64.init)
    let (p, t, l) = g2p.encode(text)
    let ok = p == expP && t == expT && l == expL
    allPass = allPass && ok
    print("\(ok ? "PASS" : "FAIL"): \(text)")
    if !ok {
        let n = min(36, max(p.count, expP.count))
        if p != expP { print("  P got \(Array(p.prefix(n)))"); print("  P exp \(Array(expP.prefix(n)))") }
        if t != expT { print("  T got \(Array(t.prefix(n)))"); print("  T exp \(Array(expT.prefix(n)))") }
        if l != expL { print("  L mismatch (lens \(l.count) vs \(expL.count))") }
    }
}
print(allPass ? "ALL PASS" : "FAILURES")
exit(allPass ? 0 : 1)
