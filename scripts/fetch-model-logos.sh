#!/usr/bin/env bash
# Fetch model-family logos (Hugging Face org avatars) into the asset catalog as
# model-logo-<family> imagesets. Rerun anytime; families that fail keep the
# ModelBadge monogram fallback. Requires network access to huggingface.co.
set -u
cd "$(dirname "$0")/.."
ASSETS="src/openTihui/Assets.xcassets"

fetch() {
    fam="$1"; org="$2"
    url=$(curl -sgm 20 "https://huggingface.co/api/organizations/$org/overview" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('avatarUrl') or '')
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

fetch qwen     "Qwen"
fetch gemma    "google"
fetch bonsai   "prism-ml"
fetch llama    "meta-llama"
fetch mistral  "mistralai"
fetch deepseek "deepseek-ai"
fetch phi      "microsoft"
