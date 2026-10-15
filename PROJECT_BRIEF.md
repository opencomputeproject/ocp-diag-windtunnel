# Project: Private AI Cluster

## Thesis

Build a fully **private, self-hosted AI cluster** on varied platforms,
provisioned step by step and captured as reusable recipes so a **new cluster can
be brought up from scratch** by following this folder.

The cluster serves two workloads:

1. **AI / agentic development** — Jupyter + Python environments for building and
   running agents and experiments.
2. **A swappable LLM stack** — serve/train models that can be exchanged
   (Gemma → Qwen → frontier weights) without re-architecting the platform.

## Long-horizon goal: models usable from this VS Code

The LLM plane should expose an **OpenAI-compatible endpoint** on the LAN
so the models running can be consumed directly inside varied code workspaces. 
Swapping the model on the box then swaps the model available to the editor. 
Kept as a north star that shapes earlier choices:

- Prefer serving stacks that expose an OpenAI-compatible API (vLLM natively;
  Ollama via its OpenAI-compat endpoint) so VS Code / agent extensions can
  point at the setup with minimal glue.
- Keep the endpoint stable while weights change underneath
- Integration path TBD (e.g. Copilot custom/BYOK model, or an extension like
  Continue) — revisited once the serving plane exists.

## Principles

- **Base first.** Everything depends on a verified base layer: kernel, driver,
  CUDA, container runtime, storage and env conventions. Build and confirm that
  before any application layer.
- **Vendor-optimized, container-first.** Prefer containers (PyTorch, vLLM, TensorRT-LLM, Jupyter/ML) 
  over host-level installs. The host stays clean; everything runs as containers 
  we can bring **up and down** on demand.
- **Dockerized by default.** Components run in containers for isolation and
  reproducibility; the host stays clean.
- **Environment flexibility.** Support multiple isolated Python environments
  (venv / conda) per project rather than one global mess.
- **Private by design.** Runs on our LAN, no dependency on external inference
  APIs for the core stack.
- **Grounded in real facts.** Recipes are written against confirmed output from
  the actual machine (see `recipes/00-spark-facts.md`), backed by vendor docs.
- **Recipe folder = source of truth.** This repo is the reproducible build book
  for new nodes, not scratch notes.

## Target architecture (evolving)

```
Host (DGX OS, aarch64)
├── Base layer:   driver + CUDA + NVIDIA Container Toolkit (preinstalled)
├── Docker:       GPU-enabled container runtime (--gpus=all)
├── Dev plane:    NGC Jupyter/ML container (PyTorch + full ML libs), up/down
└── LLM plane:    NGC model server (vLLM / TensorRT-LLM) — swappable weights
                  + optional training/fine-tune jobs
```
