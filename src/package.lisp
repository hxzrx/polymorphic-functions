
(polymorphic-functions.defpackage:defpackage :polymorphic-functions.extended-types
  #+extensible-compound-types
  (:use :extensible-compound-types-cl)
  #-extensible-compound-types
  (:use :cl)
  (:intern #:*extended-type-specifiers*
           #:upgraded-extended-type)
  (:shadow #:extended-type-specifier-p
           #:type-specifier-p
           #:supertypep
           #:subtypep
           #:typep
           #:type=)
  (:export #:extended-type-specifier-p
           #:cl-type-specifier-p
           #:type-specifier-p
           #:upgrade-extended-type
           #:supertypep
           #:subtypep
           #:typep
           #:type=

           #:*subtypep-alist*
           #:*extended-subtypep-functions*
           #:subtypep-not-knowo
           #:definitive-subtypep
           #:type-pair-=

           ))

(defpackage #:polymorphic-functions.nonuser
  (:use)
  (:documentation
   "Package for internal use by POLYMORPHIC-FUNCTIONS not intended for direct use by users."))

(polymorphic-functions.defpackage:defpackage :polymorphic-functions
  (:shadowing-import-exported-symbols :polymorphic-functions.extended-types)
  (:use :alexandria
        #+extensible-compound-types
        :extensible-compound-types-cl
        #-extensible-compound-types
        :cl)
  ;; #+extensible-compound-types
  ;; (:use :cl-form-types :alexandria :cl-environments-cl)
  (:import-from :extensible-compound-types
                #:orthogonally-specializing-type-specifier-p
                #:specializing)
  (:import-from :5am #:is #:def-test)
  (:import-from :let-plus #:let+ #:&values)
  (:import-from :compiler-macro-notes
                #:*muffled-notes-type*)
  (:import-from :polymorphic-functions.extended-types
                #:*extended-type-specifiers*
                #:upgraded-extended-type)
  (:import-from :introspect-environment
                #:compiler-macroexpand
                #:constant-form-value
                #:parse-compiler-macro)
  (:import-from :cl-environments.cltl2
                #:function-information
                #:variable-information
                #:declaration-information
                #:define-declaration
                #-extensible-compound-types
                #:augment-environment)
  (:export #:define-polymorphic-function
           #:undefine-polymorphic-function
           #:defpolymorph
           #:defpolymorph-compiler-macro
           #:undefpolymorph
           #:find-polymorph
           #:polymorph-apropos-list-type

           ;; Unstable API
           #:polymorphic-function
           #:polymorph
           #:no-applicable-polymorph
           #:polymorphic-function-type-lists
           #:inline-pf
           #:notinline-pf
           #:pf-defined-before-use
           #:not-pf-defined-before-use
           #:*compiler-macro-expanding-p*
           #:*disable-static-dispatch*

           #:*parametric-type-symbol-predicates*
           #:parametric-type-run-time-lambda-body
           #:parametric-type-compile-time-lambda-body

           #:%deparameterize-type

           #:suboptimal-polymorph-note
           #:more-optimal-polymorph-inapplicable

           #:specializing
           #:specializing-type-of

           #:pflet
           #:pflet*))

(in-package :polymorphic-functions)

(5am:def-suite :polymorphic-functions)

(defmacro catch-condition (form)
  `(handler-case ,form
     (condition (condition) condition)))

(defmacro is-error (form)
  `(5am:signals error ,form))

(defmacro list-named-lambda (name package lambda-list &body body &environment env)
  (declare (type list name)
           (ignorable env package))
  #+sbcl
  (progn
    #+extensible-compound-types
    `(sb-int:named-lambda ,name ,lambda-list
       ,@(nthcdr 2 (let ((*disable-extype-checks* t))
                     (macroexpand-1
                      `(,(find-symbol "LAMBDA" :extensible-compound-types-cl)
                        ,lambda-list ,@body)))))
    #-extensible-compound-types
    `(sb-int:named-lambda ,name ,lambda-list
       ,@body))
  #+ccl
  `(ccl:nfunction ,name
                  #+extensible-compound-types
                  (cl:lambda ,@(rest (macroexpand-1 `(lambda ,lambda-list ,@body) env)))
                  #-extensible-compound-types
                  (cl:lambda ,lambda-list ,@body))
  #-(or sbcl ccl)
  (let ((function-name (intern (write-to-string name) package)))
    `(flet ((,function-name ,lambda-list ,@body))
       #',function-name)))

(define-symbol-macro optim-safety (= 3 (policy-quality 'safety env)))

(define-symbol-macro optim-debug (or (= 3 (policy-quality 'debug env))
                                     (> (policy-quality 'debug env)
                                        (policy-quality 'speed env))))
(define-symbol-macro optim-speed (and (/= 3 (policy-quality 'debug env))
                                      (= 3 (policy-quality 'speed env))))
(define-symbol-macro optim-slight-speed (and (/= 3 (policy-quality 'debug env))
                                             (/= 3 (policy-quality 'speed env))
                                             (<= (policy-quality 'debug env)
                                                 (policy-quality 'speed env))))

#-extensible-compound-types
(defun typexpand (type-specifier &optional env)
  (if (cl-type-specifier-p type-specifier)
      (ctype::typexpand type-specifier env)
      type-specifier))

(defun policy-quality (quality &optional env)
  (second (assoc quality (declaration-information 'optimize env))))

(defun macroexpand-all (form &optional env)
  (cl-form-types.walker:walk-form (lambda (form env)
                                    (optima:match form
                                      ((list* name _)
                                       (cond ((listp name)
                                              form)
                                             ((and (compiler-macro-function name env)
                                                   (not (eq (find-package :cl)
                                                            (symbol-package name))))
                                              (funcall (compiler-macro-function name env)
                                                       form
                                                       env))
                                             (t
                                              form)))
                                      (_
                                       form)))
                                  form
                                  env))

(defun cl-type-specifier-p (type-specifier)
  "Returns true if TYPE-SPECIFIER is a valid type specfiier."
  (block nil
    #+sbcl (return (ignore-some-conditions (sb-kernel:parse-unknown-type)
                     (sb-ext:valid-type-specifier-p type-specifier)))
    #+openmcl (return (ccl:type-specifier-p type-specifier))
    #+ecl (return (c::valid-type-specifier type-specifier))
    #+clisp (return (null
                     (nth-value 1 (ignore-errors
                                   (ext:type-expand type-specifier)))))
    #-(or sbcl openmcl ecl lisp)
    (or (when (symbolp type-specifier)
          (documentation type-specifier 'type))
        (error "TYPE-SPECIFIER-P not available for this implementation"))))

(defun setf-function-name-p (object)
  (and (listp object)
       (null (cddr object))
       (eq 'setf (car object))
       (symbolp (cadr object))))

(extensible-compound-types:deftype function-name ()
  ;; Doesn't work great with subtypep
  "Ref: http://www.lispworks.com/documentation/HyperSpec/Body/26_glo_f.htm#function_name"
  `(or symbol (satisfies setf-function-name-p)))

(defun form-type (form env &key (return-default-type t)
                             expand-compiler-macros constant-eql-types)
  (or (ignore-errors
       (handler-bind ((cl-form-types:unknown-special-operator
                        (lambda (c)
                          (declare (ignore c))
                          (invoke-restart 'cl-form-types:return-default-type
                                          return-default-type))))
         (cl-form-types:form-type form env
                                  :expand-compiler-macros expand-compiler-macros
                                  :constant-eql-types constant-eql-types)))
      t))

(defun nth-form-type (form env n
                      &optional
                        constant-eql-types expand-compiler-macros (return-default-type t))
  (or (ignore-errors
       (handler-bind ((cl-form-types:unknown-special-operator
                        (lambda (c)
                          (declare (ignore c))
                          (invoke-restart 'cl-form-types:return-default-type
                                          return-default-type))))
         (cl-form-types:nth-form-type form env n constant-eql-types expand-compiler-macros)))
      t))
