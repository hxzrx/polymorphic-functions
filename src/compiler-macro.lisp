(in-package :polymorphic-functions)

(defvar *disable-static-dispatch* nil
  "If value at the time of compilation of the call-site is non-NIL,
the polymorphic-function being called at the call-site is dispatched dynamically.")

;;; TODO: Allow user to specify custom optim-speed etc

(defun pf-compiler-macro-function (form &optional env)
  (when (eq 'apply (first form))
    (format *error-output* "~A can optimize cases other than FUNCALL and raw call!~%Ask the maintainer of POLYMORPHIC-FUNCTIONS to provide support for this case!"
            (lisp-implementation-type))
    (return-from pf-compiler-macro-function form))

  (let* ((*environment*                 env)
         (*compiler-macro-expanding-p*    t)
         (original-form                form))

    (multiple-value-bind (name args)
        (if (eq 'funcall (car form))
            (values (optima:match (second form)
                      ((list 'cl:function name)
                       name)
                      (variable
                       variable))
                    (rest (rest form)))
            (values (first form)
                    (rest form)))

      (compiler-macro-notes:with-notes
          (original-form env :name (fdefinition name)
                             :unwind-on-signal nil
                             :optimization-note-condition
                             (and optim-speed
                                  (not *disable-static-dispatch*)))

        (unless (macroexpand 'top-level-p env)
          (return-from pf-compiler-macro-function form))

        (let* ((arg-list  (mapcar (lambda (form)
                                    (with-output-to-string (*error-output*)
                                      (setq form (macroexpand-all form env)))
                                    form)
                                  args))
               ;; Expanding things here results in O(n) calls to this function
               ;; rather than O(n^2); although the actual effects of this are
               ;; insignificant for day-to-day compilations
               (arg-types (mapcar (lambda (form)
                                    (let (form-type)
                                      ;; We already have the expanded forms
                                      (with-output-to-string (*error-output*)
                                        (setq form-type (nth-form-type form env 0 nil nil)))
                                      form-type))
                                  arg-list))
               ;; FORM-TYPE-FAILURE: We not only want to inform the user that there
               ;; was a failure, but also inform them what the failure-ing form was.
               ;; However, even if there was what appeared to be a failure on an
               ;; earlier polymorph (because its type list was more specific than T),
               ;; the possibility that there exists a later polymorph remains.
               ;; Therefore, we first muffle the duplicated FORM-TYPE-FAILUREs;
               ;; then, if a polymorph was found (see COND below), we further muffle
               ;; the non-duplicated failures as well.
               (form-type-failures nil)
               (polymorph (handler-bind ((form-type-failure
                                           (lambda (c)
                                             (if (find c form-type-failures
                                                       :test (lambda (c1 c2)
                                                               (equalp (form c1)
                                                                       (form c2))))
                                                 (compiler-macro-notes:muffle c)
                                                 (push c form-type-failures)))))
                            (apply #'compiler-retrieve-polymorph
                                   name (mapcar #'cons (rest form) arg-types)))))

          (when (and optim-debug
                     (not (declaration-information 'pf-defined-before-use env)))
            (return-from pf-compiler-macro-function original-form))
          (cond ((and (null polymorph)
                      optim-speed
                      ;; We can be sure that *something* will be printed
                      ;; However, if there were no failures, and no polymorphs
                      ;; *nothing* will be shown! And then we rely on the
                      ;; NO-APPLICABLE-POLYMORPH/COMPILER-NOTE below.
                      form-type-failures)
                 (return-from pf-compiler-macro-function original-form))
                (polymorph
                 ;; We muffle, because unsuccessful searches could have resulted
                 ;; in compiler notes
                 (mapc #'compiler-macro-notes:muffle form-type-failures)))
          (when (and (null polymorph)
                     (or optim-speed optim-safety
                         (declaration-information 'pf-defined-before-use env)))
            (handler-case (funcall (polymorphic-function-default (fdefinition name))
                                   name env arg-list arg-types)
              (condition (c)
                (if (declaration-information 'pf-defined-before-use env)
                    (error c)
                    (signal c)))))
          (when (or (null polymorph)
                    (not optim-speed)
                    *disable-static-dispatch*)
            (return-from pf-compiler-macro-function original-form))

          (with-slots (inline-p return-type type-list
                       more-optimal-type-list suboptimal-note
                       compiler-macro-lambda lambda-list-type
                       static-dispatch-name parameters)
              polymorph
            (let ((inline-lambda-body (polymorph-inline-lambda-body polymorph))
                  (return-type        return-type))
              (when inline-lambda-body
                (setq inline-lambda-body
                      ;; The only thing we want to preserve from the ENV are the OPTIMIZE
                      ;; declarations.
                      ;; Otherwise, the other information must be excluded
                      ;; because the POLYMORPH was originally expected to be defined in
                      ;; null env; see the discussion preceding DEFPOLYMORPH macro for
                      ;; more details
                      (let* ((augmented-env (augment-environment
                                             env
                                             :declare (list
                                                       (cons 'optimize
                                                             (declaration-information 'optimize env)))))
                             (notes nil)
                             ;; The source of compile-time subtype-polymorphism
                             (*deparameterizer-alist* (copy-alist *deparameterizer-alist*))
                             (compiler-macro-notes:*muffled-notes-type*
                               `(or ,compiler-macro-notes:*muffled-notes-type*
                                    ,@(declaration-information
                                       'compiler-macro-notes:muffle
                                       env)))
                             (lambda-with-enhanced-declarations
                               (optima:ematch inline-lambda-body
                                 ((list lambda args ignorable-decl _ more-decl
                                        (list 'let
                                              type-parameter-list
                                              _
                                              (list* 'block block-name body)))
                                  `(,lambda ,args
                                     ;; The source of compile-time subtype-polymorphism
                                     ,ignorable-decl
                                     ,@(let+ (((&values
                                                enhanced-decl
                                                new-type-parameter-ignorable-declaration
                                                new-type-parameter-type-decl
                                                deparameterized-return-type)
                                               (enhanced-lambda-declarations parameters
                                                                             arg-types
                                                                             return-type)))
                                         (setq return-type deparameterized-return-type)
                                         `(,enhanced-decl
                                           ,more-decl
                                           (let ,type-parameter-list
                                             ,new-type-parameter-type-decl
                                             ,new-type-parameter-ignorable-declaration
                                             (block ,block-name ,@body)))))))))

                        ;; We need to expand here, because we want to report
                        ;;   that the notes generated from the result of this expansion
                        ;;   were actually generated from THIS PARTICULAR TOP-LEVEL FORM
                        ;; But even besides compiler notes, this expansion is also
                        ;;   required so that the type parameters above are considered appropriately.
                        ;;   Though, it might be possible to supply this information through
                        ;;   SYMBOL-MACROLET as we do below for TOP-LEVEL-P

                        (when compiler-macro-lambda
                          (let* ((compiler-macro-form
                                   (cons lambda-with-enhanced-declarations args))
                                 (expansion
                                   (handler-bind
                                       ((compiler-macro-notes:note
                                          (lambda (note)
                                            (unless
                                                (typep note *muffled-notes-type*)
                                              (compiler-macro-notes::swank-signal note env)
                                              (push note notes)))))
                                     (let (#+extensible-compound-types
                                           (*disable-extype-checks* t))
                                       (eval
                                        `(cl:symbol-macrolet
                                             ((compiler-macro-notes::previous-form
                                                ,form)
                                              (compiler-macro-notes::parent-form
                                                ,compiler-macro-form))
                                           (funcall ,compiler-macro-lambda
                                                    ',form
                                                    ,augmented-env)))))))
                            (unless (equal expansion form)
                              (when more-optimal-type-list
                                (signal 'more-optimal-polymorph-inapplicable
                                        :more-optimal-type-list
                                        more-optimal-type-list))
                              (when suboptimal-note
                                (signal suboptimal-note :type-list type-list))
                              (return-from compiler-macro-notes:with-notes
                                expansion))))

                        (let ((macroexpanded-form
                                (handler-bind
                                    ((compiler-macro-notes:note
                                       (lambda (note)
                                         (unless
                                             (typep note *muffled-notes-type*)
                                           (compiler-macro-notes::swank-signal note env)
                                           (push note notes)))))
                                  (lastcar
                                   (let (#+extensible-compound-types
                                         (*disable-extype-checks* t))
                                     (macroexpand-all
                                      `(cl:symbol-macrolet
                                           ((compiler-macro-notes::previous-form
                                              ,form)
                                            (compiler-macro-notes::parent-form
                                              ,lambda-with-enhanced-declarations))
                                         ,lambda-with-enhanced-declarations)
                                      augmented-env))))))
                          ;; MUFFLE because they would already have been reported!
                          (mapc #'compiler-macro-notes:muffle notes)
                          (let ((enhanced-return-type
                                  (lastcar
                                   (form-type macroexpanded-form augmented-env))))
                            ;; We can't just substitute the enhanced-return-type
                            ;; because it is possible that the originally specified
                            ;; return-type was more specific than what a derivation
                            ;; could tell us.
                            (setq return-type
                                  (cond ((subtypep enhanced-return-type return-type)
                                         enhanced-return-type)
                                        ((subtypep `(and ,enhanced-return-type
                                                         ,return-type)
                                                   nil)
                                         (signal 'compile-time-return-type-mismatch
                                                 :derived enhanced-return-type
                                                 :declared return-type
                                                 :form lambda-with-enhanced-declarations)
                                         (return-from pf-compiler-macro-function
                                           original-form))
                                        (t
                                         (cl-form-types::combine-values-types
                                          'and return-type enhanced-return-type)))))
                          ;; Some macroexpand-all can produce a (function (lambda ...)) from (lambda ...)
                          ;; Some others do not
                          (if (eq 'cl:function (first macroexpanded-form))
                              (second macroexpanded-form)
                              macroexpanded-form)))))
              (cond (optim-speed
                     (when more-optimal-type-list
                       (signal 'more-optimal-polymorph-inapplicable
                               :more-optimal-type-list more-optimal-type-list))
                     (when suboptimal-note (signal suboptimal-note :type-list type-list))
                     (return-from compiler-macro-notes:with-notes
                       (let ((inline-pf
                               (assoc 'inline-pf
                                      (nth-value 2 (function-information name env))))
                             (inline-dispatch-form
                               `(the ,return-type
                                     (symbol-macrolet ((top-level-p nil))
                                       (,inline-lambda-body ,@arg-list))))
                             (non-inline-dispatch-form
                               `(the ,return-type
                                     (symbol-macrolet ((top-level-p nil))
                                       (,static-dispatch-name ,@arg-list)))))
                         (ecase inline-p
                           ((t)
                            (assert inline-lambda-body)
                            (if (eq 'notinline-pf (cdr inline-pf))
                                non-inline-dispatch-form
                                inline-dispatch-form))
                           ((nil)
                            (when (eq 'inline-pf (cdr inline-pf))
                              (signal 'polymorph-has-no-inline-lambda-body
                                      :name name :type-list type-list))
                            non-inline-dispatch-form)
                           ((:maybe)
                            (cond ((null inline-pf)
                                   non-inline-dispatch-form)
                                  ((eq 'inline-pf (cdr inline-pf))
                                   (assert inline-lambda-body)
                                   inline-dispatch-form)
                                  ((eq 'notinline-pf (cdr inline-pf))
                                   non-inline-dispatch-form)
                                  (t
                                   (error "Unexpected case in pf-compiler-macro!"))))))))
                    (t
                     (return-from pf-compiler-macro-function form))))))))))

;; Separate into a function and macro-function so that redefinitions during
;; development are caught easily
(defun pf-compiler-macro (form &optional env)
  (pf-compiler-macro-function form env))

(defmacro pflet (bindings &body body)
  ;; TODO: Should we just call ENHANCED-LAMBDA-DECLARATIONS in general?
  "Like LET but when expanded inside PF-COMPILER-MACRO, this uses information in
*DEPARAMETERIZER-ALIST* to deparameterize types."
  `(let ,bindings
     ,@(multiple-value-bind (body decls) (alexandria:parse-body body)
         `(,@(loop :for decl :in decls
                   :collect
                   `(declare
                     ,@(loop :with specs := (rest decl)
                             :for spec :in specs
                             :collect
                             (if (and (eq 'type (first spec))
                                      (parametric-type-specifier-p (second spec)))
                                 `(type ,(deparameterize-type (second spec))
                                        ,@(nthcdr 2 spec))
                                 spec))))
           ,@body))))

(defmacro pflet* (bindings &body body)
  "Like LET* but when expanded inside PF-COMPILER-MACRO, this uses information in
*DEPARAMETERIZER-ALIST* to deparameterize types."
  `(let* ,bindings
     ,@(multiple-value-bind (body decls) (alexandria:parse-body body)
         `(,@(loop :for decl :in decls
                   :collect `(declare
                              ,@(loop :with specs := (rest decl)
                                      :for spec :in specs
                                      :collect (if (and (eq 'type (first spec))
                                                        (parametric-type-specifier-p (second spec)))
                                                   `(type ,(deparameterize-type (second spec))
                                                          ,@(nthcdr 2 spec))
                                                   spec))))
           ,@body))))
