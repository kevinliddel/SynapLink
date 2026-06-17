#!/usr/bin/env bash
# MeloTTS (V2 base TTS) desktop install — reproducible, ordered to dodge the
# dependency landmines. Run AFTER setup.sh (needs the `openvoice` conda env +
# converter). After this, run the pipeline with the env vars at the bottom.
set -e
ENV=openvoice
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1) numba/llvmlite as conda-forge BINARIES (pip can't build llvmlite here),
#    pinned with numpy=1.26 so the pip torch's numpy-1.x ABI keeps working
#    (conda's default numba pulls numpy 2.1 and breaks torch's .numpy()).
echo "== numba/llvmlite + numpy=1.26 (conda-forge) =="
conda install -y -n "$ENV" -c conda-forge "numpy=1.26" numba llvmlite

echo "== librosa (pip, uses the conda numba) =="
conda run -n "$ENV" python -m pip install "librosa==0.9.1"

echo "== MeloTTS + frontend =="
conda run -n "$ENV" python -m pip install "unidic-lite" "git+https://github.com/myshell-ai/MeloTTS.git"
conda run -n "$ENV" python -m nltk.downloader -q averaged_perceptron_tagger_eng cmudict averaged_perceptron_tagger || true
# MeCab is initialized at import even for English; it needs the FULL unidic dict.
conda run -n "$ENV" python -m unidic download

echo "== V2 base-speaker source SE vectors =="
mkdir -p "${HERE}/checkpoints/base_speakers/ses"
base="https://huggingface.co/myshell-ai/OpenVoiceV2/resolve/main/base_speakers/ses"
for s in en-us en-newest en-default; do
  curl -L --fail -sS -o "${HERE}/checkpoints/base_speakers/ses/$s.pth" "$base/$s.pth" \
    && echo "  got $s" || echo "  MISS $s"
done

echo
echo "MELOTTS_SETUP_DONE. Run the pipeline with the OpenMP-duplicate workaround:"
echo "  KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false \\"
echo "    conda run -n ${ENV} python ${HERE}/melo_clone.py <reference.wav> \"text\""
