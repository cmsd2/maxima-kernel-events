;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Debugger event hooks.
;;;
;;; Emits debug_enter / debug_leave envelopes when the kernel enters
;;; the SBCL Lisp debugger or Maxima's dbm debugger.
;;;
;;; Mechanism:
;;;   SBCL Lisp debugger: customize *debugger-hook* (standard CL).
;;;   Maxima dbm:         wrap (symbol-function '$dbm_repl).
;;;
;;; Defensive emission: a handler-case wraps every event emission so
;;; that a bug in our emission code doesn't infinite-loop into the
;;; debugger.

(in-package :kernel-events)

(defvar *current-debug-depth* 0
  "Current debugger nesting level.  Incremented by debug_enter,
   decremented by debug_leave.  Matches the N in (dbm:N>.")

(defvar *original-debugger-hook* nil
  "The pre-install *debugger-hook*, so uninstall can restore it.")

(defvar *original-dbm-repl* nil
  "The pre-install symbol-function of $dbm_repl, so uninstall can
   restore it.")

(defun install-debugger-hooks ()
  "Install both hooks.  Idempotent."
  (error "TODO: implement install-debugger-hooks"))

(defun uninstall-debugger-hooks ()
  "Restore the original hooks.  Mostly for tests."
  (error "TODO: implement uninstall-debugger-hooks"))

(defun emit-debug-enter (level &key condition-type message frames)
  "Emit a debug_enter envelope.
   LEVEL is :maxima or :lisp."
  (declare (ignore level condition-type message frames))
  (error "TODO: implement emit-debug-enter"))

(defun emit-debug-leave (level)
  "Emit a debug_leave envelope.  Decrements *current-debug-depth*."
  (declare (ignore level))
  (error "TODO: implement emit-debug-leave"))
