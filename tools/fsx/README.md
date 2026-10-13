# fsx

Query router and reranker for FinderSearch. Typesafe AI (not TypeScript) makes every bounded decision.

    tools/fsx/fsx query "<text>" [--json] [--no-typesafe] [--no-rerank]
    tools/fsx/fsx stdio        # one JSON request per line: {"q":"...","rerank":true,"typesafe":true}

Reply per line: `{"hits":[...],"mode","path","ms","typesafe_calls"}`. Hits keep the fsearch shape
(`kind`, `path`, `mtime`, `size`) plus `source` (name|content|symbol|semantic|estate|docs) and `score`
(0..1 after rerank; `reranked:true`). Content hits add `line` and `text`. `copies` counts worktree duplicates folded in.

## Flow
1. Fast path: any of `grep: ext: sym: in: name: estate: sem:` skips Typesafe entirely.
2. Otherwise one Typesafe `choice` call picks name | content | symbol | semantic | estate. Below 0.5 confidence it falls back to name.
   Obvious filters (`~/path`, `.md`, "markdown") are extracted by regex.
3. Natural-language modes also run recall nets (docs/ phrase grep across ~/Projects/*/docs, keyword name fan-out).
4. One batched Typesafe call scores the top 40 candidates (yes/no per candidate) and reranks.
5. Decisions are cached on disk in `~/.cache/fsx` keyed by query and candidate set. Warm queries cost 0 calls.

Backends: `fsearch stdio` for name/content/symbol; `tkg search` via spine for estate (slow, 5 s budget, env `FSX_ESTATE_TIMEOUT`, `FSX_ESTATE=0` to skip);
`semantic` shells out to `jg` (jevgrep) when installed, else returns a "not installed" note. The engine is still being chosen.

Needs `~/.local/share/typesafe-venv` and `spine`; `fsx` injects the key itself. Tests: `~/.local/share/typesafe-venv/bin/python -m unittest discover -s tests`. Latency: `python bench.py`.
