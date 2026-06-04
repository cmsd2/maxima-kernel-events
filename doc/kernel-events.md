# Package kernel-events

## Introduction to kernel-events

Structured kernel-event channel for embedding Maxima in hosts. Emits
typed JSON envelopes (evaluation lifecycle, output, structured
display, errors, debugger events, streaming view frames, …) to a
host-registered sink. Embedding hosts consume the envelope stream and
expose it through their own protocols (HTTP/SSE for `maxima_mcp`,
fd-3 for `aximar`, …).

The package is pre-alpha. The envelope grammar will evolve through
v1.x as use cases land. See the design suite in `doc/design/` for the
architecture, prior-art references, and migration path from sentinel-
based stdout parsing.

To use the package:

```
load("kernel-events");
```

By itself the package emits envelopes only when a host has registered
a sink. Without a sink, all emission is a no-op — safe to load in any
context.

## Definitions for kernel-events

### Function: show (@var{expr})

Emit a `display` event for @var{expr} with a mime bundle (text/plain,
application/x-maxima-latex, and others depending on the host's
declared capabilities). The renderer picks the richest mime it can
render.

```
for i:1 thru 3 do show(integrate(sin(i*x), x))$
```

### Function: emit_display (@var{pairs})

Emit a `display` event with an explicit mime bundle. @var{pairs} is
a Maxima list of `[mime, payload]` pairs. Used by libraries that know
exactly what mime types they are producing (e.g. `ax-plots` emitting
`application/x-maxima-plotly`).

```
emit_display([
  ["application/x-maxima-plotly", json_string],
  ["text/plain", "<plot>"]
])$
```

### Function: emit_frame (@var{view_id}, @var{payload})

Emit a `frame` envelope to a streaming view. @var{payload} shape is
per-view-kind (e.g. `[t, y]` for an ODE trajectory).

### Function: emit_progress (@var{view_id}, @var{fraction})

Emit a `progress` envelope. @var{fraction} is a number between 0 and
1, or @code{none} (= `null` in JSON) if the total is unknown.

### Function: emit_log (@var{view_id}, @var{level}, @var{message})

Emit a `log` envelope attached to a view. @var{level} is one of the
symbols @code{info}, @code{warn}, @code{error}.

### Function: emit_done (@var{view_id}[, @var{status}])

Close a streaming view. @var{status} is one of the symbols
@code{complete} (default), @code{cancelled}, @code{error}.

### Function: alloc_view (@var{kind})

Allocate a new view-id and emit the corresponding `stream_begin`
envelope. Returns the view-id as a Maxima string. @var{kind} is a
renderer-side dispatch key (e.g. @code{ode_trajectory},
@code{table_append}, @code{mcmc_chain}).

### Function: kernel_events_available ()

Feature-detect. Returns @code{true} if the package is loaded — mirrors
Python's `from __future__ import …` idiom for libraries that want to
conditionally opt in.

### Function: emit_capabilities ([@var{packages}])

Emit a `capabilities` envelope announcing kernel version, lisp
implementation, and supported features. @var{packages} is an optional
Maxima list of strings naming packages the host wants to advertise.

### Function: emit_ready ()

Emit a `ready` envelope signalling the kernel will accept the next
evaluation.

### Function: start_session ([@var{packages}])

Convenience: emit `capabilities` then `ready` in sequence — the
standard session-start handshake. @var{packages} is forwarded to
@code{emit_capabilities}.

### Function: emit_error (@var{kind}, @var{message})

Emit a structured `error` envelope. @var{kind} is one of the symbols
@code{maxima_error}, @code{lisp_error}, @code{parser_error},
@code{timeout}, @code{cancelled}. @var{message} is a string. The
package auto-emits this envelope for eval-time failures; call
@code{emit_error} explicitly only for cases the kernel doesn't catch
(host-side timeouts, custom parser layers, …).

### Function: emit_vars ()

Snapshot @code{values} and emit a `vars` envelope carrying parallel
arrays of variable names and their mgrind-rendered values.

### Function: emit_stdin_request (@var{prompt}, @var{kind})

Announce the kernel is blocking on user input. @var{prompt} is the
text to display in the host UI. @var{kind} is one of the symbols
@code{string}, @code{expression}, @code{debugger_command}. Returns
the request id string so the caller can correlate the eventual
response (delivered out-of-band — the events channel is one-way).

## See also

- `doc/design/kernel-events.md` — full envelope catalogue and design
- `doc/design/streaming.md` — streaming-specific envelopes and PoC
- `schemas/envelopes/v1/` — JSON Schema for each envelope type
