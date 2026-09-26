# WIRE-PRE proof (lane wire-pre)

Residual from TOP10-CODE-PROOF: Swift sends preserved bytes, but Rust
wrapped everything in `<p>` (`send_message_with_client`) — HTML
collapses whitespace in OTHER clients. Fix: emit `<pre>` for fenced
blocks on the wire.

## Seam

Rust-side detection in `rust/ost/src/api/chat.rs`. No FFI/Swift change.
`build_message_html` mirrors Swift `CodeBlocks` fence grammar
(```/~~~, ≥3 run, info w/o fence char, closer ≥ opener, unclosed runs
to end, 50-block cap, extras stay prose).

- Fenced block → `<pre>` (fences/info consumed, code byte-exact modulo
  HTML-escaping). Mixed messages → `<p>` prose + `<pre>` code segments.
- Fence-less prose → legacy single-`<p>` bit-identical.
- Send + edit + reply bodies route through it (`send_message_body`
  captured-body seam; `edit_message_body`, `build_reply_html` reuse).
- Out of scope, untouched: `notes.rs` `<p>` wrap (OneNote surface),
  Swift render, FFI signatures.

## Accept evidence (captured wire bodies, no network)

Fenced send ` ```swift\nlet x  =  1\n\tindented\n``` ` posts
`content: "<pre>let x  =  1\n\tindented</pre>"` — double spaces + tab
verbatim inside `<pre>` (test `wire_fenced_block_byte_exact_pre`).

Prose send `a<b>&"'` posts `content: "<p>a&lt;b&gt;&amp;&quot;&#39;..."`
— identical to pre-lane shape (test `wire_prose_unchanged_single_p`;
existing `edit_url_and_body_shape` + reply round-trip still green).

## Tests

`cargo test --lib` in `rust/ost`: 282 passed, 0 failed (6 new `wire_*`,
all in `src/api/chat.rs` mod tests — maintained, colocated).
`cargo check` ostmac-core clean (5 pre-existing warnings, untouched
crate). `swift build` complete (link warnings only, macOS-version drift,
pre-existing). Full gate parent-side post-merge.

Ledger: `rust/ost/OSTMAC-PATCHES.md` §60 [minor], UNFILED.

## Shots

None: non-visual lane. Wire HTML bytes only; no UI surface changed.
Own-client render of incoming `<pre>` already covered by top10-code.
