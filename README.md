# kernel-events

Structured kernel-event channel for embedding Maxima in hosts.

Provides a Lisp-side producer that emits typed JSON envelopes
(evaluation lifecycle, output streams, structured display, errors,
debugger entry/exit, streaming view frames, …) to a configurable
sink. Embedding hosts — aximar (out-of-process, fd-3 transport),
maxima_mcp (in-process, HTTP+SSE transport), or a future custom
frontend — register a sink and consume the envelope stream.

The package is the kernel-side substrate; transports and host-side
consumption live elsewhere.

## Status

Pre-alpha. API and envelope grammar are not yet stable. Iteration
expected; pinning to a specific commit is recommended until 1.0.

## Design

See the design suite:

- `doc/design/kernel-events.md` — the protocol foundation (envelope
  catalogue, transport, prior art, load-only vs core-patched paths)
- `doc/design/streaming.md` — the first consumer (per-view streaming
  with a SUNDIALS proof of concept)
- `doc/design/animate.md` — paradigm-2 precomputed-frame animation
  (no infrastructure required, ships independently)
- `doc/design/reactive-views.md` — the north-star architecture this
  fits into

## Install

Install locally during development:

```
mxpm install --path . --editable
```

Or copy-install:

```
mxpm install --path .
```

## Usage

```maxima
load("kernel-events");

/* Emit a display event with a mime bundle */
show(integrate(1/(1+x^2), x))$

/* Inside a library — emit a streaming frame */
emit_frame(view_id, [t, current_state])$
```

The host (aximar, maxima_mcp, …) registers a sink at load time.
Without a registered sink, all emission is a no-op.

## Two distribution paths

This package works against stock Maxima today (load-only path).
Optional Maxima core patches polish the integration:

- **Patch 1** (`src/init-cl.lisp`): bind `*maxima-events-out*` from
  the `MAXIMA_EVENTS_FD` environment variable at session init,
  parallelling the existing socket-mode alternate-I/O setup.
- **Patch 2** (`src/mlisp.lisp`): cooperative cancellation check in
  `mdo` so user-level Maxima loops are interruptible without
  library-author opt-in.

Both patches are tracked separately on the `feature/kernel-events`
branch of `cmsd2/maxima`. Neither is required for this package to
work.

## Documentation

Build documentation artifacts (`.info` and help index):

```
mxpm doc build
```

Live preview with mdBook:

```
mxpm doc serve
```

## License

MIT
