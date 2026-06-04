;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Debugger event hooks.
;;;
;;; Emits debug_enter / debug_leave envelopes when the kernel enters
;;; the SBCL Lisp debugger or Maxima's dbm break loop.
;;;
;;; Two function wraps:
;;;
;;;   - break-dbm-loop (mdebug.lisp:390) — entered from merror.lisp:79
;;;     when *mdebug* is truthy, or from a tripped breakpoint.  We
;;;     wrap the function; emit debug_enter on the way in, debug_leave
;;;     on the way out (unwind-protect cleanup).
;;;
;;;   - SBCL's *debugger-hook* — a standard CL hook.  Our hook calls
;;;     invoke-debugger itself so the unwind-protect cleanup fires
;;;     *after* the debugger session exits (rather than before, which
;;;     is what happens if the hook just returns).
;;;
;;; Both wraps maintain *current-debug-depth* so hosts know which
;;; nesting level dbm:N> they're at.

(in-package :kernel-events)

;; *current-eval-id* is defined in eval-hooks.lisp, which loads
;; after this file.  Declaim special so the compiler doesn't warn.
(declaim (special *current-eval-id*))

(defvar *current-debug-depth* 0
  "Current debugger nesting level.  Incremented on debug_enter,
   decremented on debug_leave.  Matches the N in (dbm:N>.")

(defvar *original-debugger-hook* :unset
  "Pre-install value of cl:*debugger-hook*.  :unset is the sentinel
   for `not installed' — distinct from NIL, which is the legitimate
   no-user-hook value.")

(defvar *original-break-dbm-loop* nil
  "Pre-install symbol-function of MAXIMA::BREAK-DBM-LOOP.  NIL when
   the hook is not installed.")

;;; --- Helpers -----------------------------------------------------------

(defun reset-debug-depth ()
  "Reset *current-debug-depth* to 0.  Used by tests."
  (setf *current-debug-depth* 0))

;;; maxima-error-message + condition-message live in error-event.lisp.

;;; --- Typed emitters ----------------------------------------------------

(defun emit-debug-enter (level &key condition-type message frames restarts)
  "Emit a debug_enter envelope.
   LEVEL is :maxima or :lisp.  Increments *current-debug-depth* and
   tags the envelope with the new depth.  FRAMES is a vector of
   frame description strings; RESTARTS is a vector of plists
   (:name :description).  Both are NIL when unavailable.  Defensive:
   a sink that errors must not re-trigger the debugger."
  (incf *current-debug-depth*)
  (handler-case
      (emit-envelope
        (make-envelope :debug_enter
                       :level          level
                       :depth          *current-debug-depth*
                       :condition_type condition-type
                       :message        message
                       :frames         frames
                       :restarts       restarts
                       :eval_id        *current-eval-id*))
    (error () nil)))

(defun emit-debug-leave (level)
  "Emit a debug_leave envelope.  Decrements *current-debug-depth*.
   Defensive: leave fires from an unwind-protect cleanup so any
   error here must be swallowed."
  (handler-case
      (emit-envelope
        (make-envelope :debug_leave
                       :level   level
                       :depth   *current-debug-depth*
                       :eval_id *current-eval-id*))
    (error () nil))
  (when (plusp *current-debug-depth*)
    (decf *current-debug-depth*)))

;;; --- Wrapper closures --------------------------------------------------

(defun make-break-dbm-loop-wrap (orig)
  "Build the break-dbm-loop replacement closure.  Emits debug_enter
   on entry with the captured Maxima error message; emits
   debug_leave from unwind-protect cleanup."
  (lambda (at)
    (let ((message (maxima-error-message)))
      (emit-debug-enter :maxima :message message)
      (unwind-protect
          (funcall orig at)
        (emit-debug-leave :maxima)))))

(defun make-lisp-debugger-hook (orig)
  "Build the *debugger-hook* replacement closure.  Emits debug_enter
   with the condition's type + message + backtrace + restarts, then
   invokes the debugger ourselves (rather than returning and letting
   SBCL invoke it afterwards) so the unwind-protect cleanup fires
   *after* the debugger session exits.

   ORIG is the pre-install value of *debugger-hook* (possibly NIL).
   We bind *debugger-hook* to NIL inside the unwind-protect to
   prevent recursive entry if an error fires during the debugger
   session — that re-entry would re-trigger our hook before SBCL
   even got to its own debugger."
  (lambda (condition hook)
    (declare (ignore hook))
    (let ((type     (type-of condition))
          (message  (condition-message condition))
          (frames   (capture-sbcl-backtrace))
          (restarts (capture-restarts condition)))
      (emit-debug-enter :lisp
                        :condition-type type
                        :message        message
                        :frames         frames
                        :restarts       restarts)
      (unwind-protect
          (let ((*debugger-hook* nil))
            (if orig
                (funcall orig condition nil)
                (invoke-debugger condition)))
        (emit-debug-leave :lisp)))))

;;; --- Install / uninstall hooks -----------------------------------------

(defun install-debugger-hooks ()
  "Install both the SBCL *debugger-hook* and the break-dbm-loop
   wrap.  Idempotent: a second call while installed returns NIL.
   Returns T on a fresh install."
  (cond
    (*original-break-dbm-loop*
     nil)
    (t
     (setf *original-break-dbm-loop*
           (symbol-function 'maxima::break-dbm-loop))
     (setf (symbol-function 'maxima::break-dbm-loop)
           (make-break-dbm-loop-wrap *original-break-dbm-loop*))
     (setf *original-debugger-hook* *debugger-hook*)
     (setf *debugger-hook*
           (make-lisp-debugger-hook *original-debugger-hook*))
     t)))

(defun uninstall-debugger-hooks ()
  "Restore the pre-install *debugger-hook* and break-dbm-loop.
   Returns T if hooks were uninstalled, NIL otherwise."
  (when *original-break-dbm-loop*
    (setf (symbol-function 'maxima::break-dbm-loop)
          *original-break-dbm-loop*)
    (setf *original-break-dbm-loop* nil)
    (unless (eq *original-debugger-hook* :unset)
      (setf *debugger-hook* *original-debugger-hook*)
      (setf *original-debugger-hook* :unset))
    t))

(defun debugger-hooks-installed-p ()
  "T when the debugger hooks are currently active."
  (not (null *original-break-dbm-loop*)))
