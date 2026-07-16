#!/usr/bin/env bash
# Fetch model-family logos (Hugging Face org avatars) into the asset catalog as
# model-logo-<family> imagesets. Rerun anytime; families that fail keep the
# ModelBadge monogram fallback. Requires network access to huggingface.co.
set -u
cd "$(dirname "$0")/.."
ASSETS="src/openTihui/Assets.xcassets"

fetch() {
    fam="$1"; repo="$2"
    url=$(curl -sm 20 "https://huggingface.co/api/models/$repo?expand[]=authorData" | python3 -c "
import json,sys
try: print((json.load(sys.stdin).get('authorData') or {}).get('avatarUrl') or '')
except Exception: print('')")
    case "$url" in /*) url="https://huggingface.co$url";; "") echo "$fam: no avatar URL (HF unreachable?)"; return;; esac
    tmp=$(mktemp)
    if ! curl -sLm 30 "$url" -o "$tmp" || [ ! -s "$tmp" ]; then echo "$fam: download failed"; rm -f "$tmp"; return; fi
    dir="$ASSETS/model-logo-$fam.imageset"
    mkdir -p "$dir"
    sips -s format png -Z 256 "$tmp" --out "$dir/logo.png" >/dev/null 2>&1 || { echo "$fam: convert failed"; rm -f "$tmp"; return; }
    rm -f "$tmp"
    cat > "$dir/Contents.json" <<JSON
{
  "images" : [ { "filename" : "logo.png", "idiom" : "universal", "scale" : "2x" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
    echo "$fam: ok"
}

fetch qwen     "Qwen/Qwen3.5-2B"
fetch gemma    "google/gemma-4-E2B-it"
fetch bonsai   "prism-ml/Bonsai-27B-gguf"
fetch llama    "meta-llama/Llama-3.1-8B"
fetch mistral  "mistralai/Mistral-7B-v0.1"
fetch deepseek "deepseek-ai/DeepSeek-V3"
fetch phi      "microsoft/phi-4"
