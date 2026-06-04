;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Evaluation lifecycle hooks.
;;;
;;; Emits eval_begin / eval_result / eval_end envelopes around each
;;; top-level Maxima evaluation.  Two function wraps:
;;;
;;;   - dbm-read (mdebug.lisp:262) — captures the suppression flag
;;;     from the read result.  In `continue', `r' is `((displayinput)
;;;     c-tag value)' for a `;'-terminated input and a different
;;;     header for a `$'-terminated one.  We stash a boolean in
;;;     *next-eval-suppressed* for the upcoming toplevel-macsyma-eval
;;;     to consume.
;;;
;;;   - toplevel-macsyma-eval (macsys.lisp:93) — binds
;;;     *current-eval-id* dynamically, emits eval_begin, runs the
;;;     original eval, emits eval_result with the value + the
;;;     captured suppression flag + the computed output label, then
;;;     emits eval_end.  All within one synchronous flow inside our
;;;     unwind-protect.
;;;
;;; We deliberately do NOT wrap displa.  Maxima's REPL calls displa
;;; AFTER toplevel-macsyma-eval returns (macsys.lisp:281-282), so by
;;; the time a displa wrap fires the outer eval-id binding has
;;; already unwound.  Instead we treat displa's text output as
;;; orthogonal: if the output-stream wrapper is installed, the
;;; rendered text will appear as `output' envelopes WITH eval_id =
;;; nil (because *current-eval-id* unbound) — the renderer can elide
;;; them as redundant with the eval_result mime bundle.
;;;
;;; Reentry: dynamic binding of *current-eval-id* handles nested
;;; toplevel-macsyma-eval calls (batch / demo / load) cleanly.  Each
;;; inner eval shadows the outer's id; unwind restores.  Debugger
;;; commands go through meval* + bare displa (mdebug.lisp:425), so
;;; they don't trigger our hooks.
;;;
;;; Tests that bypass dbm-read (calling toplevel-macsyma-eval
;;; directly) can override the suppression default by binding
;;; *next-eval-suppressed* — see test-eval-hooks.lisp.

(in-package :kernel-events)

(defvar *current-eval-id* nil
  "Dynamically bound during a top-level Maxima evaluation to the
   string id (e.g. \"e_42\") this evaluation is using.  NIL outside
   any evaluation.  Read by emit-output-line and other within-eval
   emitters so their envelopes can be tagged with the current eval.")

(defvar *eval-counter* 0
  "Monotonically increasing eval-id allocator, session-scoped.")

(defvar *next-eval-suppressed* nil
  "Set by the dbm-read wrap based on whether the read form is
   `displayinput'-wrapped (semicolon, displayed → NIL) or not
   (dollar, suppressed → T).  Consumed by the next toplevel-
   macsyma-eval to fill in eval_result's `suppressed' field.  Default
   NIL — sensible for tests and any direct invocation that bypasses
   dbm-read.")

(defvar *original-toplevel-macsyma-eval* nil
  "Pre-install symbol-function of MAXIMA::TOPLEVEL-MACSYMA-EVAL.
   NIL when the eval hook is not installed.")

(defvar *original-dbm-read* nil
  "Pre-install symbol-function of MAXIMA::DBM-READ.")

(defun next-eval-id ()
  "Allocate the next session-scoped eval-id string."
  (format nil "e_~D" (incf *eval-counter*)))

(defun current-eval-id ()
  "Return the eval-id of the currently-evaluating form, or NIL."
  *current-eval-id*)

(defun reset-eval-counter ()
  "Reset eval-id allocator and clear *current-eval-id* /
   *next-eval-suppressed*.  Used by tests for isolation."
  (setf *eval-counter* 0)
  (setf *current-eval-id* nil)
  (setf *next-eval-suppressed* nil))

;;; --- Typed eval-lifecycle emitters --------------------------------------

(defun emit-eval-begin (eval-id)
  "Emit an eval_begin envelope for EVAL-ID."
  (emit-envelope
    (make-envelope :eval_begin
                   :eval_id eval-id
                   :started_at (current-iso8601-utc))))

(defun emit-eval-result (eval-id value &key label suppressed)
  "Emit an eval_result envelope.  Builds a mime bundle for VALUE.
   LABEL is a Maxima output label string (e.g. \"%o7\") or NIL.
   SUPPRESSED is T when the user terminated with `$'."
  (let ((bundle (build-mime-bundle value)))
    (emit-envelope
      (make-envelope :eval_result
                     :eval_id eval-id
                     :output_label label
                     :suppressed (if suppressed t :false)
                     :mime_bundle bundle))))

(defun emit-eval-end (eval-id status &key duration-ms)
  "Emit an eval_end envelope.  STATUS is :ok | :error | :cancelled."
  (emit-envelope
    (make-envelope :eval_end
                   :eval_id eval-id
                   :status status
                   :duration_ms duration-ms)))

(defun duration-ms (start-internal-real-time)
  "Compute elapsed milliseconds since START-INTERNAL-REAL-TIME."
  (round (* 1000
            (/ (- (get-internal-real-time) start-internal-real-time)
               internal-time-units-per-second))))

;;; --- Output label string -----------------------------------------------

(defun current-output-label-string ()
  "Build the string label Maxima would assign to the current output
   line, e.g. \"%o7\".  Reads $outchar and $linenum live, so user
   customisations are honoured.  Strips the leading $ from
   $outchar's printed form."
  (let ((outchar-name
          (let ((s (symbol-name (symbol-value 'maxima::$outchar))))
            (if (and (plusp (length s)) (char= (char s 0) #\$))
                (subseq s 1)
                s))))
    (format nil "~A~D" outchar-name (symbol-value 'maxima::$linenum))))

;;; --- Install / uninstall hooks -----------------------------------------

(defun install-eval-hooks ()
  "Wrap dbm-read and toplevel-macsyma-eval.  Idempotent: a second
   call while installed returns NIL.  Returns T on a fresh install."
  (cond
    (*original-toplevel-macsyma-eval*
     nil)
    (t
     (setf *original-dbm-read*
           (symbol-function 'maxima::dbm-read))
     (setf *original-toplevel-macsyma-eval*
           (symbol-function 'maxima::toplevel-macsyma-eval))
     (setf (symbol-function 'maxima::dbm-read)
           (make-dbm-read-wrap *original-dbm-read*))
     (setf (symbol-function 'maxima::toplevel-macsyma-eval)
           (make-toplevel-eval-wrap *original-toplevel-macsyma-eval*))
     t)))

(defun uninstall-eval-hooks ()
  "Restore the original dbm-read and toplevel-macsyma-eval.  Returns
   T if hooks were uninstalled, NIL otherwise."
  (when *original-toplevel-macsyma-eval*
    (setf (symbol-function 'maxima::dbm-read)
          *original-dbm-read*)
    (setf (symbol-function 'maxima::toplevel-macsyma-eval)
          *original-toplevel-macsyma-eval*)
    (setf *original-dbm-read* nil
          *original-toplevel-macsyma-eval* nil)
    t))

(defun eval-hooks-installed-p ()
  "T when the eval hooks are currently active."
  (not (null *original-toplevel-macsyma-eval*)))

;;; --- Wrapper closures --------------------------------------------------

(defun make-dbm-read-wrap (orig)
  "Build the dbm-read replacement closure.

   Two responsibilities:

   1. On a successful read, capture the suppression flag from the
      parsed form's header into *next-eval-suppressed*.  Pure
      observation; the form is returned unchanged.

   2. On a *parse* failure, emit an `error' envelope with
      kind = :parser_error.  Two failure shapes are handled, in
      symmetry with the toplevel-eval wrap:

        - cl:error signalled out of ORIG (uncommon — most parser
          errors go through merror, which throws):
          handler-bind observes, emits, declines.  The condition
          keeps propagating to the continue loop's recovery.

        - throw 'macsyma-quit out of ORIG (the merror default):
          catch snapshots maxima::$error, emits :parser_error, then
          re-throws so the outer catch still sees the abort.

   Parser errors have :eval_id NIL because no eval has started yet."
  (lambda (&rest args)
    (handler-bind
        ((error
           (lambda (cnd)
             ;; Cancellation during a read is unusual but the host
             ;; might trigger it; do not relabel as a parse error.
             (unless (typep cnd 'cancellation-requested)
               (typecase cnd
                 (maxima::maxima-$error
                  (emit-error :parser_error
                              (or (maxima-error-message)
                                  (condition-message cnd))))
                 (t
                  (emit-error :parser_error
                              (condition-message cnd)
                              :condition-type
                              (string (type-of cnd)))))))))
      (let ((completed   nil)
            (form-result nil)
            (throw-val   nil))
        (setf throw-val
              (catch 'maxima::macsyma-quit
                (let ((r (apply orig args)))
                  (when (and (consp r) (consp (car r)))
                    ;; `r' is `((displayinput) c-tag expr)' for
                    ;; `;'-terminated input — header SYMBOL is
                    ;; `displayinput' in :maxima.  Anything else,
                    ;; treat as suppressed.
                    (setf *next-eval-suppressed*
                          (not (eq (caar r) 'maxima::displayinput))))
                  (setf form-result r)
                  (setf completed t)
                  :ok)))
        (if completed
            form-result
            (progn
              (emit-error :parser_error
                          (or (maxima-error-message) "Parse error"))
              (throw 'maxima::macsyma-quit throw-val)))))))

(defun make-toplevel-eval-wrap (orig)
  "Build the toplevel-macsyma-eval replacement closure that wraps
   ORIG.  Bound to MAXIMA::TOPLEVEL-MACSYMA-EVAL by install-eval-hooks.

   Three failure modes are observed and surfaced as `error'
   envelopes before the closing `eval_end':

     - cancellation-requested  ->  kind = :cancelled  (consumed)
     - maxima::maxima-$error   ->  kind = :maxima_error (declined)
     - any other cl:error      ->  kind = :lisp_error (declined)
     - (throw 'macsyma-quit)   ->  kind = :maxima_error (re-thrown)

   `Consumed' = handler-case unwinds the condition; status :cancelled.
   `Declined' = handler-bind observes and lets the condition keep
   propagating; status stays :error and the caller (continue / batch
   / *debugger-hook*) decides what happens next.
   `Re-thrown' = we catch the macsyma-quit tag long enough to snapshot
   $error, then re-throw so continue's outer catch still sees the
   abort."
  (lambda (x)
    (let ((eval-id    (next-eval-id))
          (start      (get-internal-real-time))
          ;; Snapshot at the very start; dbm-read for the *next*
          ;; eval will overwrite *next-eval-suppressed* before we
          ;; read it next time.
          (suppressed *next-eval-suppressed*)
          (status     :error)
          (result     nil))
      (let ((*current-eval-id* eval-id))
        (reset-cancel-flag)
        (emit-eval-begin eval-id)
        (unwind-protect
            (handler-case
                (handler-bind
                    ((error
                       (lambda (cnd)
                         (typecase cnd
                           (cancellation-requested
                            ;; Outer handler-case will consume; emit
                            ;; the envelope there to keep the flow
                            ;; explicit.
                            nil)
                           (maxima::maxima-$error
                            (emit-error :maxima_error
                                        (or (maxima-error-message)
                                            (condition-message cnd))))
                           (t
                            (emit-error :lisp_error
                                        (condition-message cnd)
                                        :condition-type
                                        (string (type-of cnd))))))))
                  (let ((completed nil)
                        (catch-val nil))
                    (setf catch-val
                          (catch 'maxima::macsyma-quit
                            (setf result (funcall orig x))
                            (setf status :ok)
                            (setf completed t)
                            :ok))
                    (unless completed
                      (emit-error :maxima_error
                                  (or (maxima-error-message)
                                      "Maxima error"))
                      (throw 'maxima::macsyma-quit catch-val))))
              (cancellation-requested (cnd)
                (emit-error :cancelled (condition-message cnd))
                (setf status :cancelled)))
          (when (eq status :ok)
            (emit-eval-result eval-id result
                              :label      (current-output-label-string)
                              :suppressed suppressed))
          (emit-eval-end eval-id status
                         :duration-ms (duration-ms start)))
        result))))
