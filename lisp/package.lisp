;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Package definition for kernel-events.
;;;
;;; Exported symbols are the host-side API: how aximar, maxima_mcp,
;;; or any other embedding host registers a sink and inspects state.
;;; The Maxima-callable API (via $show, $emit_frame, ...) lives in
;;; api.lisp and is in :maxima.

(defpackage :kernel-events
  (:use :cl)
  (:export
    ;; Sink registration (host-side)
    #:register-sink
    #:unregister-sink
    #:list-sinks
    ;; Envelope emission (called internally and by Maxima-callable wrappers)
    #:emit-envelope
    ;; Lifecycle queries (host-side)
    #:current-eval-id
    #:cancel-requested-p
    #:request-cancel
    ;; Capability negotiation
    #:set-render-mimes
    #:render-mimes))
