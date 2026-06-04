# Maxima kernel events channel

Status: proposed
Scope: a host (transport), the editor frontend (renderer), Maxima core (one
small hook), the new `maxima-events` package.

This doc defines the **protocol** — the events channel that flows
structured messages from the Maxima kernel to embedding hosts (the embedding host
today, potentially others later). It is the foundation that lets us
retire the host's current sentinel-based stdout-parsing pipeline.

For the **first consumer** of this protocol — per-view streaming, with
a SUNDIALS-based proof of concept and a cancellation design — see
[streaming.md](streaming.md). Streaming envelopes (`stream_begin`,
`frame`, etc.), the cancellation fd 4 channel, and the Patch 2 `mdo`
cancellation hook all live there.

This is one of two design docs in this repo:

1. **This doc** — the kernel events protocol.
2. [streaming.md](streaming.md) — the first consumer of the protocol:
   per-view streaming with a SUNDIALS PoC.

## Summary

Add a third communication channel from the Maxima kernel to the
frontend: **fd 3** (inheritable pipe) from Maxima to host, carrying
newline-delimited JSON envelopes describing structured kernel events.
An embedding host forwards each envelope to the editor frontend as an MCP
notification. The extension forwards to the renderer via VS Code's
notebook renderer messaging API.

The envelope grammar catalogues every kind of kernel event the embedding host
currently reconstructs from stdout parsing (eval lifecycle, output,
display, error, debug-prompt entry, stdin requests) — plus extensible
slots for new event types like the per-view streaming envelopes used
by [streaming.md](streaming.md).

The total architectural change is small (~400 LOC plus one ~20-line
upstream Maxima patch). Migration from the current sentinel pipeline is
incremental — both pipelines run concurrently while each event type
moves over.

## Scope: from streaming to general kernel events

The streaming use case (per-view frames, slider-cancels-stream) is the
*first consumer* of the events channel, not its only purpose. The
channel and its envelope vocabulary are designed to be general enough
that the existing sentinel-based stdout pipeline can be retired through
it, one event type at a time.

### What a host reconstructs from stdout today

`the host parser module ` (~4700 LOC across the module)
contains substantial machinery dedicated to inferring kernel events
from textual output:

| An embedding host code | What it's doing | Cost |
|-------------|-----------------|------|
| `protocol.rs:10–12` — `EVAL_SENTINEL`, `VARS_SENTINEL`, `VARS_START` | Injected text markers framing user code | Five sentinel strings plus LaTeX-escape variants |
| `process.rs:430` — `ERROR_MARKERS` scan | Detect that an error has happened so we know to wait for the debugger prompt | Grace-period state machine for debugger arrival |
| `process.rs:572, 623` — `detect_debugger_prompt` | Recognise `(dbm:N>` and SBCL `0]` prompts | Pattern-matching on partial reads |
| `parser.rs:464` — `PLOTLY_PATH_RE` scan | Scan output text for `.plotly.json` temp-file paths emitted by plot functions | Per-mime regex + path-safety check + temp-file read |
| `parser.rs:273` | Strip sentinel lines (and their LaTeX-escaped variants) from `text_output` | Required because sentinels leak into displayed output |

Each piece works, but every new feature adds another pattern. The
trajectory is shared with every project that started by parsing
interpreter output (Jupyter, GDB, SLIME, IPython); the convergent
answer is a structured event channel.

### What the events channel replaces

The fd 3 channel and its envelope grammar absorb every responsibility
above into typed messages:

| An embedding host pattern today | Event type that retires it |
|----------------------|------------------------------|
| `__EVAL_END__` sentinel injection + scan | `eval_begin` / `eval_end` envelopes |
| `__VARS__` / `__VARS_END__` | `vars` envelope |
| `__LABEL__` + linenum print | `eval_result` envelope (carries `output_label` field) |
| Stdout text capture + sentinel stripping | `output` envelopes (stream-wrapped, see [§ Output during evaluation](#output-during-evaluation-multi-write-statements-and-stream-wrapping)) |
| Injected `tex(%);` + LaTeX block extraction | `eval_result` envelope with a mime bundle (see [§ Display events and mime bundles](#display-events-and-mime-bundles)) |
| `.plotly.json` temp-file path scan + safety check + file read | `display` envelope with `mime: application/x-maxima-plotly` and inline payload |
| `.png` / `.svg` temp-file scan | Same — `display` envelope with the appropriate mime |
| `ERROR_MARKERS` scan + debugger-arrival grace period | `error` envelope with structured info; `debug_enter` envelope when entering the debugger |
| `(dbm:N>` prompt detection | `debug_enter` envelope; `debug_leave` envelope |
| SBCL `0]` prompt detection | Same — `debug_enter` with `level: lisp` |
| Stdin requests (currently blocks/breaks) | `stdin_request` envelope; `stdin_response` MCP tool call back |

None of this needs to happen at once. The pipeline runs alongside the
events channel and each row migrates when its event-type producer is
implemented kernel-side. See [§ Migration from the sentinel pipeline](#migration-from-the-sentinel-pipeline)
for the incremental plan.

## Prior discussion and parallel work

The events-channel design is not new ground in the Maxima community.
Several threads on `maxima-discuss` and one active parallel project
have been wrestling with the same problem from different angles. This
section catalogues that prior art so that the design and the eventual
upstream pitch can be grounded in existing community demand rather than
proposed as speculative new infrastructure.

### Existing community demand

**"Easy parseable, machine readable, input and output interface for
Maxima" — Mar 2022 (sf_id 37619516).** Wolfgang Dautermann opened a
thread asking for structured output for frontend consumption. Replies
from Robert Dodier (sf_id 37619772), Gunter Königsmann (37619813,
37620792), Leo Butler (37620145), Stavros Macrakis, and Richard
Fateman. Consensus that the need is real; no agreement on the format
(XML vs JSON vs S-expressions); fizzled without a patch landing.
Dautermann re-raised the topic in Oct 2022 (37724116) as one of the
named goals for Maxima development: "Maxima should support — out of
the box — some sort of machine readable output. JSON. XML. Or
something else. Something standardized."

**"MCP server" thread — Mar 2026 (sf_id 59303988, ongoing).** Richard
Fateman opened with "Anyone looking at hooking up maxima to AI via
MCP?" The thread quickly broadened beyond LLM tool-calling into the
same structured-output question. Two messages worth quoting in full:

- **Leo Butler (sf_id 59305197, 2026-03-06)** explicitly proposed
  what this design is: *"IMO, far more useful would be to code a
  `message' interface in Maxima that would enable Maxima to
  communicate in `machine-readable form.' I think this is a frequent
  request of Wolfgang's. Right now, there's 50+ years of code that
  throws strings at a terminal..."*
- **Stavros Macrakis (sf_id 59300212, 2026-02-24)** named the
  prerequisite: *"We can make that easier by supporting the Model
  Context Protocol (MCP), which would require us to clean up some of
  the long-standing issues around non-interactive use of Maxima."*

This thread is the most recent and most direct community precedent for
the kernel-events channel. Leo Butler's framing is essentially the
elevator pitch for this doc.

### Parallel project: `maxima_mcp`

In the same MCP thread, **Dimiter Prodanov (IICT) announced an active
in-process MCP server at https://github.com/vibrate-project/maxima_mcp**
(sf_id 59309190, 2026-03-14). The project is ~860 LOC of pure-SBCL
Lisp, Apache 2.0 licensed, dependency-free (uses `sb-bsd-sockets` and
`sb-thread` only), and runs as a Lisp thread inside the Maxima
process. It exposes HTTP endpoints:

- `/tool-call` — JSON `{"expression": "..."}` → returns the result as
  a single text string via `mread` + `meval` + `mgrind`
- `/mcp` — full MCP protocol over JSON-RPC 2.0: `initialize`,
  `tools/list`, `tools/call`
- `/load`, `/functsource`, `/help`, `/listfunctions` — convenience
  endpoints
- `/mcp` (GET, SSE) — server-sent events, *currently used only for
  keepalive heartbeats*

**The architectural relationship to this design.** `maxima_mcp` is
in-process (Lisp thread in Maxima); a host is out-of-process (Maxima
spawned as a child of a Rust host). These are complementary deployment
shapes, not competing designs. Both face the same underlying problems:

| Pain point in `maxima_mcp` (current state) | What kernel-events provides |
|---------------------------------------------|------------------------------|
| All output is `{"type": "text"}` — no LaTeX, no plots, no MathML | `display` envelope with [mime bundle](#display-events-and-mime-bundles) |
| Error suffix stripping at `mcp_server.lisp:304–310` (`"-- an error. To debug this try: debugmode(true);"`) | Structured `error` envelope with `kind`/`message`/`location` |
| No debugger handling — `meval` entering `dbm:` hangs the request | [`debug_enter`/`debug_leave`](#debug_enter) envelopes |
| No cancellation — long evaluations block the request thread | fd 4 + `*cancel-flag*` (see [streaming.md § Cancellation](streaming.md#cancellation)) |
| No streaming — each request is request/response | [`stream_begin`/`frame`/`stream_end`](streaming.md#streaming-envelopes) |
| `*sse-streams*` infrastructure exists but only sends heartbeats | The SSE stream is the natural place to push kernel events |

The most striking observation: `maxima_mcp`'s SSE machinery
(`*sse-streams*`, `*sse-lock*`, `handle-mcp-sse`) is *already in place*
but currently pushes nothing except 5-second heartbeats. A small change
would push every kernel-events envelope as an SSE event, making
`maxima_mcp` a second transport for the events channel alongside
the host's fd 3.

**Three coordination options**, in increasing scope:

1. **Light**: `maxima_mcp` adopts the `maxima-events` Lisp package's
   mime-bundle builder internally. `/tool-call` returns richer MCP
   content arrays (text + LaTeX + plot data). ~50 LOC change.
2. **Medium**: `maxima_mcp` wires its SSE endpoint to the events
   channel. Notebook frontends gain a working HTTP-based transport
   without needing the fd-3 setup. ~200 LOC change.
3. **Deep**: shared `maxima-events` package becomes the substrate for
   both. `maxima_mcp` is the MCP-over-HTTP transport; a host is the
   MCP-over-fd-3 transport. Each owns its transport; the kernel-side
   producer is shared.

I'd start with option 1 (validates the shared package), then move to
option 2 (gives notebook frontends a fallback transport). Option 3 is
the longer conversation.

### Existing structured-output mechanism: `alt-display`

Leo Butler's `alt-display` package (in `share/contrib/alt-display`)
is the existing user-level mechanism for structured output. It works
by *replacing* the display function (`set_alt_display(2,
my_display_fn)`) so that every result echo goes through a
user-provided formatter that can produce MathML, TeX, HTML, etc.
wxMaxima uses this plus `*prompt-prefix*` / `*prompt-suffix*`
markers as its kernel protocol.

The 2022 thread (sf_id 37620469, Dautermann's reply to Butler)
identified the limitation: even with `alt-display` active, user code
can `printf(true, "...")` arbitrary text to stdout that the frontend
will mis-parse as output. The kernel-events channel solves this
because the structured output is on a *separate fd*; user code printing
to stdout flows through the `output` envelopes with explicit
`eval_id` tagging and `stream: "stdout"` discrimination.

This design does not replace `alt-display`; it adds an out-of-band
channel for events. The two compose: `alt-display` users get their
displayed values routed through `display` envelopes naturally, and the
new event types (`debug_enter`, `frame`, `stream_begin`, …) become
available without changing the display path.

### Cancellation prior art: Fateman's "stopme"

Richard Fateman prototyped a timeout mechanism in Apr 2016 (sf_id
35052716, 35052789) — "stopme takes 2 arguments. An expression to
evaluate and a time limit in seconds." Implementation used SBCL
threads (`sb-thread`). Discussed favourably but never landed.
Concerns: cross-Lisp portability (other Lisps' threading is
different), reliability of mid-evaluation thread interruption, the
foreign-call-boundary problem during BLAS/LAPACK calls.

The 2017 wxMaxima interruption-reliability thread (sf_id 35697912)
documented student-visible bugs where the Maxima "interrupt" button
either crashed wxMaxima or did nothing — issues that persist today.

This design's cancellation approach
([streaming.md § Cancellation](streaming.md#cancellation)) avoids
threads-as-interruption-mechanism entirely. A polling Lisp thread
reads a cancel fd and sets a flag; the main evaluation thread checks
the flag at well-defined opt-in points (the SUNDIALS RHS callback;
optionally `mdo`). This is closer in spirit to how interruption is
handled in long-running C libraries (check a flag every N iterations)
than to Fateman's threads-based approach. Cross-Lisp portable; no
foreign-call-boundary problem.

### Architectural precedent: `src/server.lisp`'s socket mode

Maxima already has a precedent for "host hands me an alternate fd; I
open it as a Lisp stream and use it for non-tty output". `src/server.lisp:44–58`
rebinds `*standard-output*`, `*error-output*`, `*trace-output*`, and
`*debug-io*` onto a socket when the kernel was launched with the
socket-mode flag. `src/server.lisp:88–104` uses platform-specific
`make-fd-stream` to wrap the inherited fd:

```lisp
#+scl (sys:make-fd-stream (ext:connect-to-inet-socket host port) ...)
#+cmu (sys:make-fd-stream (ext:connect-to-inet-socket host port) ...)
```

The kernel-events channel generalises this from "alternate fd
*replaces* tty" to "alternate fd *runs alongside* tty for
out-of-band structured data". This is the strongest argument for the
upstream Patch 1 — we are not introducing a new IPC mechanism, we are
extending an existing one in a strictly additive direction.

### Likely allies and expected objections

Based on the prior-art reading:

| Person | Stance to expect |
|--------|------------------|
| **Gunter Königsmann** (wxMaxima maintainer) | Strong ally — wxMaxima would benefit directly from being able to retire its `*prompt-prefix*`-marker parsing; he opened the 2017 wxMaxima interruption thread and replied to the 2022 structured-output thread |
| **Leo Butler** | Strong ally — explicitly proposed "a `message' interface in Maxima" in the 2026 MCP thread; author of `alt-display` so he understands the limits of the existing mechanism |
| **Stavros Macrakis** | Supportive — explicitly named "non-interactive use of Maxima" as needing cleanup |
| **Robert Dodier** | Procedurally cautious but accepts small additive patches; prefers `share/` over core unless necessary; has worked on fork/pipe for parallel execution (sf_id 59125912, Feb 2025) so familiar with the relevant abstractions |
| **Dimiter Prodanov** | Active co-traveller via `maxima_mcp`; coordination is a natural conversation |
| **Richard Fateman** | Skeptical of wire-protocol overhead; tends to defer to the consensus; would care about not adding bloat to the no-frontend case |
| **Raymond Toy** | Pragmatic, focused on cross-Lisp portability — the patches must work cleanly on SBCL/CLISP/CCL/ECL |

Expected objections and pre-empts:

- *"Why not just use `alt-display` + markers in stdout?"* — Answer:
  user code can still `printf` text that confuses the markers. The
  out-of-band channel is the cleanest fix. Cite Dautermann's same
  concern from the 2022 thread.
- *"Why not just convert all output to JSON?"* — Answer: that breaks
  every existing interactive use. The events channel is strictly
  additive and zero-cost when not used.
- *"What about CLISP/CCL/ECL?"* — Answer: the patch handles all four
  via `#+` reader macros (same pattern `server.lisp:88–104` uses).

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│ Maxima (CL)                                                        │
│   eval driver and library code                                     │
│     ($show, $emit_display, $emit_frame, output stream wrapping)    │
│       → write JSON envelope to *maxima-events-out*                 │
│                                  ▼                                 │
└────────────────────────────────────fd 3 (write end)────────────────┘
                                     │
                                     │ JSON-lines, push
                                     ▼
┌────────────────────────────────────────────────────────────────────┐
│ a host (Rust)                                                      │
│   per-session reader task on fd 3 → MCP notifications              │
│   notifications/maxima_kernel_event { type, eval_id, payload, … }  │
└────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ MCP push over streamable HTTP
                                     ▼
┌────────────────────────────────────────────────────────────────────┐
│ the editor frontend (TS)                                              │
│   McpProcessManager subscribes to notifications/maxima_kernel_event│
│   forwards via createRendererMessaging → renderer iframe           │
└────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ postMessage
                                     ▼
┌────────────────────────────────────────────────────────────────────┐
│ renderer (custom notebook renderer)                                │
│   per-type dispatch:                                               │
│     output      → cell text area                                   │
│     display     → cell output (rendered from mime bundle)          │
│     eval_result → cell result area                                 │
│     stream_*    → per-view DOM nodes (see streaming.md)            │
│     debug_enter → debugger UI                                      │
│     stdin_request → input prompt                                   │
└────────────────────────────────────────────────────────────────────┘
```

Reverse-direction control (cancellation, stdin responses) flows over
additional pipes / MCP tools — see [streaming.md § Cancellation](streaming.md#cancellation)
and [§ `stdin_request`](#stdin_request) below for the specifics.

Three legs, three transports — each appropriate to its leg:

| Leg | Transport | Why |
|-----|-----------|-----|
| Maxima → host | fd 3 (inheritable pipe), JSON-lines | Binary-safe, zero escaping, POSIX-standard, no new IPC machinery |
| host → extension | MCP `notifications/*` over existing HTTP | Reuses the existing connection; MCP SDK already supports it |
| extension → renderer | VS Code `createRendererMessaging` postMessage | Native VS Code API; iframe-safe |

## Maxima → host: the fd 3 channel

### Why fd 3, not stdout

Maxima rebinds `*standard-output*` during evaluation (text output is
captured and returned in `EvalResult.text_output`). Stdout is also where
the MCP server reads the startup info line (`mcpClient.ts:245`). Using
stdout for stream frames would either fight that capture or pollute the
text output channel.

A second inheritable pipe (fd 3 on the Maxima child's side) is opened by
a host at spawn time and held open for the lifetime of the session. Maxima
opens fd 3 once at session init, holds it as `*maxima-events-out*`, writes
newline-delimited JSON envelopes, and `force-output`s after each.

The Maxima child sees fd 3 as a plain output stream — no awareness of
the host's port, auth token, or HTTP. It just writes lines. This keeps the
Maxima Lisp code transport-agnostic and trivial to test in isolation
(redirect fd 3 to a file in a unit test).

### Windows fallback

Inheritable pipes work the same on Windows (CreateProcess + handle
inheritance), but the fd number isn't fixed. The Lisp side discovers the
write handle via an env var (`MAXIMA_EVENTS_FD`) set by a host at spawn.
On POSIX the env var holds `"3"`; on Windows it holds the inherited
handle number. The Lisp side opens whatever it finds.

### Lisp-side API (in a new `maxima-events` package — pure Lisp, no
Maxima core changes here)

```lisp
(defpackage :maxima-events
  (:use :cl)
  (:export #:*events-out* #:open-stream #:close-stream
           #:write-envelope))

(in-package :maxima-events)

(defvar *events-out* nil
  "Output stream for view-frame envelopes.  NIL when streaming
   isn't available (e.g. CLI Maxima, unit tests).")

(defvar *frame-seq* 0)

(defun open-stream ()
  "Open the fd indicated by MAXIMA_EVENTS_FD (POSIX: an integer fd;
   Windows: an inherited handle number).  Returns the stream or NIL."
  (let ((fd (uiop:getenv \"MAXIMA_EVENTS_FD\")))
    (when fd
      (setf *events-out*
            #+sbcl (sb-sys:make-fd-stream
                     (parse-integer fd)
                     :output t :external-format :utf-8 :buffering :line)
            #-sbcl (error \"streaming requires SBCL today\")))))

(defun close-stream ()
  (when *events-out*
    (close *events-out*)
    (setf *events-out* nil)))

(defun write-envelope (envelope-json)
  \"Write one envelope as a single line.  No-op if not streaming.\"
  (when *events-out*
    (write-line envelope-json *events-out*)
    (force-output *events-out*)))
```

If [Patch 1](#patch-1-extend-server-lisps-alternate-i-o-setup-to-add-a-side-channel)
lands upstream, Maxima core itself opens the fd from `MAXIMA_EVENTS_FD`
and binds it as `maxima::*maxima-events-out*`. The
`maxima-events` package then drops its own `open-stream` and simply
defines `*events-out*` as an alias for the core-provided binding. The
write path (`write-envelope`) is unchanged either way. This is the
"one writer helper, two places it might get its stream from"
arrangement that keeps the package working with both stock Maxima
(monkey-patched at load time) and patched Maxima (uses the core
variable directly).

### Maxima-callable API (the `streaming` package, also pure Lisp +
.mac)

```maxima
load(\"streaming\")$

emit_frame(view_id, payload)$       /* one frame */
emit_progress(view_id, fraction)$   /* 0..1 progress */
emit_log(view_id, message)$         /* attached log line */
emit_done(view_id)$                 /* end of stream */
emit_error(view_id, message)$       /* end of stream, with error */
```

Lisp implementation (`$emit_frame` etc.) is a thin wrapper around
`maxima-events:write-envelope` that builds the JSON envelope. The
payload conversion `mexpr-to-json` reuses the JSON helpers from
`a plot library's emission helpers` (``, ``,
``) — extracted into a shared package to avoid duplication.

### Reused Maxima patterns

The design above is not novel; every piece mirrors an existing pattern
in Maxima's source. Spelling these out makes the upstream story
narrower and easier to motivate.

| Our piece | Mirrors | Maxima source |
|-----------|---------|---------------|
| `maxima-events:write-envelope(value, stream)` | `mgrind(x, out)` — write structured representation to a stream | `src/grind.lisp:61` |
| `*maxima-events-out*` (special variable holding the side channel) | `*socket-connection*` — bound when the kernel has a non-tty I/O channel | `src/server.lisp:16` |
| Opening fd 3 as a stream via `sb-sys:make-fd-stream` | The same call is already used to wrap socket fds when running as a remote backend | `src/server.lisp:88–104` |
| Optional `with_view_stream(view_id, body)` Maxima-level scoping macro (if we add it later) | `$with_stdout(stream, body)` — `progv` rebind + `meval*` + `unwind-protect` | `src/macsys.lisp:654–678` |
| Future transcript-mirror (if we ever want envelope flow to also be visible in the cell's text output) | `$appendfile` — `make-broadcast-stream` + `make-echo-stream` fan-out | `src/macsys.lisp:585–592` |
| `$events_stream_enabled` boolean global | `$file_output_append` — Maxima-callable `defmvar` flag controlling I/O behaviour | `src/globals.lisp:1480` |

The most important precedent is **`src/server.lisp`**: Maxima already
has an alternate-I/O mode where the kernel's standard streams are
redirected onto a socket inherited from the launcher. Lines 44–58
rebind `*standard-output*`, `*error-output*`, `*trace-output*`, and
`*debug-io*` when `*socket-connection*` is set; lines 88–104 use
platform-specific `make-fd-stream` calls to wrap the inherited fd:

```lisp
#+scl (sys:make-fd-stream (ext:connect-to-inet-socket host port) ...)
#+cmu (sys:make-fd-stream (ext:connect-to-inet-socket host port) ...)
```

This is the strongest argument for the upstream patch: we are not
introducing a new IPC mechanism, we are extending an existing one.
Maxima already understands "launcher hands me an alternate fd; I open
it as a stream and use it for non-tty output". Our patch generalises
that from "replaces tty" to "alongside tty, for out-of-band data".

### Patterns we deliberately do **not** reuse

A few things in Maxima look superficially similar but are the wrong
fit; flagging so the upstream conversation doesn't get derailed by
"why not just use X?":

- **`mtell` / `mtell-open` (`src/mformt.lisp:141`)** and
  **`displa` (`src/displa.lisp:47`)** target `*standard-output*`
  implicitly. We deliberately bypass these — envelope JSON is a
  parallel channel, not a redirect. Reusing `mtell` would mean
  envelope JSON appearing in `EvalResult.text_output`, which is the
  exact problem the fd 3 design solves.
- **`dribble`-based transcript in `$writefile`
  (`src/macsys.lisp:622–634`)** is OS-level terminal mirroring tied to
  the TTY. It doesn't compose with our use case (Maxima is already
  running headless under host).
- **Maxima init hooks.** There are none, as confirmed by the survey
  — no `*output-init-hooks*` or similar registry. Any "session-init
  hook" assumption is wishful thinking; we follow Maxima's actual
  idiom of editing `init-cl.lisp` directly. See
  [§ Patch 1](#patch-1-extend-server-lisps-alternate-i-o-setup-to-add-a-side-channel)
  below for the concrete shape.

## An embedding host side: spawn + reader + MCP notification push

### Spawn change

`McpProcessManager` (in host; mirrors the TS-side
`mcpClient.ts:173`) currently spawns Maxima with `["--http", "--port",
"0", "--allow-dangerous"]` and inherits stdin/stdout/stderr. The change:

```rust
// Before
.stdio([Ignore, Pipe, Pipe])

// After
let (stream_read, stream_write) = pipe()?;  // OS pipe
.stdio([Ignore, Pipe, Pipe])
.env(\"MAXIMA_EVENTS_FD\", \"3\")
.fd(3, stream_write)                         // inherited fd 3
.spawn();
// a host reads from stream_read
```

The session entry now carries the read end of the pipe:

```rust
struct Session {
    session_id: String,
    process: Child,
    stream_reader: PipeReader,  // ← new
    cancel_writer: PipeWriter,  // ← new, fd 4 (see Cancellation)
    // …
}
```

### Reader task

For each session, a host spawns an async task that reads `stream_reader`
line-by-line, parses each line as a JSON envelope, and forwards it as
an MCP notification. ~80 LOC of straightforward tokio.

```rust
async fn pump_stream(session_id: String, mut rdr: BufReader<PipeReader>,
                     notifier: McpNotifier) -> Result<()> {
    let mut line = String::new();
    while rdr.read_line(&mut line).await? > 0 {
        match serde_json::from_str::<Envelope>(&line) {
            Ok(env) => notifier.send(
                \"notifications/maxima_view_frame\",
                json!({ \"session_id\": session_id, \"envelope\": env })
            ).await?,
            Err(e) => tracing::warn!(?e, ?line, \"bad envelope\"),
        }
        line.clear();
    }
    Ok(())
}
```

### MCP notification

MCP's spec includes server-initiated notifications. The streamable-HTTP
transport (the one the extension uses today,
`mcpClient.ts:9, 221`) supports SSE for server→client push, and the
`@modelcontextprotocol/sdk` client surface includes `setNotificationHandler`.
No new wire-level work is needed — just register a handler for
`notifications/maxima_view_frame` on the extension side.

The notification payload is the envelope, plus the session_id so the
extension knows which notebook (and which controller) it belongs to.

## Wire protocol — envelope schemas

Machine-readable JSON Schema (Draft 2020-12) definitions for every
envelope type implemented today live in
[`schemas/envelopes/v1/`](../../schemas/envelopes/v1/). The narrative
catalogue below is the design source of truth; the schemas are the
runtime-validatable subset.

All envelopes share a `type` discriminator. JSON-lines, one envelope per
newline. Envelopes are grouped here by lifecycle phase:

- **[Session lifecycle](#session-lifecycle-envelopes)** — emitted once
  per session at startup / shutdown.
- **[Evaluation lifecycle](#evaluation-lifecycle-envelopes)** — emitted
  bracketing each evaluation.
- **[Within-evaluation events](#within-evaluation-events)** — output,
  display, errors, debugger, stdin requests. The bulk of per-eval
  traffic.
- **[Streaming envelopes](#streaming-envelopes)** — per-view frames.
  Can interleave with within-evaluation events.

Every envelope carries an implicit `session_id` field added by the embedding host
on the way out, so the extension knows which notebook the event belongs
to. The kernel itself doesn't track session IDs.

## Session lifecycle envelopes

### `capabilities`

Emitted by the kernel at session start, before any evaluation. Declares
versions and which optional features the kernel supports; the renderer
responds (via an MCP tool call back to host) with which mime types it
can render. Both halves of the negotiation tune cost knobs in the
kernel.

```json
{
  "type": "capabilities",
  "protocol_version": "1",
  "kernel_version": "5.47.0",
  "lisp": "SBCL 2.4.10",
  "packages": ["numerics", "a Plotly-emitting library", "a CVODE-binding package"],
  "supports": ["streaming", "mime_bundles", "stdin_request",
               "structured_errors", "debug_events"]
}
```

`protocol_version` carries the envelope grammar version this build
implements. It matches the schema directory name (`schemas/envelopes/v1/`)
and is the canonical drift-detection field — hosts validating each
capabilities envelope against the schema reject a mismatched version
before consuming the rest of the stream.

The renderer's response, sent via a `negotiate_capabilities` MCP tool
on host, includes the renderer's accepted mime types:

```json
{
  "render_mimes": [
    "application/x-maxima-latex",
    "application/x-maxima-plotly",
    "image/png",
    "image/svg+xml",
    "text/plain"
  ]
}
```

The kernel uses `render_mimes` to gate expensive computations — for
example, it skips computing `application/x-maxima-latex` for
`eval_result` if the renderer hasn't declared it. See
[§ Display events and mime bundles](#display-events-and-mime-bundles)
for the cost story.

### `ready`

Emitted when the kernel is ready to accept the next evaluation. Today
a host infers this from prompt patterns. The envelope replaces it
explicitly:

```json
{ "type": "ready" }
```

## Evaluation lifecycle envelopes

### `eval_begin`

Emitted by the kernel at the start of every evaluation. Carries an
`eval_id` that subsequent within-evaluation events reference.

```json
{
  "type": "eval_begin",
  "eval_id": "e_42",
  "started_at": "2026-06-03T15:21:08.412Z"
}
```

The `eval_id` is generated kernel-side (a counter scoped to the
session). The MCP `evaluate_expression` tool call returns the
`eval_id` synchronously so the extension can correlate.

### `eval_result`

Emitted by the kernel after the last expression in an evaluation
finishes, carrying the value of that expression as a mime bundle. See
[§ Display events and mime bundles](#display-events-and-mime-bundles)
for the bundle semantics.

```json
{
  "type": "eval_result",
  "eval_id": "e_42",
  "output_label": "%o7",
  "suppressed": false,
  "mime_bundle": {
    "text/plain": "1/2",
    "application/x-maxima-latex": "\\frac{1}{2}"
  }
}
```

`suppressed: true` when the user terminated the statement with `$`
(Maxima's "compute but don't display" sigil). The renderer can choose
to elide rendering; the kernel still emits the envelope so
post-processors (logs, etc.) see the value.

### `eval_end`

Emitted by the kernel when the entire evaluation (including any
side effects, displayed values, and streaming views started by it) has
completed.

```json
{
  "type": "eval_end",
  "eval_id": "e_42",
  "status": "ok",
  "duration_ms": 12
}
```

`status` is one of `"ok" | "error" | "cancelled"`. The envelope fires
only when the evaluation actually terminates — returns a value
(`"ok"`), errors out (`"error"`), or aborts to top level
(`"cancelled"`).

`eval_end` does **not** fire when the kernel enters the debugger. The
evaluation is *paused*, not ended: the `eval_begin` envelope remains
the last lifecycle event the renderer has seen, and the corresponding
`debug_enter` envelope (see below) marks the pause. The renderer
tracks "this cell is paused at the debugger" from an unmatched
`debug_enter` / `debug_leave` pair, not from any `eval_end` state.
When the user resumes via the debugger (`:c`, picking a restart), the
evaluation continues and eventually fires `eval_end` normally. When
they abort to top level (`:a`, or an `abort` restart), `debug_leave`
fires followed by `eval_end` with `status: "cancelled"`.

## Within-evaluation events

These envelopes are emitted during an evaluation. They reference an
`eval_id` and arrive between the `eval_begin` and `eval_end` for that
evaluation.

### `output`

A textual side effect — anything written to `*standard-output*` or
`*error-output*` during evaluation. See [§ Output during evaluation](#output-during-evaluation-multi-write-statements-and-stream-wrapping)
for the wrapping mechanism that produces these.

```json
{
  "type": "output",
  "eval_id": "e_42",
  "seq": 3,
  "stream": "stdout",
  "mime": "text/plain",
  "text": "step 3: 9\n"
}
```

`stream` is one of `"stdout" | "stderr"`. `mime` is `text/plain` for
all `output` events — structured representations go through `display`
instead. `seq` is a within-evaluation counter for ordering.

### `display`

A structured value to be displayed mid-evaluation. Produced by the
`show(x)` Maxima primitive, by libraries like `a Plotly-emitting library` calling
`emit_display(mime, payload)` directly, and by any code path that
computes a value with multiple representations worth surfacing. Carries
a mime bundle; the renderer picks the richest renderable mime.

```json
{
  "type": "display",
  "eval_id": "e_42",
  "seq": 5,
  "mime_bundle": {
    "text/plain": "1/2",
    "application/x-maxima-latex": "\\frac{1}{2}"
  }
}
```

For a Plotly figure from `the plot function(...)`:

```json
{
  "type": "display",
  "eval_id": "e_42",
  "seq": 5,
  "mime_bundle": {
    "application/x-maxima-plotly": "{\"data\":[...],\"layout\":{...}}",
    "text/plain": "<plot>"
  }
}
```

The `text/plain` fallback is always included for headless / CLI
consumers. See [§ Display events and mime bundles](#display-events-and-mime-bundles)
for the design rationale.

### `error`

A structured error event. Replaces the host's current regex-and-grace-
period detection of error markers in text output.

```json
{
  "type": "error",
  "eval_id": "e_42",
  "kind": "maxima_error",
  "message": "Division by 0",
  "location": {"line": 3, "column": 12},
  "form": "1/0",
  "backtrace": ["...", "..."],
  "recoverable": true
}
```

`kind` is one of `"maxima_error"` (a `merror` call), `"lisp_error"` (an
unhandled Lisp condition), `"parser_error"` (lexer/parser failure
before evaluation began), `"timeout"`, or `"cancelled"`. The renderer
can render different kinds differently.

### `debug_enter`

The kernel has entered the debugger (either Maxima's `dbm:` debugger
or the underlying Lisp debugger). Replaces the prompt-pattern matching
at `process.rs:572, 623, 636`.

```json
{
  "type": "debug_enter",
  "eval_id": "e_42",
  "level": "maxima",
  "depth": 1,
  "condition_type": null,
  "message": "Division by 0",
  "frames": [
    "#0: myfun(x=3) (foo.mac line 4)",
    "#1: bar(y=2)"
  ],
  "restarts": [
    {"name": "resume",
     "description": "Continue the computation."},
    {"name": "quit",
     "description": "Quit this level."}
  ]
}
```

`level` is `"maxima"` for the `(dbm:N>` debugger and `"lisp"` for the
SBCL `0]` debugger. `depth` is the debugger nesting level (matches the
N in `(dbm:N>`).

`frames` is an array of one string per stack frame, innermost first.
The format is the implementation's choice: SBCL renders via
`sb-debug:print-backtrace`; Maxima dbm uses `print-one-frame`. Hosts
display these verbatim — structured frame inspection
(function-name / args / source-line as separate fields) is a v2
candidate once a consumer needs it.

`restarts` is an array of `{name, description}` pairs naming the
recovery options available at this debugger entry. For SBCL these
are the CL restarts (`abort`, `continue`, etc.); for Maxima these
are the dbm command keywords (`resume`, `quit`, `frame`, `break`,
`help`, …). The renderer surfaces them as buttons or shortcuts in
the debugger UI.

### `debug_leave`

The kernel has left the debugger.

```json
{
  "type": "debug_leave",
  "eval_id": "e_42",
  "depth": 1
}
```

### How debug events are actually emitted

A common misconception: "the Lisp debugger interrupts the kernel, so
it can't emit events". That's half right. The kernel process *is*
still running when the debugger is entered — it's just running
*different* Lisp code (the debugger's REPL). fd 3 stays open;
`write-line` still works; envelopes still flow. The real challenge is
detecting the entry and exit transitions so we know *when* to emit.

Two hooks, one per debugger flavour:

**SBCL Lisp debugger — customize `*debugger-hook*`.** Common Lisp's
standard hook variable is called before the runtime enters the
standard debugger:

```lisp
(setf *debugger-hook*
  (lambda (condition prev-hook)
    (handler-case
        (maxima-events:emit-debug-enter
          :level "lisp"
          :condition-type (type-of condition)
          :message (princ-to-string condition))
      (error () nil))           ; never let event emission re-trigger debugger
    (unwind-protect
        (let ((*debugger-hook* prev-hook))
          (invoke-debugger condition))   ; delegate to standard debugger
      (handler-case
          (maxima-events:emit-debug-leave :level "lisp")
        (error () nil)))))
```

Three things load-bearing:

1. **Defensive emission.** The `handler-case` wrappers around
   emission are required. If the event emitter itself signals an
   error, it would re-trigger `*debugger-hook*` and infinite-loop.
2. **Delegate, don't replace.** `invoke-debugger` is the standard
   debugger; the hook *announces* its entry/exit, not replace its
   functionality. SBCL's `0]` prompt UI is still available via
   stdin.
3. **`unwind-protect` for `debug_leave`.** The user might exit the
   debugger by picking a restart that unwinds through the call
   stack; `unwind-protect` guarantees the leave envelope fires
   regardless of how control leaves.

**Maxima `dbm` debugger — wrap `$dbm_repl`.** Maxima's debugger is
just a function that reads commands from stdin:

```lisp
(let ((orig (symbol-function '$dbm_repl)))
  (setf (symbol-function '$dbm_repl)
        (lambda (&rest args)
          (handler-case
              (maxima-events:emit-debug-enter
                :level "maxima"
                :depth (incf *current-debug-depth*))
            (error () nil))
          (unwind-protect (apply orig args)
            (handler-case
                (maxima-events:emit-debug-leave
                  :level "maxima"
                  :depth *current-debug-depth*)
              (error () nil))
            (decf *current-debug-depth*)))))
```

Same defensive pattern, same `unwind-protect`, same "delegate to the
original; we just announce around it".

### Debugger input — stdin, not events

The events channel is one-way (kernel → host). Debugger *input* —
commands like `:c`, `:r 1`, `:l (some-form)` — comes through stdin,
the same way a host feeds it today. The `stdin_request` envelope (see
below) is the cleaner future where the renderer pops up an input UI
and sends `stdin_response` back through host; for the PoC we keep
the existing stdin path and only use events to *announce* debugger
entry and exit. The renderer can use that announcement to surface a
"debugger active" indicator and a dedicated input field that pipes to
the kernel's stdin.

### Cancellation while at the debugger

Our cooperative-cancellation watcher thread (see
[streaming.md § Cancellation](streaming.md#cancellation)) keeps
running in the debugger. If the user moves a slider while the kernel
is at a debug prompt, the cancel flag gets set — but no Maxima code
is checking it, so nothing happens until either: the user resumes
evaluation (the next `meval` iteration sees the flag and aborts), or
the user manually selects `:a` / an `abort` restart in the debugger.

For an aggressive cancellation that *also* exits the debugger, the
watcher thread can invoke the `abort` restart programmatically via
`invoke-restart-interactively`. This is intentionally not the
default — losing debugger state to a slider drag would be
infuriating — but is available via an explicit "abort to top level"
button the renderer can surface when it sees an unmatched
`debug_enter`.

### Re-executing a cell while paused at the debugger

If the user tries to run a new cell while the kernel sits at a
debugger prompt, the new `evaluate_expression` MCP call cannot
proceed — the kernel isn't accepting input through the normal eval
path. Two options:

- **Refuse.** An embedding host returns an error to the new evaluation request
  ("kernel is at the debugger; exit it first via the debugger panel").
  Simple, honest about state.
- **Auto-abort.** An embedding host sends an abort command (`:a` to dbm,
  `invoke-restart 'abort` to SBCL) before the new evaluation. More
  forgiving but throws away whatever state the user was inspecting.

The PoC chooses **refuse**, with a "kernel at debugger — abort?"
button in the renderer that explicitly triggers auto-abort. This
prevents accidental loss of debugger state.

### `stdin_request`

The kernel is asking for input from the user (a `readonly`-style
prompt, or `read_string`, or the debugger asking for a command).
Today this is a hard problem for a host — the kernel blocks waiting
for input that a host has no clean way to deliver. The envelope makes
it explicit:

```json
{
  "type": "stdin_request",
  "eval_id": "e_42",
  "request_id": "r_3",
  "prompt": "Enter x: ",
  "kind": "string"
}
```

The renderer responds via an MCP tool call `stdin_response(request_id,
value)` that a host delivers to the kernel by writing to a dedicated
fd (separate from the cancel fd 4 — see [§ Cancellation](#cancellation)).
`kind` is one of `"string" | "expression" | "debugger_command"`.

### `vars`

Variable list snapshot (replaces `__VARS__` /
`__VARS_END__` sentinels at `protocol.rs:147`).

```json
{
  "type": "vars",
  "eval_id": "e_42",
  "vars": ["x", "y", "z"],
  "values_text": ["3", "4", "5"]
}
```

Emitted on demand (when the renderer requests it via an MCP tool), not
on every evaluation.

## Streaming envelopes (defined in `streaming.md`)

The events channel supports a family of streaming-specific envelope
types (`stream_begin`, `frame`, `progress`, `stream_end`,
`stream_error`, `log`) used by per-view animation and progressive
computation. These reference a `view_id` rather than an `eval_id` —
a view's lifetime can span multiple evaluations, and an evaluation can
spawn many views. Streaming envelopes interleave freely with the
within-evaluation events catalogued above.

The streaming envelope schemas, backpressure rules, and the
view-kind dispatch table all live in
[streaming.md § Streaming envelopes](streaming.md#streaming-envelopes).
The channel infrastructure documented in this doc is what they ride on.

## Output during evaluation: multi-write statements and stream wrapping

The events channel handles "single statement that produces multiple
text outputs" — e.g. `for i:1 thru 5 do print("step ", i, ": ", i^2)$`
— by wrapping the kernel's stdout, not by instrumenting `$print` or any
specific output function. Every byte written to `*standard-output*`
during evaluation becomes an `output` event carrying the current
`eval_id`.

### Why wrap the stream, not the print function

Three reasons the wrapping point is the stream, not the call site:

1. **Lisp libraries that use `(format t ...)`** — including condition
   handlers, warnings from solvers, and any user-loaded `.lisp` code —
   write to `*standard-output*` directly. Instrumenting `$print` would
   miss them.
2. **`displa()`** (`src/displa.lisp:47`), which formats the value
   echo at the top of a fresh result line, writes to
   `*standard-output*`. With wrapping, the displayed value of `1 + 1`
   appears as an `output` event for free, no `displa` change.
3. **`printf(stream, ...)` to an explicit user-opened file stream**
   *shouldn't* emit events — it's an unrelated user file. Wrapping
   `*standard-output*` cleanly excludes this; explicit streams pass
   through unchanged.

### The wrapper

At session init (alongside the `MAXIMA_EVENTS_FD` setup in
[Patch 1](#patch-1-extend-server-lisps-alternate-i-o-setup-to-add-a-side-channel)),
the kernel rebinds `*standard-output*` to a `gray:fundamental-character-output-stream`
that buffers bytes line-by-line and emits an `output` envelope on each
newline. Pseudocode:

```lisp
(defclass events-output-stream
    (gray:fundamental-character-output-stream)
  ((buffer :initform (make-array 256 :element-type 'character
                                      :adjustable t :fill-pointer 0))
   (stream-name :initarg :name :reader stream-name)))

(defmethod gray:stream-write-char ((s events-output-stream) c)
  (vector-push-extend c (slot-value s 'buffer))
  (when (char= c #\Newline)
    (emit-output-envelope :stream (stream-name s)
                          :text (copy-seq (slot-value s 'buffer))
                          :eval-id *current-eval-id*)
    (setf (fill-pointer (slot-value s 'buffer)) 0))
  c)

(defmethod gray:stream-force-output ((s events-output-stream))
  (when (plusp (length (slot-value s 'buffer)))
    (emit-output-envelope :stream (stream-name s)
                          :text (copy-seq (slot-value s 'buffer))
                          :eval-id *current-eval-id*)
    (setf (fill-pointer (slot-value s 'buffer)) 0)))
```

`*current-eval-id*` is a special variable set by the eval driver
between `eval_begin` and `eval_end`. Outside an evaluation it's `nil`,
in which case the output envelope is emitted with `eval_id: null` —
the renderer can treat these as session-level diagnostics.

`*standard-output*` gets one such stream named `"stdout"`;
`*error-output*` gets a separate one named `"stderr"`. Each line goes
out as a typed event with stream tagging matching the underlying Lisp
binding.

### Buffering and flushing

- **Line-buffered by default.** Bytes accumulate into the buffer until
  a newline or an explicit `force-output`. `print("step ", i)` calls
  `format` several times under the hood; line buffering coalesces
  them into a single envelope per printed line.
- **Force flush at `eval_end`.** Any partial line is emitted as a
  final envelope before the `eval_end` envelope. `printf("starting…")`
  without newline isn't lost.
- **Coalescing happens in host, not the kernel.** A tight loop
  printing 10,000 lines produces 10,000 envelopes from the kernel;
  the host's reader is free to coalesce adjacent same-(`stream`, `mime`,
  `eval_id`) `output` envelopes into one before forwarding to the
  renderer, up to a small time/size budget (8KB or 16ms, whichever
  first — matches IPython's `iopub` stream coalescing). Coalescing
  stops at the first event of a different type (a `display`, a
  `frame`, an `error`), preserving relative ordering against
  structured events.

### Worked example: the for-loop case

```maxima
for i:1 thru 5 do print("step ", i, ": ", i^2)$
```

produces this event sequence on fd 3:

```
eval_begin    eval_id=e_42
output        eval_id=e_42 seq=1 stream=stdout text="step 1: 1\n"
output        eval_id=e_42 seq=2 stream=stdout text="step 2: 4\n"
output        eval_id=e_42 seq=3 stream=stdout text="step 3: 9\n"
output        eval_id=e_42 seq=4 stream=stdout text="step 4: 16\n"
output        eval_id=e_42 seq=5 stream=stdout text="step 5: 25\n"
eval_result   eval_id=e_42 mime_bundle={"text/plain":"done","application/x-maxima-latex":"\\mathbf{done}"} suppressed=true
eval_end      eval_id=e_42 status=ok duration_ms=12
```

The renderer appends each `output` envelope to the cell's scrolling
text area as it arrives. The user sees `step 1: 1` immediately when
the kernel finishes that iteration, not when the whole loop completes.
`eval_result` carries the loop's return value (`done`) but
`suppressed: true` because of the `$` terminator, so the renderer
elides it.

### Interleaving with streaming frames

```maxima
for i:1 thru 100 do (
  print("integrating step ", i),
  emit_frame(view_id, current_state)
)$
```

produces interleaved events on the same channel:

```
output  eval_id=e_42 stream=stdout text="integrating step 1\n"
frame   view_id=v_3  payload={...}
output  eval_id=e_42 stream=stdout text="integrating step 2\n"
frame   view_id=v_3  payload={...}
…
```

The renderer dispatches by `type`: `output` events go to the cell's
text area (keyed by `eval_id`), `frame` events go to the view's DOM
node (keyed by `view_id`). They land in different places but the
relative timing the user sees matches the kernel's actual execution
order.

### Backpressure for `output` specifically

Unlike `frame` (which can be `latest_only`), `output` is by definition
accumulating — every line is significant. If the renderer can't keep
up, the host's read buffer fills and the kernel's `force-output` blocks,
throttling the kernel to match the renderer's drain rate. That's
correct behaviour — the user sees output at the rate they can consume
it — but worth knowing: a slow renderer slows the kernel for
print-heavy code. The 64KB buffer + adjacent-event coalescing in
a host means even pathological loops sustain thousands of envelopes/sec
without visible backpressure.

## Display events and mime bundles

Where `output` is for text written explicitly with `print` / `format`,
`display` is for *structured values to be displayed*. Each `display`
envelope carries a **mime bundle** — multiple representations of one
value, side by side. The renderer picks the richest mime it can
render.

This unifies three things the kernel currently handles separately:

1. The final result of an evaluation (today: `EvalResult.latex` and
   `EvalResult.text_output`).
2. Plot output (today: `EvalResult.plot_data` via temp-file-path scan).
3. Image output (today: `EvalResult.image_png` via temp-file scan).

In the events model, all three are mime bundles attached to either
`eval_result` (for the value of the last expression) or `display` (for
mid-evaluation displayed values).

### The bundle shape

```json
{
  "text/plain":                       "1/2",
  "application/x-maxima-latex":       "\\frac{1}{2}",
  "application/x-maxima-plotly":      "{\"data\":[...],\"layout\":{...}}",
  "image/png":                        "<base64...>",
  "image/svg+xml":                    "<svg>...</svg>",
  "text/html":                        "<table>...</table>"
}
```

A bundle always contains at least `text/plain` as a fallback for
headless / CLI consumers. Other entries are added by whatever Lisp
function built the bundle. The renderer iterates the bundle in
preference order (typically: domain-specific mimes first, then the
richest fallback, then `text/plain`) and renders the first it can.

### `show(x)` — the user-facing primitive

`show` is the Maxima function that emits a `display` envelope for an
arbitrary value:

```maxima
load("maxima-events")$

show(integrate(1/(1+x^2), x))$
```

Internally, `show` calls a Lisp helper that builds a bundle from the
value — `mgrind` for `text/plain`, `tex1` for
`application/x-maxima-latex`, possibly more — and writes one `display`
envelope. For the integral above, the renderer receives both the
text form (`atan(x)`) and the LaTeX form (`\arctan x`) and picks LaTeX.

### Intermediate values inside a loop

The original motivating use case:

```maxima
for i:1 thru 3 do show(integrate(sin(i*x), x))$
```

produces:

```
eval_begin  eval_id=e_42
display     eval_id=e_42 mime_bundle={"text/plain":"-cos(x)",       "application/x-maxima-latex":"-\\cos(x)"}
display     eval_id=e_42 mime_bundle={"text/plain":"-cos(2*x)/2",   "application/x-maxima-latex":"-\\frac{\\cos(2x)}{2}"}
display     eval_id=e_42 mime_bundle={"text/plain":"-cos(3*x)/3",   "application/x-maxima-latex":"-\\frac{\\cos(3x)}{3}"}
eval_result eval_id=e_42 mime_bundle={"text/plain":"done", ...} suppressed=true
eval_end    eval_id=e_42 status=ok
```

Each `show` call produces a `display` envelope as it executes. The
renderer shows three typeset integrals in the cell, in order. The
loop's return value (`done`) is suppressed by the `$` terminator.

### Library use — `a Plotly-emitting library` migration

Today's `the plot emission helper` (`a plot library's emission helpers:1419`) writes the
Plotly JSON to a temp file and prints the path; the host's parser scans
for the path and reads the file. In the events model, it becomes a
direct `display` envelope:

```maxima
the plot emission helper(traces, layout) := block(
  [json],
  json: sconcat("{\"data\":[", simplode(traces, ","), "],\"layout\":", layout, "}"),
  emit_display([
    ["application/x-maxima-plotly", json],
    ["text/plain", "<plot>"]
  ])
)$
```

`emit_display` is a Maxima-callable function in the `maxima-events`
package that takes a list of `[mime, payload]` pairs, builds the
bundle, and writes the envelope. The temp-file pattern retires
completely; `parser.rs:464`'s `PLOTLY_PATH_RE` scan, the path-safety
check, and the temp-file read all become dead code.

### The final-result case — what replaces the injected `tex(%);`

Today, a host wraps user code with `{user code}; tex(%); print(LABEL);
print(EVAL_END);` (`protocol.rs:42`). In the events model the wrapping
becomes:

```
:lisp (events:emit-eval-begin :id eval-id)
{user code}
:lisp (events:emit-eval-result :id eval-id :value $%
                               :label (linenum-label))
:lisp (events:emit-eval-end :id eval-id)
```

`emit-eval-result` computes the bundle once from `$%` (calling
`mgrind` for `text/plain`, `tex1` for `application/x-maxima-latex`,
respecting capability-negotiated `render_mimes` to skip unused mimes)
and writes the envelope. The `tex(%);` text-output injection is gone,
along with the LaTeX-block extraction at `parser.rs`.

### Performance: LaTeX isn't free

`tex(x)` for a complex expression can be slower than `mgrind(x)`. The
events model handles this with two mechanisms:

1. **Opt-in for intermediates.** `print(x)` stays cheap (text only);
   `show(x)` pays for LaTeX. The user makes the cost choice
   explicitly.
2. **Capability gating for the final result.** The eval driver
   always builds the bundle, but inspects the renderer's
   `render_mimes` (from the `capabilities` exchange) to skip
   computing mimes that won't be rendered. A CLI frontend declaring
   `render_mimes: ["text/plain"]` never pays for LaTeX. The default
   (interactive renderer with KaTeX) includes LaTeX.

So a `for i:1 thru 10000 do print(i)` loop costs no LaTeX work
(zero), even though every `print` becomes an `output` event. A
`for i:1 thru 10000 do show(i)` loop costs LaTeX work proportional
to iteration count — but the user asked for that.

## the editor frontend → renderer

### Controller changes (`controller.ts`)

When a cell evaluation might produce streaming output, the controller
registers a subscription:

```typescript
private async executeCell(cell, notebook, controller) {
  // … existing code …
  this.notificationHandler.onViewFrame(envelope => {
    if (envelope.session_id === sessionId) {
      this.rendererMessaging.postMessage({
        type: \"view_frame\",
        envelope: envelope.envelope,
      });
    }
  });
  // … existing evaluation …
}
```

`createRendererMessaging` is initialised once at controller construction
and bound to the same renderer ID as the notebook output renderer
(`maxima-renderer`).

### Renderer side (`renderers/maxima/index.ts`)

The renderer maintains:

```typescript
const views: Map<string, {
  domNode: HTMLElement;
  kind: string;
  extend: (payload: unknown) => void;
}> = new Map();
```

`stream_begin` registers a view with its DOM node and a per-kind
extend handler:

```typescript
const handlers: Record<string, ViewKindHandler> = {
  ode_trajectory: makeOdeTrajectoryHandler,
  table_append:   makeTableAppendHandler,
  mcmc_chain:     makeMcmcChainHandler,
  // …
};
```

Each handler returns an `extend(payload)` function specialised to its
kind. For `ode_trajectory`, that's `Plotly.extendTraces(div, {x: [[t]],
y: [[y[0]]]}, [0])`.

`stream_end` triggers any final layout adjustments and unregisters the
view from the message handler.

### A note on output identity

VS Code re-runs a cell by destroying old outputs and creating new ones.
We need the renderer's view registry to be tied to *output element
identity*, not to `view_id` alone — if the user re-runs a cell while a
stream is in flight from the previous run, the old view's DOM is gone
but envelopes are still arriving. The controller cancels the stream on
re-execution (via the cancellation path); the renderer ignores
envelopes for unknown `view_id`s defensively.

## Cancellation and other reverse-direction control

Cancellation (the user moves a slider, the kernel should stop a
running streamed evaluation) is needed by the first consumer of this
channel and so is documented with that consumer. The mechanism uses a
dedicated reverse-direction pipe (fd 4) and a cooperative-cancellation
hook in `mdo` (the second small Maxima patch). See
[streaming.md § Cancellation](streaming.md#cancellation).

The `stdin_request` envelope defined above is the kernel-asking-the-user
direction; the renderer responds via an MCP tool call
`stdin_response(request_id, value)` that a host delivers to the kernel
via a dedicated fd (separate from the cancel fd). The mechanism is the
same shape as cancellation; details are deferred until the first
consumer needs it.

## Implementation: load-only package vs core patches

The entire events-channel design can ship as a `load`-able Lisp
package against stock Maxima, with **one exception** that requires
either a core patch or a fragile workaround. This is the same
distribution pattern that `alt-display.mac`, `keyword_args.lisp`,
and other `share/contrib` packages use, and it matches the way
`maxima_mcp` ships today (pure-SBCL, load-only, no core patches).

Two implementation paths, in order of effort:

1. **Load-only**: the `maxima-events` package is loaded by
   `maxima-init.lisp`, by the host's spawn wrapper, or by the user. No
   core changes. Works against stock Maxima as released. This is the
   MVP path.
2. **Core-patched**: Patch 1 and Patch 2 land upstream (eventually).
   The package's init code becomes ~20 lines shorter; cancellation of
   user-level Maxima loops works without library-author opt-in.

The recommended path is **ship the load-only version first, gather
usage data, then propose the patches upstream as quality-of-life
cleanups on a known-useful feature** — mirroring the trajectory
`alt-display` walked.

### What works as a load-only package

Every piece of the events channel except for one is achievable from a
loaded Lisp file. The per-component status:

| Component | Load-only? | Notes |
|-----------|------------|-------|
| fd 3 init + `*maxima-events-out*` binding | Yes | Read `MAXIMA_EVENTS_FD`, call `(sb-sys:make-fd-stream ...)` at load. |
| `write-envelope` + JSON helpers | Yes | Pure Lisp; no special privileges. |
| Output stream wrapping (`*standard-output*` → line-buffered envelope emitter) | Yes | Set `(setf *standard-output* (make-instance 'events-output-stream ...))` at load. Gray-stream feature supported by SBCL/CCL/CLISP/ECL. |
| `$show`, `$emit_display`, `$emit_frame` | Yes | New `defmfun`s; identical pattern to `keyword_args.lisp` or `alt-display.mac`. |
| Mime-bundle builder (text + LaTeX from one value) | Yes | Calls existing public `mgrind` and `$tex1`. |
| `eval_begin` / `eval_result` / `eval_end` lifecycle | Yes (caveat) | Hook via `*prompt-prefix*` / `*prompt-suffix*` (already a frontend-protocol API used by wxMaxima) plus wrap `displa` for the result. *Caveat: we own the producer side, not the consumer side — so prompt-based boundary detection is fine here, unlike when a host tries to parse output that originated elsewhere.* |
| `error` envelopes (structured) | Yes | Wrap `merror` and `mwarning` by saving the original `symbol-function` and rebinding. |
| `debug_enter` / `debug_leave` | Yes | `(setf *debugger-hook* ...)` for SBCL; `(setf (symbol-function '$dbm_repl) ...)` for Maxima debugger. Both pure Lisp features. |
| `stdin_request` | Yes | Wrap `$read`, `$readonly`, debugger input. Same pattern. |
| Streaming envelopes (`stream_begin`, `frame`, …) | Yes | Just envelope writers — pure data. |
| SUNDIALS streaming PoC | Yes | Already designed as a `.mac` file in `a CVODE-binding package`. |
| fd 4 cancel pipe + watcher thread + `*cancel-flag*` | Yes | `(sb-thread:make-thread …)` reading the fd, `(setf *cancel-flag* t)` on signal. Pure Lisp. |
| RHS-callback cancellation check (SUNDIALS-style) | Yes | The cancellation point is *our* RHS closure; the check is a one-line read of `*cancel-flag*`. |
| **`mdo` cancellation check (for user-level Maxima loops)** | **Mostly no** | This is the one place where load-only is awkward. See [§ The mdo cancellation problem](#the-mdo-cancellation-problem) below. |

### Bootstrapping the load-only path

The package gets loaded one of three ways, in order of preference:

1. **Host-driven spawn**: the embedding host invokes Maxima with
   `maxima --very-quiet --batch-string='load("kernel-events.mac")$' --userdir=...`,
   ensuring the package is loaded before the first user evaluation.
   *Recommended for the PoC* — keeps the dependency at the host's
   discretion.
2. **User's `maxima-init.lisp`**: a one-line addition. Works for
   non-host consumers (CLI users, custom embedders).
3. **Per-notebook**: cell 1 of every notebook contains
   `load("maxima-events.mac")$`. Workable but inelegant.

Path (1) makes the dependency invisible to the user. The first envelope
emitted is the `capabilities` envelope at load completion; any output
between Maxima startup and `load` completion goes to plain stdout, which
a host can still parse with the legacy sentinel pipeline as fallback.

### Cross-Lisp portability without core changes

The load-only path puts the cross-Lisp burden in the package, where
the core-patched path would consolidate it in `init-cl.lisp` once.
Both versions have the same set of `#+sbcl` / `#+ccl` / `#+clisp` /
`#+ecl` branches; they just live in different files. Concretely:

```lisp
(defun open-events-stream (fd-string)
  (let ((fd (parse-integer fd-string)))
    #+sbcl   (sb-sys:make-fd-stream fd :output t :external-format :utf-8 :buffering :line)
    #+ccl    (ccl::make-fd-stream fd :direction :output :external-format :utf-8)
    #+clisp  (ext:make-stream fd :direction :output :buffered :line)
    #+ecl    (si:make-stream-from-fd fd :smm-output :external-format :utf-8)
    #-(or sbcl ccl clisp ecl)
             (error "maxima-events: unsupported Lisp implementation")))
```

### The `mdo` cancellation problem

`mdo` is Maxima's `for` loop primitive (`src/mlisp.lisp`, defined as a
`defmspec`). Adding a cancellation check inside it means either:

- **Redefine the symbol-function** in the package: copy the entire
  `mdo` body, inject a flag check, install via
  `(setf (symbol-function 'mdo) ...)`. Fragile — every Maxima release
  that changes `mdo` requires the package to be updated. SBCL needs
  `sb-ext:without-package-locks` to do this.
- **Wrap at a coarser grain**: hook the top-level eval driver in
  `src/macsys.lisp` so cancellation is checked between top-level
  expressions but not inside loops. Less responsive but more stable.
- **Accept the limitation**: user-level Maxima `for` loops aren't
  interruptible from the watcher thread. *Library-authored* loops are
  (because library authors call `(maxima-events::check-cancel)`
  explicitly inside their inner loop). This is what the SUNDIALS PoC
  does — its RHS callback is *our* code, so it can check the flag
  without `mdo` changes.

The SUNDIALS PoC and other library-driven streaming work fine under
the "accept the limitation" path. Only fully-Maxima-implemented loops
(rare in practice for long-running work) need Patch 2.

### What the upstream patches actually buy

Given that the load-only path covers nearly everything, the upstream
patches are quality-of-life cleanups, not enablers:

**Patch 1 (fd 3 init in `server.lisp`) buys:**
- Slightly cleaner init timing — envelopes can be emitted from the
  very first instruction of `maxima-init.lisp`, before any package
  loads.
- One copy of the cross-Lisp `make-fd-stream` switch instead of one
  per embedding package.
- A shared contract — `MAXIMA_EVENTS_FD` and `*maxima-events-out*`
  become a public Maxima embedding API rather than host-private.
- The upstream pitch frames it as "extend the existing alternate-I/O
  mechanism" rather than "add new infrastructure", which is an easier
  conversation.

**Patch 2 (mdo cancellation) buys:**
- Cancellation of pure-Maxima user-level loops without
  library-author opt-in.
- A generic interruptibility primitive — usable by any future
  embedding host, not just ours.

Neither is a blocker. **Both can be deferred until the load-only path
has demonstrated usage.**

### Patch 1: extend `server.lisp`'s alternate-I/O setup to add a side channel

Maxima already understands "the launcher hands me an alternate fd; I
open it as a Lisp stream and use it for non-tty output". That's
`src/server.lisp` (the socket-backend mode). The patch generalises
from "alternate fd *replaces* tty" to "alternate fd *runs alongside*
tty, for out-of-band data".

Concretely, ~20 lines added to `src/init-cl.lisp` (alongside the
existing socket-init path) and ~10 lines added to a new package or to
the bottom of `src/server.lisp`:

```lisp
;; src/init-cl.lisp, in the session-init sequence:
(let ((sfd (uiop:getenv "MAXIMA_EVENTS_FD")))
  (when sfd
    #+sbcl
    (setf *maxima-events-out*
          (sb-sys:make-fd-stream
            (parse-integer sfd)
            :output t :external-format :utf-8 :buffering :line))))
```

The patch is small, additive, no-op without the env var set, and
mirrors the existing socket-fd handling line-for-line — the upstream
pitch is "extend embedding support: alternate fd for structured output,
alongside the existing socket-mode alternate fd for textual output".

`*maxima-events-out*` is the new special variable, named to parallel
existing `*socket-connection*` (`src/server.lisp:16`). The
`maxima-events:write-envelope` helper writes to it. If upstream
declines this patch, the load-only path opens its own copy of the fd
at package-load time — works, but `MAXIMA_EVENTS_FD` and
`*maxima-events-out*` become package-private rather than shared
embedding infrastructure.

## SUNDIALS streaming wrapper (defined in `streaming.md`)

The first consumer of this events channel is per-view streaming, with
SUNDIALS CVODE as the proof-of-concept solver. The wrapper exists in
three modes (per-`tspan` point, adaptive per-internal-step, event-
driven) and lives in [streaming.md § SUNDIALS streaming wrapper](streaming.md#sundials-streaming-wrapper--proof-of-concept).

## Migration from the sentinel pipeline

The current pipeline at `the host parser module ` (~4700
LOC) retires in phases as the events channel grows. Both pipelines run
concurrently for as long as needed — each row migrates only when its
event-type producer is implemented kernel-side. Nothing in this plan
requires "stop the world and rewrite".

### Migration phases (ordered by value-per-cost)

**Phase M1: eval lifecycle envelopes** *(retires three sentinels)*

| Migration step | LOC retired |
|----------------|-------------|
| Kernel emits `eval_begin` / `eval_end` / `ready` | — |
| An embedding host stops injecting `__EVAL_END__` and `__READY__` | ~40 LOC at `protocol.rs:42, 96` |
| An embedding host stops scanning text output for those sentinels | ~30 LOC at `process.rs` (eval-end detection loop) |
| An embedding host stops stripping sentinels (and LaTeX-escaped variants) from `text_output` | ~50 LOC at `parser.rs:273, 290` |

User-visible win: user code containing strings that happen to match
sentinel markers is no longer confused with kernel framing.
Estimate: 1 week, mostly test updates.

**Phase M2: `output` envelopes via stream wrapping** *(retires text
capture)*

| Migration step | LOC retired |
|----------------|-------------|
| Kernel wraps `*standard-output*` / `*error-output*` and emits `output` envelopes per line | — |
| An embedding host stops capturing stdout for `EvalResult.text_output`; derives it from `output` envelopes instead | ~60 LOC at `process.rs` (output-buffer-merge logic) |

User-visible win: progressive output in long-running cells (the
for-loop-with-print case becomes live, not retroactive). Estimate:
1 week.

**Phase M3: `display` envelopes with mime bundles** *(retires temp-
file scanning + `tex(%)` injection)*

| Migration step | LOC retired |
|----------------|-------------|
| Kernel emits `eval_result` with mime bundle (computes LaTeX inline, no `tex(%)` injection) | — |
| An embedding host stops injecting `tex(%);` and `print("__LABEL__"...)` | ~20 LOC at `protocol.rs:42, 96` |
| `a Plotly-emitting library` emits `display` envelopes for plots instead of writing temp files | ~30 LOC at `a Plotly-emitting library.mac:1419` |
| An embedding host stops scanning for `.plotly.json` / `.png` / `.svg` paths and reading temp files | ~150 LOC at `parser.rs:464–515` |
| The path-safety check (`is_safe_plotly_path`) retires with it | ~30 LOC at `parser.rs:101` |
| The label sentinel retires | ~30 LOC across `protocol.rs` and `labels.rs` |

User-visible win: structured plot output is now atomic with the
evaluation (no race between "evaluation finished" and "temp file
appears"). The renderer can show plots in mid-cell `display` events,
not just as the final result. Estimate: 2 weeks. **This is the
biggest single retirement** — eliminates ~250 LOC of a host parser
machinery.

**Phase M4: `error` envelopes with structured info** *(retires error-
marker regex scanning)*

| Migration step | LOC retired |
|----------------|-------------|
| Kernel emits `error` envelopes with kind, message, location, backtrace | — |
| An embedding host stops `ERROR_MARKERS` regex scanning | ~40 LOC at `process.rs:430` and `debugger.rs` |
| The "error happened? wait for the debugger" grace-period state machine retires | ~80 LOC at `process.rs:543, 604, 670` |

User-visible win: clickable backtraces, "did you mean…" on unknown
functions, structured error formatting in the renderer. Estimate: 1
week.

**Phase M5: `debug_enter` / `debug_leave` envelopes** *(retires prompt-
pattern detection)*

| Migration step | LOC retired |
|----------------|-------------|
| Kernel emits `debug_enter` when entering the Maxima or Lisp debugger; `debug_leave` when leaving | — |
| An embedding host stops `(dbm:N>` and SBCL `0]` prompt detection on partial reads | ~100 LOC at `process.rs:572, 623, 636` and `debugger.rs` |
| The chunk-based `read()`-instead-of-`read_line()` machinery used to detect prompts without newlines retires | ~150 LOC at `process.rs:279–326, 521–565` |

User-visible win: reliable debugger detection (no false positives on
user code that prints `(dbm:1)`), proper debugger UX with frames and
restarts. Estimate: 1.5 weeks. **This is the biggest reliability
win** — the current prompt detection is the leakiest abstraction in
host.

**Phase M6: `stdin_request` envelopes** *(adds new functionality)*

| Migration step | LOC added/changed |
|-------------|-------------------|
| Kernel emits `stdin_request` when blocking on input | — |
| Renderer presents a prompt UI and posts `stdin_response` MCP tool call | New transport leg |
| An embedding host relays the response to the kernel via a dedicated fd | ~50 LOC new |

User-visible win: `readonly`, `read_string`, and debugger input
actually work from the renderer. Today they block / break. Estimate:
1 week.

**Phase M7: `vars` envelopes on demand** *(retires the last sentinel)*

| Migration step | LOC retired |
|----------------|-------------|
| Kernel emits `vars` envelope when requested via MCP tool | — |
| An embedding host stops injecting `__VARS__` / `__VARS_END__` | ~30 LOC at `protocol.rs:147` |

Cleanup step. Estimate: 2 days.

### Total accounting

If all seven phases land, the host's `maxima/` module shrinks by an
estimated ~750 LOC and several entire state machines (debugger-arrival
grace period, prompt-pattern matching, temp-file path scanning,
sentinel stripping) retire. The remaining parser code in `parser.rs`
becomes a thin dispatch over envelope types — closer to a few hundred
LOC of straightforward MCP-notification fan-out.

The kernel side gains the `maxima-events` package (~200 LOC pure
Lisp), the stream-wrapping glue (~60 LOC), and the
`emit_display`/`show`/`emit_frame` Maxima-callable API (~80 LOC `.mac`
+ tests). Net change: roughly break-even on LOC; large reduction in
state-machine complexity; significant gain in reliability and
feature ceiling.

### Forward compatibility

Until each phase lands, the corresponding sentinel/scan pipeline
continues to run unchanged. The kernel can emit both: an `eval_result`
envelope *and* the old `tex(%)` printout, for example, with the embedding host
preferring the envelope when present and falling back to parsing the
printout when not. This makes each migration step atomically reversible
in case a regression is found.

## Open questions

1. **Backwards compatibility of upstream Patch 1.** What if upstream
   rejects extending `server.lisp`'s alternate-I/O setup to support a
   side channel? Fallback: monkey-patch the same logic at
   package-load time. Works, but `MAXIMA_EVENTS_FD` and
   `*maxima-events-out*` become package-private rather than shared
   embedding infrastructure.
2. **Authorisation on the events channel.** Anyone with read access
   to fd 3 sees every event. Inside one process tree this matches
   the existing trust boundary. Worth noting if we ever expose
   a host over a network socket.
3. **Multiple frontends on one session.** Renderer-side subscription
   tables are per-frontend. If two frontends connect to one host
   session, each should get every envelope; their subscription tables
   filter independently. The host's MCP notification should fan out —
   already the default for MCP notifications.
4. **Envelope versioning.** When we add fields to envelopes, do we
   use a version field, additive-only changes, or a capabilities-
   negotiated set? Proposal: additive-only changes for minor
   evolution; major changes go through capability negotiation
   (renderer declares it understands `events_v2`, kernel adapts).
5. **`eval_id` opacity.** Today proposed as a session-scoped
   integer counter. Should it be opaque (UUID) to discourage
   clients from depending on its structure? Counter is debuggable;
   UUID is robust. Initial proposal: counter, with a documented
   "treat as opaque" contract.

## Roadmap (rough order)

The events-channel infrastructure ships in stages independent of any
particular consumer:

1. **Maxima Lisp `maxima-events` package.** No core changes needed if
   we accept a monkey-patched init. Includes `write-envelope`, the
   `gray`-stream wrapper for `*standard-output*`/`*error-output*`, the
   eval-driver hooks (`emit-eval-begin`/`emit-eval-result`/`emit-eval-end`),
   and `$show` / `$emit_display`. Testable against a file-redirected
   fd 3 in unit tests. *~1 week.*
2. **An embedding host spawn + fd 3 reader + MCP notification push.** Includes
   the envelope schema validation. Testable against a mock kernel that
   writes canned envelopes. *~1 week.*
3. **the editor frontend controller notification handler +
   renderer-messaging plumbing.** Testable against a mock a host that
   emits canned notifications. *~3 days.*
4. **Renderer-side per-type dispatch.** Output area for `output`
   events; result area for `eval_result`; mime-bundle resolver. First
   demo: a hand-crafted envelope stream renders a cell with text + a
   typeset LaTeX result. *~3 days.*
5. **Upstream Patch 1 (extend `server.lisp` alternate-I/O).** Long
   review cycle but no blocker — fall back to monkey-patch meanwhile.
   *~weeks of review.*

Total events-channel foundation: ~3 weeks of focused work, plus
upstream review running in parallel.

### Sentinel-pipeline migration phases

After the foundation lands, the
[§ Migration from the sentinel pipeline](#migration-from-the-sentinel-pipeline)
phases can be done in any order. Priority order:

| Phase | Retires | Effort |
|-------|---------|--------|
| **M3** — `display` + `eval_result` mime bundles | ~250 LOC of a host parser code (temp-file scanning, LaTeX extraction, `tex(%)` injection); structured plot output | ~2 weeks |
| **M5** — `debug_enter` / `debug_leave` | ~250 LOC of prompt-pattern machinery; biggest reliability win | ~1.5 weeks |
| **M4** — `error` envelopes | Error-marker regex scan + grace-period state machine; unlocks rich error UX | ~1 week |
| **M1** — eval lifecycle envelopes | The `__EVAL_END__` sentinel pipeline | ~1 week |
| **M2** — `output` envelopes via stream wrapping | Stdout text capture and sentinel stripping; progressive output | ~1 week |
| **M6** — `stdin_request` | Adds new functionality (`readonly`/`read_string` from the renderer) | ~1 week |
| **M7** — `vars` envelope | The last sentinel | ~2 days |

Total migration: ~7–8 weeks across M1–M7, running incrementally. Each
phase ships independently with the old pipeline still in place as
fallback.

### Streaming consumer

In parallel with (or after) the foundation lands, the streaming
consumer ([streaming.md](streaming.md)) adds its own envelopes,
cancellation infrastructure, and the SUNDIALS proof of concept. See
[streaming.md § Roadmap](streaming.md#roadmap-rough-order).

## References

Other docs in this repo:

- [streaming.md](streaming.md) — first consumer of this protocol;
  streaming envelopes, cancellation, SUNDIALS PoC

Prior art and external specifications:

- [MCP specification — notifications](https://modelcontextprotocol.io/)
- [Jupyter messaging — `display_data` vs `execute_result` vs `stream`](https://jupyter-client.readthedocs.io/en/latest/messaging.html#messages-on-the-iopub-pub-sub-channel)
  — the prior art for the mime bundle and stream-coalescing patterns
- VS Code notebook renderer messaging API (`createRendererMessaging`)

Maxima source-tree locations referenced throughout this doc:

- `src/server.lisp` — existing alternate-I/O setup that Patch 1 extends
- `src/init-cl.lisp` — session-init sequence where the fd-3 stream is
  bound
- `src/mlisp.lisp` near `mdo` — hook point for Patch 2 (cooperative
  cancellation in user-level Maxima loops)
