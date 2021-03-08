(in-package adhoc-polymorphic-functions)

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
;;;   - DEFINE-POLYMORPH-FUNCTION -> DEFUN
;;;   - DEFPOLYMORPH
;;; - compile-time correctness requires
;;;   - DEFINE-POLYMORPH-FUNCTION -> DEFINE-COMPILER-MACRO
;;;   - GET-TYPE-LIST
;;;   - DEFPOLYMORPH-COMPILER-MACRO

(defmacro with-compiler-note (&body body)
  `(handler-case (progn ,@body)
     (no-applicable-polymorph (condition)
       (format *error-output*
               "~%; While compiling ~S: ~&; ~A"
               form
               (str:join (uiop:strcat #\newline ";  ")
                         (str:split #\newline (format nil "~A" condition))))
       original-form)
     (form-type-failure (condition)
       (when (< 1 (policy-quality 'speed env))
         (format *error-output*
                 (uiop:strcat "~%; Optimization of ~&;  "
                              (str:join (uiop:strcat #\newline ";  ")
                                        (str:split #\newline (format nil " ~S"
                                                                     original-form)))
                              "~%; is left to ~A because ADHOC-POLYMORPHIC-FUNCTIONS "
                              "is unable to optimize it ~%; because~&; ~A~&; ~&")
                 (lisp-implementation-type)
                 (str:join (uiop:strcat #\newline ";  ")
                           (str:split #\newline (format nil "~A" condition)))))
       (if (= 3 (policy-quality 'debug env))
           original-form
           block-form))
     ((or polymorph-body-has-free-variables
       recursive-expansion-is-possibly-infinite) (condition)
       (when (< 1 (policy-quality 'speed env))
         (format *error-output*
                 (uiop:strcat "~&; "
                              (format nil "Unable to optimize ~S because:" original-form)
                              "~&;  ~A")
                 (str:join (uiop:strcat #\newline ";  ")
                           (str:split #\newline (format nil "~A" condition)))))
       ;; FIXME: Will SBCL optimize these cases - should these conditions be merged
       ;; into the previous FORM-TYPE-FAILURE case?
       (if (= 3 (policy-quality 'debug env))
           original-form
           block-form))))

(defmacro define-polymorphic-function (name untyped-lambda-list &key overwrite &environment env)
  "Define a function named NAME that can then be used for DEFPOLYMORPH
for specializing on various argument types.

If OVERWRITE is T, all the existing polymorphs associated with NAME are deleted,
and new polymorphs will be ready to be installed.
If OVERWRITE is NIL, a continuable error is raised."
  (declare (type function-name       name)
           (type untyped-lambda-list untyped-lambda-list))
  ;; TODO: Handle the case of redefinition
  (let ((*name*        name)
        (*environment*  env))
    (multiple-value-bind (body-form lambda-list) (defun-body untyped-lambda-list)
      `(progn
         (eval-when (:compile-toplevel)
           ,(when overwrite
              `(undefine-polymorphic-function ',name))
           (register-polymorph-wrapper ',name ',untyped-lambda-list))
         (eval-when (:load-toplevel :execute)
           (unless (gethash ',name *polymorphic-function-table*)
             (register-polymorph-wrapper ',name ',untyped-lambda-list :overwrite ,overwrite)))
         #+sbcl (sb-c:defknown ,name * * nil :overwrite-fndb-silently t)
         (defun ,name ,lambda-list
           ,body-form)
         (define-compiler-macro ,name (&whole form &rest args &environment env)
           (declare (ignore args))
           ;; FIXME: Is the assumption that FORM either starts with ',NAME or FUNCALL correct?
           (let ((*environment*                 env)
                 (*compiler-macro-expanding-p*    t)
                 (original-form                form)
                 (block-form                    nil))
             (with-compiler-note
               (when (eq 'funcall (car form))
                 (setf form (cons (second (second form))
                                  (cddr form))))
               (setq block-form
                     (let ((name (first form))
                           (gensyms (make-gensym-list (length (rest form)))))
                       `(let (,@(loop :for sym :in gensyms
                                      :for form :in (rest form)
                                      :collect `(,sym ,form)))
                          (block ,name
                            (funcall (the function
                                          (nth-value 1 (retrieve-polymorph
                                                        ',name
                                                        ,@gensyms)))
                                     ,@gensyms)))))
               (let ((arg-list (rest form)))
                 (multiple-value-bind (fbody function dispatch-type-list)
                     (apply 'retrieve-polymorph ',name arg-list)
                   (declare (ignore function))
                   (if (< 1 (policy-quality 'speed env))
                       (let ((fbody-return-type (when fbody
                                                  (nth 1 (nth 2 (nth 4 fbody))))))
                         (unless fbody
                           ;; TODO: Here the reason concerning free-variables is hardcoded
                           (signal 'polymorph-body-has-free-variables :name ',name
                                                                      :type-list dispatch-type-list))
                         (if-let ((compiler-function (apply
                                                      'retrieve-polymorph-compiler-macro
                                                      ',name arg-list)))
                           (funcall compiler-function
                                    (cons fbody (rest form))
                                    env)
                           ;; TODO: Use some other declaration for inlining as well
                           ;; Optimized for speed and type information available
                           (if (recursive-function-p ',name fbody)
                               (signal 'recursive-expansion-is-possibly-infinite
                                       :form form)
                               `(the ,fbody-return-type (,fbody ,@(cdr form))))))
                       original-form))))))))))

(defun extract-declarations (body)
  "Returns two values: DECLARATIONS and remaining BODY"
  (cond ((null body)
         (values `(declare) nil))
        ((and (listp (car body))
              (eq 'declare (caar body)))
         (multiple-value-bind (declarations rest-body) (extract-declarations (rest body))
           (values (nconc (cons 'declare (cdar body))
                          (rest declarations))
                   rest-body)))
        (t
         (values `(declare) body))))

(defun ensure-non-intersecting-type-lists (name type-list)
  (loop :for list :in (polymorph-wrapper-type-lists
                       (retrieve-polymorph-wrapper
                        name))
        :do (when (and (type-list-intersect-p type-list list)
                       (not (equalp type-list list)))
              (error "The given TYPE-LIST ~%  ~S~%intersects with the type list ~%  ~S~% of an existing polymorph"
                     type-list
                     list)
              (return))))

(defmacro defpolymorph (name typed-lambda-list return-type &body body &environment env)
  "  Expects OPTIONAL or KEY args to be in the form ((A TYPE) DEFAULT-VALUE) or ((A TYPE) DEFAULT-VALUE AP)."
  (declare (type function-name name)
           (type typed-lambda-list typed-lambda-list))
  (let* ((*name*               name)
         (untyped-lambda-list (polymorph-wrapper-lambda-list
                               (retrieve-polymorph-wrapper
                                name))))
    (multiple-value-bind (param-list type-list)
        (defun-lambda-list typed-lambda-list :typed t)
      (assert (type-list-compatible-p type-list untyped-lambda-list)
              nil
              "TYPE-LIST ~S is not compatible with the LAMBDA-LIST ~S of the POLYMORPHs associated with ~S"
              type-list untyped-lambda-list name)
      (ensure-non-intersecting-type-lists name type-list)
      (multiple-value-bind (declarations body) (extract-declarations body)
        (let (;; no declarations in FREE-VARIABLE-ANALYSIS-FORM
              (free-variable-analysis-form `(lambda ,param-list (block ,name ,@body)))
              (form                        `(defpolymorph ,name ,typed-lambda-list ,@body)))
          (let* ((lambda-body `(lambda ,param-list
                                 ,(lambda-declarations typed-lambda-list :typed t)
                                 ,declarations
                                 (block ,name
                                   ,@(butlast body)
                                   (the ,return-type ,@(or (last body) '(nil))))))
                 ;; TODO: should not contain declarations
                 (free-variables (free-variables-p free-variable-analysis-form))
                 #+sbcl
                 (sbcl-transform `(sb-c:deftransform ,name (,param-list ,type-list *
                                                            :policy (> speed 1))
                                    `(apply ,',lambda-body ,@',(sbcl-transform-body-args typed-lambda-list
                                                                                         :typed t)))))
            ;; NOTE: We need the LAMBDA-BODY due to compiler macros,
            ;; and "objects of type FUNCTION can't be dumped into fasl files
            `(progn
               #+sbcl ,(unless (or free-variables
                                   (recursive-function-p name lambda-body))
                         (if (= 3 (policy-quality 'debug env))
                             sbcl-transform
                             `(locally (declare (sb-ext:muffle-conditions style-warning))
                                (handler-bind ((style-warning #'muffle-warning))
                                  ,sbcl-transform))))
               (eval-when (:compile-toplevel :load-toplevel :execute)
                 (register-polymorph ',name ',type-list
                                     ',(if free-variables
                                           (progn
                                             (terpri *error-output*)
                                             (format *error-output* "; Will not inline ~%;   ")
                                             (write-string
                                              (str:replace-all
                                               (string #\newline)
                                               (uiop:strcat #\newline #\; "  ")
                                               (format nil "~S~&" form))
                                              *error-output*)
                                             (format *error-output*
                                                     "because free variables ~S were found"
                                                     free-variables)
                                             nil)
                                           lambda-body)
                                     ,lambda-body)
                 ',name))))))))

(defmacro defpolymorph-compiler-macro (name type-list compiler-macro-lambda-list
                                       &body body)
  "An example of a type-list for a function with optional args would be (STRING &OPTIONAL INTEGER)"
  (declare (type function-name name)
           (type type-list type-list))
  ;; TODO: Handle the case when NAME is not bound to a POLYMORPH
  (let ((lambda-list (polymorph-wrapper-lambda-list
                      (retrieve-polymorph-wrapper
                       name)))
        (type-list   (let ((key-position (position '&key type-list)))
                       (if key-position
                           (append (subseq type-list 0 key-position)
                                   '(&key)
                                   (sort (subseq type-list (1+ key-position))
                                         #'string< :key #'first))
                           type-list))))
    (assert (type-list-compatible-p type-list lambda-list)
            nil
            "TYPE-LIST ~S is not compatible with the LAMBDA-LIST ~S of the POLYMORPHs associated with ~S"
            type-list lambda-list name)
    (ensure-non-intersecting-type-lists name type-list)
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (register-polymorph-compiler-macro
        ',name ',type-list
        (compile nil (parse-compiler-macro nil
                                           ',compiler-macro-lambda-list
                                           ',body)))
       ',name)))

(defun undefpolymorph (name type-list)
  "Remove the POLYMORPH associated with NAME with TYPE-LIST"
  #+sbcl
  (let ((info  (sb-c::fun-info-or-lose name))
        (ctype (sb-c::specifier-type (list 'function
                                           type-list
                                           '*))))
    (setf (sb-c::fun-info-transforms info)
          (remove-if (curry #'sb-c::type= ctype)
                     (sb-c::fun-info-transforms info)
                     :key #'sb-c::transform-type)))
  (remove-polymorph name type-list))

(defun undefine-polymorphic-function (name)
  "Remove the POLYMORPH(-WRAPPER) defined by DEFINE-POLYMORPH"
  (remhash name *polymorphic-function-table*)
  (fmakunbound name)
  (setf (compiler-macro-function name) nil))
