;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Session-lifecycle envelopes: capabilities + ready.
;;;
;;; Hosts call these explicitly at session start (after registering
;;; their sink) to announce versions and feature support, then signal
;;; the session is ready to accept evaluations.
;;;
;;; Neither is wired into any wrap — they are pure announcements.

(in-package :kernel-events)

(defvar *default-capabilities-supports*
  '("eval_lifecycle" "output_capture" "structured_errors"
    "debug_events" "streaming" "mime_bundles" "cancellation"
    "stdin_request")
  "List of capability keys this kernel-events build advertises by
   default.  Hosts pass :supports to override.")

(defun maxima-version-string ()
  "Return Maxima's *autoconf-version* as a string, or NIL when the
   global isn't bound (e.g. running the package in isolation)."
  (when (boundp 'maxima::*autoconf-version*)
    (let ((v (symbol-value 'maxima::*autoconf-version*)))
      (and (stringp v) v))))

(defun lisp-version-string ()
  "Return \"<impl> <version>\" — e.g. \"SBCL 2.6.3\"."
  (format nil "~A ~A"
          (lisp-implementation-type)
          (lisp-implementation-version)))

(defun emit-capabilities (&key packages
                               (supports *default-capabilities-supports*)
                               kernel-version
                               lisp)
  "Emit a capabilities envelope.

   PACKAGES is the list of Maxima packages the host has chosen to
   advertise (the kernel does not auto-detect — hosts know which
   packages they care about announcing).
   SUPPORTS is the feature list; defaults to *default-capabilities-supports*.
   KERNEL-VERSION and LISP override the auto-detected strings (useful
   for tests)."
  (emit-envelope
    (make-envelope :capabilities
                   :kernel_version (or kernel-version
                                       (maxima-version-string))
                   :lisp           (or lisp (lisp-version-string))
                   :packages       (or packages '())
                   :supports       supports)))

(defun emit-ready ()
  "Emit a ready envelope signalling the kernel is ready to accept
   the next evaluation."
  (emit-envelope (make-envelope :ready)))
