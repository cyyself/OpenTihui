# llama.cpp patches

`*.patch` files in this directory are applied to the `llama.cpp/` submodule by
`scripts/build-llama-ios.sh` before the xcframework is built (`make framework`).

- Generate one from inside `llama.cpp/` with `git diff > ../patches/llama.cpp/NNNN-name.patch`.
- Patches are applied in filename order and idempotently (an already-applied
  patch is skipped; one that no longer applies fails the build loudly).
- Keep them small and upstreamable — this is for temporary fixes/backports
  (e.g. missing Metal kernels) until they land in ggml-org/llama.cpp.
