;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Envelope construction and JSON serialization.
;;;
;;; An envelope is a Lisp object (alist or struct) that serializes to
;;; one JSON object per the schemas in ../schemas/envelopes/v1/.
;;; Each envelope has a TYPE discriminator (capabilities, ready,
;;; eval_begin, eval_result, eval_end, output, display, error,
;;; debug_enter, debug_leave, stdin_request, vars, stream_begin,
;;; frame, progress, stream_end, stream_error, log).
;;;
;;; Sequence numbering: SEQ is per-(eval_id, stream-kind) — output
;;; and display each have their own seq scoped to the current
;;; evaluation; streaming envelopes have seq scoped to view_id.

(in-package :kernel-events)

(defvar *frame-seq* 0
  "Monotonically increasing counter for envelope seq numbers within
   the current eval.  Reset by eval_begin.")

(defun make-envelope (type &rest plist)
  "Construct an envelope.  Returns a Lisp object the JSON serializer
   can render as a JSON object."
  (declare (ignore type plist))
  (error "TODO: implement make-envelope"))

(defun envelope-to-json (envelope)
  "Serialize ENVELOPE to a JSON string (no trailing newline)."
  (declare (ignore envelope))
  (error "TODO: implement envelope-to-json"))

(defun emit-envelope (envelope)
  "Render ENVELOPE to JSON and deliver to all registered sinks.
   Internal: callers should prefer the typed wrappers (emit-eval-begin,
   emit-display, emit-frame, etc.)."
  (declare (ignore envelope))
  (error "TODO: implement emit-envelope"))

;; --- JSON helpers ---------------------------------------------------
;;
;; We hand-roll JSON output to avoid pulling in cl-json or similar.
;; The envelope shape is well-defined and small; ~100 LOC of JSON
;; emission is cheaper than a dependency.  Same approach maxima_mcp
;; takes (mcp_server.lisp:40-76).

(defun json-escape-string (s)
  "RFC 8259-compliant JSON string escape.  No newlines, no control
   characters, no embedded quotes."
  (declare (ignore s))
  (error "TODO: implement json-escape-string"))
