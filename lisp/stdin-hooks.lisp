;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; stdin_request wiring.
;;;
;;; Auto-fires stdin_request envelopes before the kernel blocks on
;;; user input.  Two install points:
;;;
;;;   1. $readonly (macsys.lisp:377) — the underlying Maxima read.
;;;      $read calls $readonly, so wrapping the latter covers both.
;;;      Emits kind = :expression.
;;;
;;;   2. The dbm-read wrap installed by eval-hooks already runs at
;;;      every dbm-read call.  When *current-debug-depth* > 0 it
;;;      additionally emits stdin_request kind = :debugger_command.
;;;      At depth 0 (top-level REPL prompt) nothing fires —
;;;      hosts use the `ready' envelope as the prompt signal instead.
;;;      That logic lives in eval-hooks.lisp; this file owns only
;;;      the $readonly wrap.
;;;
;;; install/uninstall is idempotent and matches the pattern used by
;;; eval-hooks and debugger-hooks.

(in-package :kernel-events)

(defvar *original-readonly* nil
  "Pre-install symbol-function of MAXIMA::$READONLY.  NIL when the
   hook is not installed.")

(defun render-readonly-prompt (args)
  "Render the prompt args $readonly received into a single string.
   Mirrors $readonly's own prompt-rendering logic (macsys.lisp:380)
   but writes to an internal buffer so the output-stream wrapper
   isn't triggered.  Defensive: any error during rendering falls
   back to the empty string."
  (handler-case
      (if args
          (string-right-trim
            '(#\Newline)
            (with-output-to-string (out)
              (let ((*standard-output* out))
                (apply (symbol-function 'maxima::$print) args))))
          "")
    (error () "")))

(defun make-readonly-wrap (orig)
  "Build the $readonly replacement closure.  Emits a stdin_request
   envelope with kind :expression before delegating to ORIG."
  (lambda (&rest args)
    (emit-stdin-request (render-readonly-prompt args) :expression)
    (apply orig args)))

(defun install-stdin-hooks ()
  "Wrap $readonly.  Idempotent: a second call while installed
   returns NIL.  Returns T on a fresh install."
  (cond
    (*original-readonly* nil)
    (t
     (setf *original-readonly*
           (symbol-function 'maxima::$readonly))
     (setf (symbol-function 'maxima::$readonly)
           (make-readonly-wrap *original-readonly*))
     t)))

(defun uninstall-stdin-hooks ()
  "Restore the original $readonly.  Returns T if uninstalled, NIL
   otherwise."
  (when *original-readonly*
    (setf (symbol-function 'maxima::$readonly) *original-readonly*)
    (setf *original-readonly* nil)
    t))

(defun stdin-hooks-installed-p ()
  "T when the stdin hooks are currently active."
  (not (null *original-readonly*)))
