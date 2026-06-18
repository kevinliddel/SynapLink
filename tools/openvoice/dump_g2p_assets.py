#!/usr/bin/env python3
"""
Bake the assets a Swift g2p needs to mirror melo's English front-end:
  g2p_assets/symbols.txt   : symbol per line (index = id)
  g2p_assets/lexicon.txt    : WORD<TAB>ph ph ...<TAB>tone tone ...  (CMUdict via refine_syllables)
  g2p_assets/meta.json      : EN tone_start, EN lang_id, punctuation rep_map
  g2p_assets/refs.json      : test sentences -> melo phone/tone/lang ids (to validate the Swift port)

Swift then: text_normalize (numbers) -> BasicTokenizer (lowercase, split whitespace+punct)
-> per token: lexicon lookup (word) / post_replace_ph (punct) / UNK (OOV) -> pad "_" ->
intersperse with 0 -> ids (symbol_to_id, tone+tone_start, lang_id=2).
Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "g2p_assets")


def main():
    os.makedirs(OUT, exist_ok=True)
    from melo.text import english
    from melo.text.symbols import language_tone_start_map, language_id_map
    from melo.api import TTS
    tts = TTS(language="EN", device="cpu")
    tts.hps.data.disable_bert = True

    # Authoritative symbol->id from the loaded model (NOT the raw symbols list —
    # they differ, which threw the punctuation ids off by +2).
    sym2id = tts.symbol_to_id
    ordered = [""] * (max(sym2id.values()) + 1)
    for sym, idx in sym2id.items():
        ordered[idx] = sym
    with open(os.path.join(OUT, "symbols.txt"), "w") as f:
        f.write("\n".join(ordered))

    eng = english.get_dict()
    words = 0
    with open(os.path.join(OUT, "lexicon.txt"), "w") as f:
        for word, syl in eng.items():
            phs, tns = english.refine_syllables(syl)
            f.write(f"{word.lower()}\t{' '.join(phs)}\t{' '.join(map(str, tns))}\n")
            words += 1

    meta = {
        "en_tone_start": language_tone_start_map["EN"],
        "en_lang_id": language_id_map["EN"],
        "rep_map": {"：": ",", "；": ",", "，": ",", "。": ".", "！": "!", "？": "?",
                    "\n": ".", "·": ",", "、": ",", "...": "…", "v": "V"},
    }
    with open(os.path.join(OUT, "meta.json"), "w") as f:
        json.dump(meta, f, ensure_ascii=False)

    from melo import utils
    # In-vocab sentences (validate the g2p logic exactly). OOV words diverge by
    # design — melo uses an LSTM we don't ship; that's a documented limitation.
    sents = [
        "Hello, world!",
        "The answer is forty two.",
        "Sure! Here is what I think about that.",
        "Photosynthesis converts light into chemical energy.",
        "How are you doing today?",
        "Please tell me more about that, and I will help.",
        "I can read your messages aloud, clearly and naturally.",
    ]
    refs = []
    for s in sents:
        _, _, ph, to, la = utils.get_text_for_tts_infer(s, "EN", tts.hps, "cpu", tts.symbol_to_id)
        refs.append({"text": s, "phone_ids": ph.tolist(), "tone_ids": to.tolist(), "lang_ids": la.tolist()})
    with open(os.path.join(OUT, "refs.json"), "w") as f:
        json.dump({"refs": refs}, f)

    with open(os.path.join(OUT, "_summary.txt"), "w") as f:
        f.write(f"symbols={len(ordered)} lexicon_words={words} refs={len(refs)} "
                f"en_tone_start={meta['en_tone_start']} en_lang_id={meta['en_lang_id']}\n")


if __name__ == "__main__":
    main()
