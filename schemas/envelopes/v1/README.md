# Envelope schemas v1

JSON Schema Draft 2020-12 definitions for every envelope type emitted
by `kernel-events`. Hosts can validate the stream against these to
catch protocol drift early.

## Files

- `common.json` — shared `$defs` (`eval_id`, `view_id`, `mime_bundle`,
  status enums, ISO 8601 timestamps). Per-type schemas `$ref` into
  this.
- One file per envelope type:

| File                  | Emitted from              | Discriminator       |
| --------------------- | ------------------------- | ------------------- |
| `capabilities.json`   | `session.lisp`            | `"capabilities"`    |
| `ready.json`          | `session.lisp`            | `"ready"`           |
| `eval_begin.json`     | `eval-hooks.lisp`         | `"eval_begin"`      |
| `eval_result.json`    | `eval-hooks.lisp`         | `"eval_result"`     |
| `eval_end.json`       | `eval-hooks.lisp`         | `"eval_end"`        |
| `output.json`         | `output-stream.lisp`      | `"output"`          |
| `display.json`        | `api.lisp` (`$show`, …)   | `"display"`         |
| `error.json`          | `error-event.lisp`        | `"error"`           |
| `debug_enter.json`    | `debugger-hooks.lisp`     | `"debug_enter"`     |
| `debug_leave.json`    | `debugger-hooks.lisp`     | `"debug_leave"`     |
| `stdin_request.json`  | `stdin.lisp`              | `"stdin_request"`   |
| `vars.json`           | `vars.lisp`               | `"vars"`            |
| `stream_begin.json`   | `stream-events.lisp`      | `"stream_begin"`    |
| `frame.json`          | `stream-events.lisp`      | `"frame"`           |
| `progress.json`       | `stream-events.lisp`      | `"progress"`        |
| `stream_end.json`     | `stream-events.lisp`      | `"stream_end"`      |
| `stream_error.json`   | `stream-events.lisp`      | `"stream_error"`    |
| `log.json`            | `stream-events.lisp`      | `"log"`             |

## Discriminating

Every envelope has a `type` field whose value is the `const` declared
in the matching schema. Hosts can dispatch with a single switch on
`type` and then validate against the corresponding schema.

## Versioning

The directory name (`v1/`) is the protocol version. A breaking change
(removed field, changed semantics, renamed type) introduces a `v2/`
sibling. Additive changes (new optional fields, new envelope types)
do not bump the version.

## Stability

API and envelope grammar are still pre-1.0. Hosts should pin to a
specific commit until a tagged 1.0.
