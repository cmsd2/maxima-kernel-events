# Streaming: the first consumer of the events channel

Status: proposed
Scope: streaming envelopes, cancellation, and a SUNDIALS-based proof
of concept. The shared transport (fd 3, the `maxima-events` package,
the host's reader, the renderer-messaging plumbing) and the general
envelope catalogue (eval lifecycle, output, display, error, debug,
stdin) live in [kernel-events.md](kernel-events.md).
Out of scope at this stage: refactoring `rk`, `lsode`, MCMC routines,
or any other library solver to stream. We pay for the architecture
once and add per-library streaming opt-ins incrementally as use cases
land.

This is one of two design docs in this repo:

1. [kernel-events.md](kernel-events.md) — the events-channel protocol
   that streaming sits on top of. **Read that first** for transport
   and general envelope conventions; this doc references it
   throughout.
2. **This doc** — streaming envelopes, the cancellation design, and
   the SUNDIALS PoC.

## Summary

Streaming is the first concrete consumer of the events channel
defined in [kernel-events.md](kernel-events.md). It adds six new
envelope types — `stream_begin`, `frame`, `progress`, `stream_end`,
`stream_error`, `log` — that drive per-view animated outputs (ODE
trajectories growing as the integrator runs, MCMC chains updating
live, optimisation iterates plotting in real time). It also adds:

- A reverse-direction control pipe (**fd 4**) for cancellation, so
  the user can interrupt an in-flight stream by changing a slider or
  closing the cell.
- The second upstream Maxima patch (~30 LOC in `src/mlisp.lisp`):
  a cooperative cancellation check in `mdo`.
- A SUNDIALS-based proof of concept demonstrating end-to-end
  streaming for ODE integration in three modes (per-`tspan` point,
  adaptive per-internal-step, event-driven). The PoC uses the
  package's existing stateful API (`np_cvode_create` /
  `np_cvode_step` / `np_cvode_close` —
  the CVODE wrapper Lisp source)
  with **no Lisp changes to the existing solver**.

Total streaming-specific work: ~3–4 weeks beyond the events-channel
foundation. The foundation is the dependency, not the SUNDIALS
solver — once kernel-events lands, any solver with an incremental
stepping API can stream in a few hundred LOC of wrapper code.

## Prerequisites: what you need from kernel-events

For readability this doc assumes you've skimmed
[kernel-events.md](kernel-events.md). The pieces this doc builds on:

- **Transport.** Maxima writes newline-delimited JSON envelopes to
  fd 3 (`MAXIMA_EVENTS_FD`); a host reads them and pushes via MCP
  `notifications/maxima_kernel_event`; the editor frontend forwards
  to the renderer via `createRendererMessaging`. See
  [kernel-events.md § Maxima → host: the fd 3 channel](kernel-events.md#maxima--host-the-fd-3-channel).
- **Envelope conventions.** Every envelope has a `type`
  discriminator. JSON-lines, one per newline. Streaming envelopes
  carry a `view_id` (rather than an `eval_id`) because a view's
  lifetime can span multiple evaluations.
- **The `maxima-events` Lisp package.** Provides `write-envelope` for
  serialisation; the `$emit_frame` / `$emit_display` / `$show`
  Maxima-callable wrappers; line-buffered output stream wrapping.
- **Patch 1** (extending `server.lisp`'s alternate-I/O setup) is in
  kernel-events.md; **Patch 2** (the `mdo` cancellation hook) is
  here.

## Why SUNDIALS as the proof of concept

Three reasons SUNDIALS is the right first consumer:

1. **It already has a persistent-handle stepping API.** `np_cvode_create`
   builds and keeps CVode memory alive; `np_cvode_step(handle, t_target)`
   integrates incrementally; `np_cvode_close` tears down. This is exactly
   the shape streaming wants. The streaming wrapper is a `.mac` function
   on top — *no Lisp changes to the existing solver*.
2. **CVode supports `CV_ONE_STEP` natively.** The CFFI binding at
   `cvode.lisp:74` takes an `itask` parameter. With one trivial wrapper
   addition (~20 LOC), we get adaptive per-internal-step framing — the
   solver's own time-step choice becomes the animation frame rate.
3. **Cancellation has a perfect insertion point: the RHS callback.**
   Every CVode integration step calls back into our Lisp RHS function.
   That's a deterministic, fast-arriving cancellation check that
   unwinds the C integrator cleanly via its existing error-return path.
   This is *easier* than cancelling a pure-Lisp integrator like `rk`.

By contrast, streaming `rk` would require modifying the `.mac` source of
`dynamics::rk` to take a callback parameter. That's a library refactor
this doc explicitly avoids at this stage. Once the SUNDIALS PoC is
working and the transport is proven, retrofitting other solvers is a
~5-LOC-per-solver change documented in
[§ Solver streamability checklist](#solver-streamability-checklist).


## Streaming envelopes

These envelopes drive per-view streaming (the original PoC motivation).
They reference a `view_id` rather than an `eval_id` — a view's lifetime
can span multiple evaluations, and conversely an evaluation can spawn
many views. Streaming envelopes can interleave with within-evaluation
events freely.

### `stream_begin`

```json
{
  \"type\": \"stream_begin\",
  \"view_id\": \"v_42\",
  \"kind\": \"ode_trajectory\",
  \"started_at\": \"2026-06-03T15:21:08.412Z\",
  \"expected_frames\": null,
  \"metadata\": {
    \"vars\": [\"x\", \"v\"],
    \"t0\": 0.0,
    \"tf\": 10.0
  }
}
```

`kind` is a renderer-side dispatch key. `expected_frames` may be null for
unbounded streams; the renderer uses it for progress bars when known.

### `frame`

```json
{
  \"type\": \"frame\",
  \"view_id\": \"v_42\",
  \"seq\": 1,
  \"payload\": {\"t\": 0.05, \"y\": [1.0, 0.02]}
}
```

The shape of `payload` is per-`kind`. For `ode_trajectory` it's
`{t, y}`. For `mcmc_chain` it would be `{sample, log_prob}`. For
`optimization` it's `{iterate, loss}`. The renderer's per-kind extend
handler knows the shape.

### `progress`

```json
{
  \"type\": \"progress\",
  \"view_id\": \"v_42\",
  \"fraction\": 0.25,
  \"message\": \"integrating t=2.5/10.0\"
}
```

Optional. Useful for unbounded or slow-frame-rate streams to show a
secondary progress indicator.

### `stream_end`

```json
{
  \"type\": \"stream_end\",
  \"view_id\": \"v_42\",
  \"final_seq\": 200,
  \"duration_ms\": 340,
  \"status\": \"complete\"
}
```

`status` is `\"complete\"` | `\"cancelled\"` | `\"error\"`.

### `stream_error`

```json
{
  \"type\": \"stream_error\",
  \"view_id\": \"v_42\",
  \"message\": \"RHS evaluation failed at t=3.7: division by zero\",
  \"recoverable\": false
}
```

Sent before a `stream_end` with status `\"error\"`.

### `log`

```json
{
  \"type\": \"log\",
  \"view_id\": \"v_42\",
  \"level\": \"info\",
  \"message\": \"detected event at t=2.3\"
}
```

For diagnostic messages attached to a view (separate from the cell's
text output channel).

### Backpressure

If the renderer can't keep up (slow JS, hidden tab), a host buffers up
to N envelopes (default 1024) per session. When the buffer is full,
behaviour depends on the `kind`'s declared semantics, set in
`stream_begin.metadata`:

| Semantics | When buffer is full |
|-----------|---------------------|
| `\"latest_only\"` (e.g. `ode_trajectory` showing current state only) | drop oldest, increment a `dropped_count` |
| `\"accumulating\"` (e.g. `table_append`, `optimization_history`) | block the writer (`force-output` to fd 3 blocks when the host's read buffer is full) |
| `\"sampled\"` (e.g. `mcmc_chain` where every Nth sample is enough) | drop with a thinning factor |

The default if unspecified is `\"accumulating\"`. ODE trajectories that
*draw* into an extending plot are actually accumulating (each frame
appends a point); ODE simulations that only show the *current* state
are `\"latest_only\"`.

## Cancellation

This is the hardest piece, because it needs to interrupt an in-flight
C-level integrator without leaving SUNDIALS state corrupted.

### The three legs of cancellation

```
renderer (slider moved during stream)
   ▼ postMessage({type: \"cancel_view\", view_id})
controller
   ▼ MCP tool call: cancel_view(view_id)
the embedding host
   ▼ write 1 byte to fd 4
Maxima (in *cancel-watcher*, a polling thread, or signal handler)
   ▼ set *cancel-flag* = T
RHS callback (next call from CVode)
   ▼ returns +CV-RHSFUNC-FAIL+
CVode aborts
   ▼ wrapper catches condition
emit_done(view_id, status=\"cancelled\")
```

### Why fd 4 (not SIGINT)

SIGINT would work — Maxima already has `*interrupt-fn*` — but it's
heavy-handed: it interrupts *all* evaluation, not just the streaming
one, and recovering cleanly from a SIGINT mid-CVode is tricky. A
dedicated cancel pipe is precise and clean.

An embedding host writes one byte to fd 4 to signal cancel. The byte's value
encodes the target: `0x01` cancels all active streams in the session,
`0x02` followed by view_id length + view_id cancels a specific view.

### Lisp-side cancel watcher

Two options for picking up the cancel signal:

**A. Polling thread.** A background SBCL thread `read`s fd 4. When it
sees the cancel byte, it sets `maxima-events::*cancel-flag*` to
T. The RHS callback (and `mdo` cancellation hook) checks the flag.
Simple, ~30 LOC.

**B. Lisp-level signal handler on a self-pipe.** More precise, but
SBCL's signal handling rules around foreign-call boundaries are subtle
and might not interact cleanly with CVode's C call stack.

I'd go with **A** (polling thread).

### The RHS callback hook

In the CVODE wrapper Lisp source, the RHS
closure is currently:

```lisp
(let* ((compiled-rhs (compile nil (coerce-float-fun f vars)))
       (rhs-closure (a CVODE-binding package::make-cvode-rhs-closure-expr
                      compiled-rhs neq)))
  ...)
```

The streaming wrapper extends this to check the cancel flag:

```lisp
(defun make-cancellable-rhs-closure (compiled-rhs neq)
  (lambda (t y dy user-data)
    (when maxima-events::*cancel-flag*
      (return-from make-cancellable-rhs-closure +cv-rhsfunc-fail+))
    (funcall compiled-rhs t y dy user-data)))
```

The streaming wrapper uses this variant instead of the existing
closure. The cost when not streaming: one boolean check per CVode RHS
call. Negligible.

### Cooperative cancellation in `mdo` (the upstream Maxima patch)

For user-level Maxima loops that aren't going through a solver, we need
the same cancellation point. The minimum patch in `mlisp.lisp` near
`mdo`:

```lisp
(defmspec mdo (form)
  (let ((body (cddr form)))
    (catch 'mdo-end
      (do-something)
      (when (and maxima-events::*cancel-flag*
                 (zerop (mod *iteration-count* 64)))
        (merror \"Computation cancelled by user\"))
      (eval body))))
```

The frequency check (every 64 iterations) keeps the cost down for tight
loops while still being responsive enough for slider drag (a 1000-iter
loop checks 16 times). Upstream-contributable as
\"cooperative cancellation hook for embedded Maxima\".

### A subtler issue: SUNDIALS internal state on cancel

When CVode aborts mid-step via RHS failure, the integrator's internal
state (linear solver matrices, history vectors, error estimates) may
be in a partially-updated state. The safe path is to **destroy the
handle on cancel** and require the user to create a new one. The
streaming wrapper does this automatically inside its `unwind-protect`:

```maxima
np_cvode_stream(view_id, f, vars, y0, tspan) := block(
  [handle: np_cvode_create(f, vars, y0, tspan[1])],
  unwind_protect(
    catch('stream_cancelled, ... loop ...),
    np_cvode_close(handle)   /* always */
  )
)$
```

If a user wants to resume after a cancel they call `np_cvode_create`
again with the partial trajectory's last state. Acceptable for the PoC;
documented limitation.


## Maxima core changes — Patch 2

The streaming-specific Maxima core change: cooperative cancellation
in `mdo`. (Patch 1, the fd 3 stream initialisation, is documented in
[kernel-events.md § Maxima core changes](kernel-events.md#maxima-core-changes--the-minimum)
because it's needed by the protocol foundation, not just streaming.)

### Patch 2: cooperative cancellation check in `mdo`

Already described in the [Cancellation section](#cooperative-cancellation-in-mdo-the-upstream-maxima-patch).
This patch is genuinely new infrastructure — no exact precedent in
Maxima today — but it's a clean ~30 LOC addition in `src/mlisp.lisp`
near `mdo`, and the cooperative-cancellation pattern itself is
well-established in other Lisps. The upstream pitch is "interruptible
evaluation for embedding hosts", and the framing benefits from being
proposed alongside Patch 1 (both motivated by "Maxima should be a
good citizen when embedded in a larger system").

That's the entire core change surface. **Everything else is package
code.** Both patches stay no-op without the corresponding env vars
or signals, so they don't affect anyone running Maxima the
traditional way.


## SUNDIALS streaming wrapper — proof of concept

Three modes, increasing granularity. All three live in a new
`.mac` file `a CVODE-binding package/streaming.mac`, loaded via
`load("a CVODE-binding package-streaming")`. The existing `a CVODE-binding package`
package is unchanged.

### Mode 1: Frame per `tspan` point

The simplest mode. Uses the existing `np_cvode_create` / `np_cvode_step`
API verbatim — no Lisp changes at all.

```maxima
load("a CVODE-binding package")$
load("a CVODE-binding package-streaming")$

/*
 * np_cvode_stream(view_id, f, vars, y0, tspan, opts...)
 *
 * Like np_cvode, but emits one frame per tspan point as integration
 * proceeds, instead of accumulating and returning a matrix.
 *
 * Returns: 'complete | 'cancelled | 'error.
 */
np_cvode_stream([args]) := block(
  [view_id, f, vars, y0, tspan, opts, handle, t, y, evs, i],
  view_id: first(args),
  [f, vars, y0, tspan] : rest(args, 1)[1..4],
  opts: rest(args, 5),

  emit_stream_begin(view_id, "ode_trajectory",
    [vars = vars, t0 = tspan[1], tf = tspan[length(tspan)]]),

  handle: apply(np_cvode_create, append([f, vars, y0, tspan[1]], opts)),
  unwind_protect(
    catch('cancelled,
      block(
        emit_frame(view_id, [tspan[1], y0]),
        for i: 2 thru length(tspan) do (
          if stream_cancel_pending(view_id) then
            throw('cancelled, 'cancelled),
          [t, y, evs]: np_cvode_step(handle, tspan[i]),
          emit_frame(view_id, [t, y]),
          for ev in evs do
            emit_frame(view_id, ['event, ev])
        ),
        emit_stream_end(view_id, "complete"),
        'complete
      )
    ),
    np_cvode_close(handle)
  )
)$
```

Total: ~40 LOC of `.mac`. Zero Lisp changes. Zero changes to existing
`a CVODE-binding package` code.

### Mode 2: Frame per internal CVode step (adaptive rate)

The smoothest mode for animation. Uses `CV_ONE_STEP` mode in the
underlying CVode call. Requires one tiny Lisp addition.

**Lisp addition** (in the CVODE wrapper Lisp source,
after `$np_cvode_step` at line 718):

```lisp
(defun $np_cvode_step_one (handle &optional t-stop)
  "Take one internal step.  Returns [t_actual, y_list, events_list].
   t-stop, if given, is an upper bound on the time CVode will reach."
  (let ((t-target (or (and t-stop (coerce (maxima::$float t-stop)
                                          'double-float))
                       most-positive-double-float)))
    (multiple-value-bind (t-actual y-list events-list)
        (a CVODE-binding package::np-cvode-step-internal-onestep
          (a CVODE-binding package::cvode-form->key handle) t-target)
      `((mlist) ,t-actual
                ((mlist) ,@y-list)
                ((mlist) ,@(mapcar #'package-event events-list))))))
```

`np-cvode-step-internal-onestep` is a copy of `np-cvode-step-internal`
(the existing single-step internal helper) with one line changed: the `itask` argument
to `%cvode-solve` flips from `+cv-normal+` to `+cv-one-step+`. ~25 LOC
including the helper.

**Maxima-side wrapper:**

```maxima
np_cvode_stream_adaptive(view_id, f, vars, y0, [t0, tf], [opts]) := block(
  [handle, t: t0, y: y0, evs],
  emit_stream_begin(view_id, "ode_trajectory",
    [vars = vars, t0 = t0, tf = tf]),
  handle: apply(np_cvode_create, append([f, vars, y0, t0], opts)),
  unwind_protect(
    catch('cancelled,
      block(
        emit_frame(view_id, [t0, y0]),
        while t < tf do (
          if stream_cancel_pending(view_id) then
            throw('cancelled, 'cancelled),
          [t, y, evs]: np_cvode_step_one(handle, tf),
          emit_frame(view_id, [t, y]),
          for ev in evs do
            emit_frame(view_id, ['event, ev])
        ),
        emit_stream_end(view_id, "complete"),
        'complete
      )
    ),
    np_cvode_close(handle)
  )
)$
```

**This is the mode I'd showcase first.** The integrator's own
time-step choice becomes the animation rate: small steps in stiff
regions (the user sees the integrator slow down and resolve fast
dynamics), large steps in smooth regions (fast playback through boring
parts). It's a striking demo.

### Mode 3: Event-driven streaming

Useful for bouncing-ball-style demos where events are the interesting
signal, not the trajectory. Same as Mode 1 with the trajectory frames
suppressed and event frames foregrounded:

```maxima
np_cvode_stream_events(view_id, f, vars, y0, tspan, events, [opts]) :=
  block([handle, t, y, evs],
    emit_stream_begin(view_id, "events_only",
      [vars = vars, events = events]),
    handle: apply(np_cvode_create,
                  append([f, vars, y0, tspan[1]], opts, [events])),
    unwind_protect(
      catch('cancelled,
        block(
          for i: 2 thru length(tspan) do (
            if stream_cancel_pending(view_id) then
              throw('cancelled, 'cancelled),
            [t, y, evs]: np_cvode_step(handle, tspan[i]),
            for ev in evs do
              emit_frame(view_id, ['event, ev])
          ),
          emit_stream_end(view_id, "complete"),
          'complete
        )
      ),
      np_cvode_close(handle)
    )
  )$
```


## What we explicitly do **not** change at this stage

To keep the PoC scope tight:

- **`rk`, `rkf45` in `dynamics`.** They could stream with a 5-LOC
  callback parameter, but we don't touch them in this PoC. SUNDIALS
  demonstrates the protocol; once accepted, retrofitting is mechanical.
- **`lsode`.** Same; supports intermediate output natively, a future
  PoC.
- **MCMC, optimisation, root-finding.** Not yet written.
- **`mdo` cancellation patch beyond the cancel-flag check.** No
  general loop instrumentation; that's a larger upstream conversation.
- **A higher-level `view` abstraction.** The PoC uses `view_id` strings
  directly; a future view object could carry the view_id, the kind, and
  any subscription state. The PoC's hand-allocated view_ids are
  forward-compatible with that.

## Solver streamability checklist

For planning which existing routines could later be retrofitted:

| Routine | Natively streamable? | Frame boundary | Effort to add |
|---------|---------------------|-----------------|----------------|
| `np_cvode_*` (this PoC) | Yes (handle API exists) | `tspan` point / `CV_ONE_STEP` / event | ~40 LOC `.mac` + 25 LOC Lisp |
| `dynamics::rk`, `rkf45` | Yes (rewrite as a step loop) | Each step | 5 LOC per solver (callback param) |
| `lsode` | Yes (native intermediate-output flag `ISTATE`) | Each step | 10 LOC wrapper |
| `numerics::np_odeint` | Depends on backend | Each step (if backend supports) | Variable |
| IDA, ARKODE (SUNDIALS DAE/IMEX) | Yes (same pattern as CVODE) | Same | Replicate this PoC |
| `find_root`, Newton | Yes | Each iterate | 5 LOC |
| `lbfgs`, optimisation | Yes | Each iterate + loss | 10 LOC |
| Adaptive quadrature | Partial | Each subdivision | Wrapper around `quad_qag` with intermediate hook |
| Iterative linear solvers (CG, GMRES) | Yes | Each iteration | 10 LOC |
| `solve` (symbolic) | No | No intermediate state | Not applicable |
| `integrate` (symbolic) | No | No intermediate state | Not applicable |
| Bessel, gamma, etc. | No | One-shot | Not applicable |
| Direct linear solve | No | One-shot | Not applicable |

The pattern: anything with an inner iteration that produces successively
better/further state is streamable. Anything that's "evaluate this
expression and return one answer" isn't.

## Performance

Budget for typical ODE streaming (the PoC case):

| Operation | Target | Realistic |
|-----------|--------|-----------|
| One CVode internal step | <100µs | 10–50µs (typical stiff RHS) |
| Frame envelope build (`mexpr-to-json`) | <50µs | 20–30µs |
| `write-line` + `force-output` | <20µs | 5–15µs |
| Pipe → a host read → MCP push | <500µs | 200–400µs (single host, localhost) |
| Renderer Plotly `extendTraces` | <2ms | ~1ms |
| **Total end-to-end frame latency** | <5ms | ~2ms |
| Max sustainable frame rate | 1000fps | 500fps |

For Mode 2 (CV_ONE_STEP), CVode commonly takes 100–10000 steps per
second of simulated time, depending on stiffness. The transport can
keep up; the bottleneck is the renderer's per-frame redraw cost
(~1ms with Plotly `extendTraces`). For very fast streams we'd throttle
on the renderer side (`extendTraces` every N frames, where N adapts to
maintain 60fps display).

Backpressure: the host's read buffer is 64KB by default; each envelope
is ~100 bytes; that's ~640 frames before `write-line` blocks. Plenty
of headroom for any realistic ODE rate.

## Worked example

A slider-driven streaming oscillator. Combines slider widget (future
Component 4), view (future Component 5), streaming (this doc), and the
existing SUNDIALS bindings.

```maxima
load(\"numerics\")$
load(\"a CVODE-binding package\")$
load(\"a CVODE-binding package-streaming\")$
load(\"widgets\")$        /* future package */

/* Damping coefficient: a slider */
zeta: widget([0, 1], default = 0.1, label = \"damping\")$

/* Create a fresh view, get its id */
v: alloc_view(\"ode_trajectory\")$

/* On any change of zeta (or on first run), stream a new trajectory */
on_change(zeta, lambda([],
  cancel_stream(v),                          /* cancel previous, if any */
  np_cvode_stream_adaptive(
    v,
    [v, -2*zeta*v - x],                      /* damped oscillator RHS */
    [t, x, v],
    [1.0, 0.0],                              /* initial condition */
    [0, 20.0]                                /* t range */
  )
))$

/* Bind the view to a Plotly figure */
display_view(v)$
```

What happens when the user drags the slider:
1. Renderer posts `set_signal(zeta_id, 0.3)` → controller → a host →
   Maxima sets `zeta = 0.3`.
2. The `on_change` hook fires, cancels the previous stream (sets the
   cancel flag on view `v`).
3. The previous integration's next RHS call returns +CV-RHSFUNC-FAIL+,
   CVode aborts, the wrapper's `unwind-protect` closes the handle.
4. `np_cvode_stream_adaptive` starts a new integration with the new
   `zeta`. Frames flow as CVode steps.
5. Renderer's `ode_trajectory` extend handler calls
   `Plotly.extendTraces` on each frame — the trajectory grows live.
6. Total latency from slider stop to first new frame: ~20ms.


## Open questions

1. **View identity across cell re-runs.** When a user re-runs a cell
   whose `display_view(v)` produced a streaming view, do we cancel the
   in-flight stream and start over, or refuse and surface a warning?
   Initial proposal: cancel + restart (matches user mental model of
   \"the cell is re-running\"). The view_id is regenerated; the old
   view's DOM is destroyed.
2. **What counts as a `view_id`?** A UUID, an integer counter, a
   hash of (cell_id + source_position)? UUIDs are simplest; counters
   are debuggable. Initial proposal: counter, scoped to session.
3. **Authorisation on the cancel pipe.** Anyone with write access to
   fd 4 can cancel a stream. Inside one process tree this is the same
   trust boundary as everything else, but worth noting if we ever
   expose a host over a network socket.
4. **Multiple frontends on one session.** Renderer-side subscription
   tables are per-frontend. If two frontends connect to one host
   session, each should get every envelope; their subscription tables
   filter independently. The host's MCP notification should fan out —
   already the default for MCP notifications.
5. **Pause and resume.** Should `cancel_view` actually *pause* with
   the option to resume? Resuming an ODE is well-defined (just call
   `cvode_step` again from the current state); pausing the kernel
   is also fine. Adds complexity to the protocol (`pause_view`,
   `resume_view` envelopes). Defer.
6. **Frame compression.** For very high-rate streams (e.g. 1000fps
   from CV_ONE_STEP on a non-stiff problem), we may want delta
   encoding or binary mime types. Defer until measured as a problem.


## Roadmap (rough order)

Streaming-specific work, assuming the events-channel foundation
([kernel-events.md § Roadmap](kernel-events.md#roadmap-rough-order)
steps 1–5) has either landed or is being built in parallel:

1. **Add streaming-envelope handlers to `maxima-events`.** New
   Maxima-callable functions `emit_frame`, `emit_progress`,
   `emit_done`, `emit_error`, `emit_log`. Trivial extensions of the
   existing envelope-writer. *~2 days.*
2. **An embedding host streaming-aware reader extensions.** Backpressure policy
   table (`latest_only` / `accumulating` / `sampled`); coalescing of
   adjacent same-`view_id` frames under load. *~3 days.*
3. **Renderer-side view registry + `ode_trajectory` extend handler.**
   First visible end-to-end demo: a hand-crafted JSON stream produces
   a growing Plotly trace. *~3 days.*
4. **SUNDIALS Mode 1 (per-tspan frame).** First *real* end-to-end
   demo driven by a Maxima cell. *~2 days.*
5. **CV_ONE_STEP Lisp addition + SUNDIALS Mode 2 (adaptive rate).**
   The demo people remember. *~3 days.*
6. **fd 4 cancel pipe + RHS callback hook + `*cancel-flag*` +
   watcher thread.** Enables slider-cancels-stream. *~1 week.*
7. **SUNDIALS Mode 3 (event-driven streaming).** Bouncing-ball-style
   demo. *~2 days.*
8. **Upstream Patch 2 (mdo cancellation).** Not strictly required for
   the SUNDIALS PoC (RHS callback is the cancellation point), but
   needed for cancelling user-level Maxima loops not going through a
   solver. Long review cycle. *~weeks of review.*

Total streaming-specific work: ~3 weeks beyond the events-channel
foundation, plus upstream review running in parallel.


## References

Other docs in this repo:

- [kernel-events.md](kernel-events.md) — the protocol foundation this
  doc builds on

Prior art and external specifications:

- [SUNDIALS user guide — CV_ONE_STEP and rootfinding](https://sundials.readthedocs.io/en/latest/cvode/Usage/index.html)
