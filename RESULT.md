# Content search in FinderSearch

Outcome: the search field now searches inside files. Pick "Contents" in the scope bar, or type `grep:`, `regex:`, `sym:` (also `content:`, `symbol:`). Results list each file once with its matching lines under it (line number, highlighted match). Return or double-click opens the file; Quick Look works. Name search is unchanged.

Branch: herdr/findersear-findersearch-cont. SHA: see `git log -1`.

Build green. Tests green except MarqueeSelectionTests, which crashes/asserts in this headless run (window-layout test; not touched by this change, not checked against baseline).

## Reply JSON shape (fsearch stdio, op grep)
{"ok":true,"files":[{"path":"...","git":"M"?,"matches":[{"line":3,"col":148,"ranges":[[148,164]],"text":"...","def":true?,"before":[..]?,"after":[..]?}]}],"complete":bool,"indexing":n,"next":n?,"candidates":n,"read":n,"source":"scan|index","took_us":n}

## Verified
Request `{"q":"grep:ROUTING-STRATEGY","in":".../harness-lab/docs"}` and the explicit `{"op":"grep","pattern":...,"mode":"literal"}` form both return 7 files, 15 matching lines (checked against fsearch stdio directly; the shared daemon was not touched by running the Swift Engine). App launched with `open -g`. No screenshot (screencapture -l failed).

## Design review
impeccable-finish-reviewer applied: bigger chevron target, VoiceOver expand/collapse, match-row context menu, column alignment, leading-whitespace trim, Kind hidden in contents mode. Not done: per-row selection tint, windowing long lines around the match, segmented This Mac/folder control.
