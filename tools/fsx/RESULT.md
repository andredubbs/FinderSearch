# fsx: router and reranker done

`fsx query "where do we decide model routing"` returns `~/Projects/harness-lab/docs/ROUTING-STRATEGY.md` at rank 2 (a canonical ADR ranks 1).
`fsx query "ext:md grep:turbopuffer in:~/Projects/estate-kg-live/docs"` takes the fast path, 0 Typesafe calls, ~11 ms.

Branch `feat/fsx-router` (origin andredubbs/FinderSearch). SHA in the commit log; see `git log -1 feat/fsx-router`.

## Measured (10 queries, stdio, cold cache, estate off)
- Without Typesafe: p50 20 ms.
- With Typesafe: p50 about 1.0 s (range 0.5 to 1.4 s).
- Typesafe calls per query: 2 cold (one route, one batched rerank of up to 40), 0 warm (disk cache), 0 on the fast path.
- Estate (tkg) takes 25 s or more even for one source, so it gets a 5 s budget and usually times out. Docs grep covers the gap.

## How FinderSearch should call it
Spawn `tools/fsx/fsx stdio` once and keep it open; send `{"q":"..."}` per line, read one JSON line back (`hits` carry `source` and `score`).
Send `"typesafe":false` for keystroke-by-keystroke search and `true` on submit. One-shot: `fsx query "<text>" --json` (adds about 1.5 s of startup).

## Open
- Semantic is a stub for `jg` (jevgrep, not installed). Final engine pending the bake-off.
- tkg estate search is too slow for interactive use; hits only map to paths when the output contains them.
- fsearch caps name hits at about 50 per query, so recall for pure name search relies on the docs and keyword nets.
