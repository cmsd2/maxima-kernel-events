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
    #:clear-sinks
    #:*debug-sinks*
    ;; Envelope construction + emission
    #:make-envelope
    #:emit-envelope
    #:envelope-to-json
    #:json-escape-string
    ;; Eval lifecycle
    #:current-eval-id
    #:next-eval-id
    #:reset-eval-counter
    #:emit-eval-begin
    #:emit-eval-result
    #:emit-eval-end
    #:install-eval-hooks
    #:uninstall-eval-hooks
    #:eval-hooks-installed-p
    ;; Debugger
    #:install-debugger-hooks
    #:uninstall-debugger-hooks
    #:debugger-hooks-installed-p
    #:emit-debug-enter
    #:emit-debug-leave
    #:reset-debug-depth
    #:*current-debug-depth*
    ;; Session
    #:emit-capabilities
    #:emit-ready
    #:start-session
    #:*default-capabilities-supports*
    #:*protocol-version*
    ;; Structured error
    #:emit-error
    #:maxima-error-message
    #:condition-message
    #:capture-sbcl-backtrace
    #:capture-restarts
    ;; stdin requests
    #:emit-stdin-request
    #:next-stdin-request-id
    #:reset-stdin-counter
    ;; Vars snapshot
    #:emit-vars
    #:current-vars-snapshot
    ;; Cancellation
    #:request-cancel
    #:cancel-requested-p
    #:check-cancel
    #:reset-cancel-flag
    #:cancellation-requested
    #:cancellation-view-id
    #:start-cancel-watcher
    #:stop-cancel-watcher
    #:cancel-watcher-running-p
    ;; Capability negotiation
    #:set-render-mimes
    #:render-mimes
    #:add-render-mime
    #:should-render-mime-p
    ;; Mime bundles
    #:make-mime-bundle
    #:mime-bundle-add
    #:mime-bundle-get
    #:mime-bundle-mimes
    #:mime-bundle-empty-p
    #:build-mime-bundle
    ;; Output stream wrapping
    #:install-output-wrapping
    #:uninstall-output-wrapping
    #:output-wrapping-installed-p
    #:emit-output-line
    ;; Streaming envelopes
    #:next-view-id
    #:next-view-seq
    #:reset-view-counters
    #:emit-stream-begin
    #:emit-frame
    #:emit-progress
    #:emit-stream-end
    #:emit-stream-error
    #:emit-log))
