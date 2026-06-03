;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Envelope construction and JSON serialization.
;;;
;;; An envelope is a Lisp plist with keyword keys.  Examples:
;;;
;;;   (make-envelope :stream_begin :view_id "v_42" :kind :ode_trajectory)
;;;
;;; Internally that's the list
;;;   (:type :stream_begin :view_id "v_42" :kind :ode_trajectory)
;;;
;;; envelope-to-json emits the canonical JSON form:
;;;   {"type":"stream_begin","view_id":"v_42","kind":"ode_trajectory"}
;;;
;;; Each envelope has a :type discriminator (capabilities, ready,
;;; eval_begin, eval_result, eval_end, output, display, error,
;;; debug_enter, debug_leave, stdin_request, vars, stream_begin,
;;; frame, progress, stream_end, stream_error, log).  Schemas live in
;;; ../schemas/envelopes/v1/.
;;;
;;; Convention for nested data:
;;;   - plist (cons cell, even length, alternating keyword/value)
;;;     → JSON object
;;;   - vector (cl:vector)        → JSON array
;;;   - hash-table                → JSON object (used for mime bundles)
;;;   - string / integer / float  → corresponding JSON scalar
;;;   - keyword                   → JSON string (lowercase, hyphen→underscore)
;;;   - t / nil                   → true / null
;;;
;;; We hand-roll JSON output to stay dependency-free.  The envelope
;;; shape is well-defined and small; ~80 LOC of JSON emission is
;;; cheaper than pulling in cl-json or jonathan.

(in-package :kernel-events)

(defun make-envelope (type &rest body)
  "Construct an envelope plist with TYPE slotted in as :type.
   Returns a plist suitable for envelope-to-json / call-sinks.

   Example:
     (make-envelope :frame
                    :view_id \"v_1\" :seq 1
                    :payload (list :t 0.05 :y #(1.0 0.02)))"
  (list* :type type body))

(defun emit-envelope (envelope)
  "Deliver ENVELOPE to all registered sinks.  Sinks receive the Lisp
   envelope plist (not a JSON string) so they can choose their own
   encoding — fd-3 transports call envelope-to-json to produce a JSON
   line; test sinks inspect the plist directly."
  (call-sinks envelope)
  (values))

;;; --- JSON serialization ------------------------------------------------
;;;
;;; Helpers come before write-json so SBCL doesn't issue forward-
;;; reference style warnings when the file is loaded as source.

(defun keyword-to-json-key (kw)
  "Convert a keyword to its canonical JSON key string:
   lowercase, hyphens replaced with underscores."
  (substitute #\_ #\- (string-downcase (symbol-name kw))))

(defun write-json-string-body (s out)
  "Write the *body* of a JSON string (no surrounding quotes) — the
   contents of S with RFC 8259 escapes applied."
  (loop for c across s
        for code = (char-code c)
        do (cond
             ((= code 34) (write-string "\\\"" out))  ; "
             ((= code 92) (write-string "\\\\" out))  ; \
             ((= code  8) (write-string "\\b" out))
             ((= code  9) (write-string "\\t" out))
             ((= code 10) (write-string "\\n" out))
             ((= code 12) (write-string "\\f" out))
             ((= code 13) (write-string "\\r" out))
             ((< code 32) (format out "\\u~4,'0x" code))
             ((= code 127) (write-string "\\u007f" out))
             (t (write-char c out)))))

(defun json-escape-string (s)
  "Return S with RFC 8259 JSON-string escapes applied.  Does *not*
   add surrounding quotes — that's write-json's job."
  (with-output-to-string (out)
    (write-json-string-body s out)))

(defun write-json-float (x out)
  "Write the JSON encoding of float X.  Non-finite values (NaN, ±Inf)
   are encoded as null — JSON has no native representation for them."
  (cond
    ((not (= x x))                                ; NaN
     (write-string "null" out))
    ((and (floatp x) (= x (* x 2)) (not (zerop x)))  ; ±Inf
     (write-string "null" out))
    (t
     ;; Avoid Lisp's default exponent marker (e.g. "1.5d0").
     ;; Convert to single-float by way of double for consistent
     ;; ~f output across implementations.
     (let ((*read-default-float-format* 'double-float))
       (format out "~f" x)))))

;; write-json and its helpers form a mutual recursion at the top
;; level.  Forward-declare to keep SBCL's source-load style-warnings
;; quiet.
(declaim (ftype (function (t stream) t)
                write-json
                write-json-object-from-plist
                write-json-object-from-hash))

(defun envelope-to-json (envelope)
  "Serialize ENVELOPE (a Lisp plist) to a JSON string.  No trailing
   newline — the transport adds that if it wants JSON-lines framing."
  (with-output-to-string (out)
    (write-json envelope out)))

(defun write-json (value out)
  "Write the JSON encoding of VALUE to the stream OUT."
  (cond
    ((null value)          (write-string "null" out))
    ((eq value t)          (write-string "true" out))
    ((eq value :false)     (write-string "false" out))
    ((eq value :null)      (write-string "null" out))
    ((keywordp value)
     ;; Keywords render as JSON strings with hyphens→underscores
     ;; and lowercased.  Useful for sum-type discriminators like
     ;; :type :stream_begin.
     (write-char #\" out)
     (write-string (keyword-to-json-key value) out)
     (write-char #\" out))
    ((stringp value)
     (write-char #\" out)
     (write-json-string-body value out)
     (write-char #\" out))
    ((integerp value)
     (format out "~d" value))
    ((floatp value)
     (write-json-float value out))
    ((rationalp value)
     (write-json-float (float value 1.0d0) out))
    ((symbolp value)
     ;; Non-keyword symbol → JSON string (lowercased).
     (write-char #\" out)
     (write-string (string-downcase (symbol-name value)) out)
     (write-char #\" out))
    ((vectorp value)
     (write-char #\[ out)
     (loop with first = t
           for v across value
           do (if first (setf first nil) (write-char #\, out))
              (write-json v out))
     (write-char #\] out))
    ((hash-table-p value)
     (write-json-object-from-hash value out))
    ((consp value)
     ;; Plist → JSON object.  We don't auto-detect arrays-as-lists
     ;; because plists and "list of pairs" would collide.  Callers
     ;; that want JSON arrays use vectors.
     (write-json-object-from-plist value out))
    (t
     (error "kernel-events: don't know how to serialize ~s to JSON"
            value))))

(defun write-json-object-from-plist (plist out)
  "Encode a plist as a JSON object."
  (unless (evenp (length plist))
    (error "kernel-events: plist has odd length: ~s" plist))
  (write-char #\{ out)
  (loop with first = t
        for (k v) on plist by #'cddr
        do (unless (keywordp k)
             (error "kernel-events: plist key ~s is not a keyword" k))
           (if first (setf first nil) (write-char #\, out))
           (write-char #\" out)
           (write-string (keyword-to-json-key k) out)
           (write-string "\":" out)
           (write-json v out))
  (write-char #\} out))

(defun write-json-object-from-hash (table out)
  "Encode a hash-table as a JSON object.  Keys may be strings or
   keywords; values go through write-json recursively.  Used for mime
   bundles where the keys are mime-type strings like
   \"application/x-maxima-latex\"."
  (write-char #\{ out)
  (let ((first t))
    (maphash
      (lambda (k v)
        (if first (setf first nil) (write-char #\, out))
        (write-char #\" out)
        (etypecase k
          (string  (write-json-string-body k out))
          (keyword (write-string (keyword-to-json-key k) out)))
        (write-string "\":" out)
        (write-json v out))
      table))
  (write-char #\} out))
