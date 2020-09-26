(in-package typed-dispatch)

(defun get-type-list (arg-list env &key optional-arg-start-idx key-arg-start-idx)
  ;; TODO: Improve this
  (flet ((type-declared-p (var)
           (cdr (assoc 'type (nth-value 2 (variable-information var env))))))
    (let* ((undeclared-args     ())
           (type-list           ())
           (idx                 0)
           (processing-key-args nil)
           ;; ARGP to be used in conjunction with PROCESSING-KEY-ARGS
           (argp                t))
      (flet ((type (arg)
               (incf idx)
               (cond ((symbolp arg)
                      (unless (type-declared-p arg)
                        (push arg undeclared-args))
                      (variable-type arg env))
                     ((constantp arg) (type-of arg))
                     ((and (listp arg)
                           (eq 'the (first arg)))
                      (second arg))
                     (t (signal 'compiler-note "Cannot optimize this case!")))))
        (loop :for arg :in arg-list
              :do (when (and optional-arg-start-idx (= idx optional-arg-start-idx))
                    (push '&optional type-list))
                  (when (and key-arg-start-idx
                             (= idx key-arg-start-idx)
                             (not processing-key-args))
                    (push '&key type-list)
                    (setq processing-key-args t))
                  (if processing-key-args
                      (progn
                        (if argp
                            (push arg type-list)
                            (push (type arg) type-list))
                        (setq argp (not argp)))
                      (push (type arg) type-list))))
      (when (and optional-arg-start-idx (= idx optional-arg-start-idx))
        (push '&optional type-list))
      (when (and key-arg-start-idx
                 (= idx key-arg-start-idx)
                 (not processing-key-args))
        (push '&key type-list))
      (nreversef type-list)
      (if undeclared-args
          (mapcar (lambda (arg)
                    (signal 'undeclared-type :var arg))
                  (nreverse undeclared-args))
          type-list))))

;; As per the discussion at https://github.com/Bike/introspect-environment/issues/4
;; the FREE-VARIABLES-P cannot be substituted by a simple CLOSUREP (sb-kernel:closurep)
;; TODO: Find the limitations of HU.DWIM.WALKER (one known is MACROLET)
;; See the discussion at
;; https://www.reddit.com/r/lisp/comments/itf0gv/determining_freevariables_in_a_form/
(defun free-variables-p (form)
  (let (free-variables)
    (with-output-to-string (*error-output*)
      (setq free-variables 
            (remove-if-not (lambda (elt)
                             (typep elt 'hu.dwim.walker:free-variable-reference-form))
                           (hu.dwim.walker:collect-variable-references 
                            (hu.dwim.walker:walk-form
                             form)))))
    (mapcar (lambda (free-var-reference-form)
              (slot-value free-var-reference-form 'hu.dwim.walker::name))
            free-variables)))

(defun recursive-function-p (name body)
  (when body
    (cond ((listp body)
           (if (eq name (car body))
               t
               (some (curry 'recursive-function-p name) (cdr body))))
          (t nil))))

;;; - run-time correctness requires
;;;   - DEFINE-TYPED-FUNCTION -> DEFUN
;;;   - DEFUN-TYPED
;;; - compile-time correctness requires
;;;   - DEFINE-TYPED-FUNCTION -> DEFINE-COMPILER-MACRO
;;;   - GET-TYPE-LIST
;;;   - DEFINE-COMPILER-MACRO-TYPED

(defmacro define-typed-function (name untyped-lambda-list)
  "Define a function named NAME that can then be used for DEFUN-TYPED for specializing on ORDINARY and OPTIONAL argument types."
  (declare (type function-name       name)
           (type untyped-lambda-list untyped-lambda-list))
  ;; TODO: Handle the case of redefinition
  (let ((*name* name))
    (multiple-value-bind (body-form lambda-list) (defun-body untyped-lambda-list)
      `(eval-when (:compile-toplevel :load-toplevel :execute)
         (register-typed-function-wrapper ',name ',untyped-lambda-list)
         (defun ,name ,lambda-list
           ,body-form)

         ;; (define-compiler-macro ,name (&whole form &rest args &environment env)
         ;;   (declare (ignorable args))
         ;;   (if (eq (car form) ',name)
         ;;       ,(let ((type-list-code `(get-type-list ,(if key-arg-start-idx
         ;;                                                   `(cdr form)
         ;;                                                   `(subseq (cdr form)
         ;;                                                            0
         ;;                                                            (min (length (cdr form))
         ;;                                                                 (length ',typed-args))))
         ;;                                              env
         ;;                                              :optional-arg-start-idx
         ;;                                              ,optional-arg-start-idx
         ;;                                              :key-arg-start-idx
         ;;                                              ,key-arg-start-idx)))
         ;;          ;; The call to GET-TYPE-LIST needs to be surrounded by HANDLER-CASE
         ;;          ;; to report any failures that arise
         ;;          `(if (< 1 (policy-quality 'speed env)) ; optimize for speed
         ;;               (handler-case
         ;;                   (let ((type-list ,type-list-code))
         ;;                     (multiple-value-bind (body function dispatch-type-list)
         ;;                         (retrieve-typed-function ',name type-list)
         ;;                       (declare (ignore function))
         ;;                       (unless body
         ;;                         ;; TODO: Here the reason concerning free-variables is hardcoded
         ;;                         (signal "~%~S with TYPE-LIST ~S cannot be inlined due to free-variables" ',name dispatch-type-list))
         ;;                       (if-let ((compiler-function (retrieve-typed-function-compiler-macro
         ;;                                                    ',name type-list)))
         ;;                         (funcall compiler-function
         ;;                                  (cons body (rest form))
         ;;                                  env)
         ;;                         ;; TODO: Use some other declaration for inlining as well
         ;;                         ;; Optimized for speed and type information available
         ;;                         (if (recursive-function-p ',name body)
         ;;                             (signal "~%Inlining ~S results in (potentially infinite) recursive expansion"
         ;;                                     form)
         ;;                             `(,body ,@(cdr form))))))
         ;;                 (condition (condition)
         ;;                   (format *error-output* "~%; Unable to optimize ~S because:" form)
         ;;                   (write-string
         ;;                    (str:replace-all (string #\newline)
         ;;                                     (uiop:strcat #\newline #\; "   ")
         ;;                                     (format nil "~A" condition)))
         ;;                   (terpri *error-output*)
         ;;                   form))
         ;;               (progn
         ;;                 (handler-case
         ;;                     (let ((type-list ,type-list-code))
         ;;                       (retrieve-typed-function ',name type-list))
         ;;                   (condition (condition)
         ;;                     (unless (typep condition 'undeclared-type)
         ;;                       (format *error-output* "~%; While compiling ~S: " form)
         ;;                       (write-string
         ;;                        (str:replace-all (string #\newline)
         ;;                                         (uiop:strcat #\newline #\; "   ")
         ;;                                         (format nil "~A" condition)))
         ;;                       (terpri *error-output*))))
         ;;                 form)))
         ;;       (progn
         ;;         (signal 'optimize-speed-note
         ;;                 :form form
         ;;                 :reason "COMPILER-MACRO of ~S can only optimize raw function calls."
         ;;                 :args (list ',name))
         ;;         form)))
         ))))


(defmacro defun-typed (name typed-lambda-list return-type &body body)
  "  Expects OPTIONAL args to be in the form ((A TYPE) DEFAULT-VALUE) or ((A TYPE) DEFAULT-VALUE AP)."
  (declare (type function-name name)
           (type typed-lambda-list typed-lambda-list))
  ;; TODO: Handle the case when NAME is not bound to a TYPED-FUNCTION
  (let* ((lambda-list                 typed-lambda-list)
         (processed-lambda-list       (process-typed-lambda-list lambda-list))
         ;; no declaraionts in FREE-VARIABLE-ANALYSIS-FORM
         (free-variable-analysis-form `(lambda ,processed-lambda-list ,@body))
         (form                        `(defun-typed ,name ,typed-lambda-list ,@body)))
    (multiple-value-bind (param-list type-list)
        (remove-untyped-args lambda-list :typed t)
      (let* ((lambda-body `(lambda ,processed-lambda-list
                             (declare
                              ,@(let ((type-declarations   nil)
                                      (processing-key-args nil)
                                      ;; To be used in conjunction with processing-key-args.
                                      ;; Recall that key-args are stored as a PLIST.
                                      (is-param            nil)) 
                                  (loop :for type :in type-list
                                        :with param-list := param-list
                                        :do ;; (print (list type param-list))
                                            (cond ((eq type '&optional)) ; pass
                                                  ((eq type '&key)
                                                   (setq processing-key-args t))
                                                  (processing-key-args
                                                   (when is-param
                                                     (push `(type ,type ,(first param-list))
                                                           type-declarations))
                                                   (setq is-param (not is-param)))
                                                  (t
                                                   (push `(type ,type ,(first param-list))
                                                         type-declarations)))
                                            (unless (or (and processing-key-args is-param)
                                                        (member type lambda-list-keywords))
                                              (setq param-list (rest param-list))))
                                  type-declarations))
                             ,@(butlast body)
                             (the ,return-type ,@(last body)))))
        ;; TODO: We need the LAMBDA-BODY due to compiler macros, and "objects of type FUNCTION can't be dumped into fasl files. TODO: Is that an issue after 2.0.8+ as well?
        `(eval-when (:compile-toplevel :load-toplevel :execute)
           (register-typed-function ',name ',type-list
                                    ',(if-let (free-variables
                                               (free-variables-p
                                                ;; TODO: should not contain declarations
                                                free-variable-analysis-form))
                                        (progn
                                          (terpri *error-output*)
                                          (format *error-output* "; Will not inline ~%;   ")
                                          (write-string
                                           (str:replace-all
                                            (string #\newline)
                                            (uiop:strcat #\newline #\; "  ")
                                            (format nil "~A~%" form))
                                           *error-output*)
                                          (format *error-output*
                                                  "because free variables ~S were found"
                                                  free-variables)
                                          nil)
                                        lambda-body)
                                    ,lambda-body)
           ',name)))))

(defmacro define-compiler-macro-typed (name type-list compiler-macro-lambda-list
                                       &body body)
  "An example of a type-list for a function with optional args would be (STRING &OPTIONAL INTEGER)"
  (declare (type function-name name)
           (type type-list type-list))
  ;; TODO: Handle the case when NAME is not bound to a TYPED-FUNCTION

  (let ((gensym (gensym)))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (register-typed-function-compiler-macro
        ',name ',type-list
        (compile nil (parse-compiler-macro ',gensym
                                           ',compiler-macro-lambda-list
                                           ',body)))
       ',name)))


