# llama-oneclick

One-click Windows launcher for [llama.cpp](https://github.com/ggml-org/llama.cpp) on **dual-GPU NVIDIA** rigs — built for running a local LLM behind [Hermes Agent](https://github.com/NousResearch/hermes-agent) without touching a terminal.

Tested on: Windows 11, RTX 4090 (24 GB, GPU 0) + RTX PRO 4500 Blackwell (32 GB, GPU 1), llama.cpp `llama-server` (CUDA 12 build).

## What it does

`llama-oneclick.ps1` runs in one shot:

1. **Detects GPUs** via `nvidia-smi` (falls back to registry for AMD/Intel → Vulkan backend).
2. **Picks the backend and split ratio** from total VRAM — dual mode tensor-splits the model across both cards (e.g. `43,57` for a 24 GB + 32 GB pair); single mode pins everything to GPU 0.
3. **Starts `llama-server` in router mode** on port 8080 (auto-increments if the port is taken), with:
   - vision support via mmproj (the model can see images),
   - configurable thinking mode (`off` / `on` / `auto`) for Qwen3 / DeepSeek-R1 style models,
   - optional YaRN long-context extrapolation,
   - per-model overrides from `presets.ini`.
4. **Auto-starts a local embedding server** (bge-small-zh-v1.5, CPU) on port 8099 for Mem0 semantic search — OpenAI-compatible `/v1/embeddings`.

## Usage

```powershell
# Dual mode (default): tensor-split across both GPUs
powershell -File llama-oneclick.ps1

# Single mode: LLM on GPU 0 only, GPU 1 (PRO 4500) left for ComfyUI
powershell -File llama-oneclick.ps1 -Mode single
```

`start-llm-comfy.ps1` is a companion script for the "ComfyUI is active" scenario: it starts the LLM in single mode and documents the `CUDA_VISIBLE_DEVICES=1` requirement so ComfyUI doesn't steal the 4090's VRAM.

## Layout

```
llama-oneclick/
├── llama-oneclick.ps1    # main launcher (dual/single mode)
├── start-llm-comfy.ps1   # companion: LLM + ComfyUI coexistence
├── presets.ini           # per-model overrides (ctx-size, mmproj paths)
└── models/               # put your .gguf files here
```

## Hermes Agent integration

Point Hermes at the local server:

- Provider: `custom` (OpenAI-compatible), base URL `http://localhost:8080/v1`
- Model: whatever `llama-server` reports (the `.gguf` filename is the real model — Hermes' display label is just a tag)
- Memory: Mem0 OSS with the local embedding server on port 8099

## Notes & gotchas

- llama.cpp v0.6.0-dev uses `--port`, not `-p`.
- `Start-Process -WindowStyle Hidden` **without** `-RedirectStandardOutput` hangs the parent script — redirect to a log file.
- The mmproj path in `presets.ini` is machine-specific; adjust it for your layout.
- YaRN is global at startup: enabling it degrades short-context quality and does not shrink the KV cache.

## License

MIT
