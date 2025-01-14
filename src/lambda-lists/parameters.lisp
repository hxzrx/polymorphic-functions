(in-package :polymorphic-functions)

(5am:def-suite lambda-list :in :polymorphic-functions)

;;; FIXME: Even though this file does a good amount of lambda-list processing
;;; it does not do some things, and not quite validation yet.

(5am:def-suite effective-lambda-list :in lambda-list)

(defun polymorphic-function-make-effective-lambda-list (untyped-lambda-list)
  (check-type untyped-lambda-list untyped-lambda-list)
  (let ((optional-position (position '&optional untyped-lambda-list))
        (keyword-position  (position '&key untyped-lambda-list)))
    (cond ((and (null optional-position)
                (null keyword-position))
           (copy-list untyped-lambda-list))
          ((and optional-position (nthcdr optional-position untyped-lambda-list))
           (append (subseq untyped-lambda-list 0 optional-position)
                   '(&optional)
                   (mapcar (lambda (elt)
                             (multiple-value-bind (var default-value-form)
                                 (optima:match elt
                                   ((list name value-form)
                                    (values name value-form))
                                   (variable (values variable nil)))
                               (list var default-value-form (gensym (symbol-name var)))))
                           (subseq untyped-lambda-list (1+ optional-position)))))
          ((and keyword-position (nthcdr keyword-position untyped-lambda-list))
           (append (subseq untyped-lambda-list 0 keyword-position)
                   (list '&rest (gensym "ARGS") '&key)
                   (mapcar (lambda (elt)
                             (multiple-value-bind (var default-value-form)
                                 (optima:match elt
                                   ((list name value-form)
                                    (values name value-form))
                                   (variable (values variable nil)))
                               (list var default-value-form (gensym (symbol-name var)))))
                           (subseq untyped-lambda-list (1+ keyword-position)))))
          (t
           (error "Unexpected")))))

(def-test effective-lambda-list-untyped (:suite effective-lambda-list)

  (is (equal '(a b &optional)
             (polymorphic-function-make-effective-lambda-list '(a b &optional))))
  (is-error (polymorphic-function-make-effective-lambda-list '(a b &optional &rest)))
  (destructuring-bind (first second third fourth)
      (polymorphic-function-make-effective-lambda-list '(a &optional c d))
    (is (eq first 'a))
    (is (eq second '&optional))
    (is (eq 'c (first third)))
    (is (eq 'd (first fourth))))

  (is-error (polymorphic-function-make-effective-lambda-list '(a b &rest args &key)))
  (destructuring-bind (first second third fourth fifth sixth)
      (polymorphic-function-make-effective-lambda-list '(a &key c d))
    (declare (ignore third))
    (is (eq first 'a))
    (is (eq second '&rest))
    (is (eq fourth '&key))
    (is (eq 'c (first fifth)))
    (is (eq 'd (first sixth))))

  (is (equal '(a b &rest c)
             (polymorphic-function-make-effective-lambda-list '(a b &rest c))))
  (is-error (polymorphic-function-make-effective-lambda-list '(a b &rest)))
  (destructuring-bind (first second third)
      (polymorphic-function-make-effective-lambda-list '(a &rest c))
    (is (eq first 'a))
    (is (eq second '&rest))
    (is (eq 'c third))))

(defun normalize-typed-lambda-list (typed-lambda-list)
  (let ((state           'required)
        (normalized-list ())
        (ignorable-list  ()))
    (loop :for (elt . rest) :on typed-lambda-list
          :do (if (member elt lambda-list-keywords)
                  (progn
                    (setq state elt)
                    (when rest (push elt normalized-list)))
                  (push (case state
                          (required
                           (optima:ematch
                               (if (listp elt)
                                   elt
                                   (list elt t))
                             ((list parameter type)
                              (list (if (string= "_" parameter)
                                        (car (push (gensym) ignorable-list))
                                        parameter)
                                    type))))
                          ((&optional &key)
                           (optima:ematch
                               (cond ((not (listp elt))
                                      (list (list elt t) nil))
                                     ((not (listp (first elt)))
                                      (list (list (first elt) t)
                                            (second elt)))
                                     (t elt))
                             ((list* (list parameter type) default-and-supplied-p)
                              (list* (list (if (string= "_" parameter)
                                               (car (push (gensym) ignorable-list))
                                               parameter)
                                           type)
                                     default-and-supplied-p))))
                          (&rest (if (string= "_" elt)
                                     (car (push (gensym) ignorable-list))
                                     elt)))
                        normalized-list)))
    (values (nreverse normalized-list)
            ignorable-list)))

(defun normalize-untyped-lambda-list (untyped-lambda-list)
  (let ((state           'required)
        (normalized-list ()))
    (loop :for (elt . rest) :on untyped-lambda-list
          :do (if (member elt lambda-list-keywords)
                  (progn
                    (setq state elt)
                    (when rest (push elt normalized-list)))
                  (push (case state
                          (required
                           elt)
                          ((&optional &key)
                           (optima:match elt
                             ((list _ _) elt)
                             (variable (list variable nil))))
                          (&rest elt))
                        normalized-list)))
    (nreverse normalized-list)))

(def-test normalize-typed-lambda-list (:suite lambda-list)
  (5am:is-true (equal '((a t))
                      (normalize-typed-lambda-list '(a))))
  (5am:is-true (equal '(&optional ((a t) nil))
                      (normalize-typed-lambda-list '(&optional a))))
  (5am:is-true (equal '(&key ((a t) nil))
                      (normalize-typed-lambda-list '(&key a))))
  (5am:is-true (equal '(&rest a)
                      (normalize-typed-lambda-list '(&rest a)))))

(defun untyped-lambda-list (normalized-typed-lambda-list)
  (let ((typed-lambda-list   normalized-typed-lambda-list)
        (state               'required)
        (untyped-lambda-list ()))
    (dolist (elt typed-lambda-list)
      (if (member elt lambda-list-keywords)
          (progn
            (setq state elt)
            (push elt untyped-lambda-list))
          (push (case state
                  (required (first elt))
                  ((&optional &key) (caar elt))
                  (&rest elt))
                untyped-lambda-list)))
    (nreverse untyped-lambda-list)))

(def-test untyped-lambda-list ()
  (is (equal '(a)   (untyped-lambda-list '((a string)))))
  (is (equal '(a b) (untyped-lambda-list '((a string) (b number)))))
  (is (equal '(&optional c)   (untyped-lambda-list '(&optional ((c string))))))
  (is (equal '(a &optional c) (untyped-lambda-list '((a number) &optional ((c string))))))
  (is (equal '(&key c)   (untyped-lambda-list '(&key ((c string))))))
  (is (equal '(&key c d)   (untyped-lambda-list '(&key ((c string)) ((d number))))))
  (is (equal '(a &key c) (untyped-lambda-list '((a number) &key ((c string))))))
  (is (equal '(a &rest args) (untyped-lambda-list '((a number) &rest args)))))

(defun ensure-default-form-type (default-form type &optional env)
  (let ((default-form-type (nth-form-type default-form env 0 t t)))
    (when (intersection-null-p env default-form-type type)
      (warn "The type of~%  ~S~%was expected to be~%  ~S~%but was derived to be~%  ~S~%which does not intersect with%  ~S"
            default-form type default-form-type type))))

(declaim (ftype (function (list list) polymorph-parameters)
                make-polymorph-parameters-from-lambda-lists))
(defun make-polymorph-parameters-from-lambda-lists (polymorphic-function-lambda-list
                                                    polymorph-lambda-list)
  (declare (optimize debug))
  (assert (let ((lambda-list-type (lambda-list-type polymorphic-function-lambda-list :typed nil)))
            (if (eq 'rest lambda-list-type)
                t
                (eq lambda-list-type
                    (lambda-list-type polymorph-lambda-list :typed t))))
          (polymorphic-function-lambda-list polymorph-lambda-list)
          "Incompatible-lambda-lists")
  (let ((untyped-lambda-list polymorphic-function-lambda-list)
        (typed-lambda-list   polymorph-lambda-list)
        (untyped-state       :required)
        (typed-state         :required)
        (parameters      (make-polymorph-parameters))
        (rest-idx        0)
        (rest-arg        nil)
        (parameter       nil))
    (declare (optimize debug))
    ;; The length of the typed and untyped lambda list need not match.
    ;; But we are guaranteed that typed-lambda-list is at least as long as
    ;; untyped-lambda-list
    (loop :for parameter-specifier :in typed-lambda-list
          ;; :do (print (list parameter-specifier
          ;;                  (car untyped-lambda-list)
          ;;                  parameter-alist))
          :do (setq untyped-state
                    (case (car untyped-lambda-list)
                      (&optional
                       (setq untyped-lambda-list (cdr untyped-lambda-list))
                       '&optional)
                      (&key
                       (setq untyped-lambda-list (cdr untyped-lambda-list))
                       '&key)
                      (&rest
                       (setq untyped-lambda-list (cdr untyped-lambda-list))
                       (setq rest-arg (car untyped-lambda-list))
                       '&rest)
                      (t untyped-state)))

              (setq typed-state
                    (case parameter-specifier
                      (&optional '&optional)
                      (&key '&key)
                      (&rest '&rest)
                      (t typed-state)))


              (unless (member parameter-specifier lambda-list-keywords)

                (ecase untyped-state
                  (:required
                   (destructuring-bind (name type) parameter-specifier
                     (setq parameter
                           (make-polymorph-parameter :local-name name
                                                     ;; TODO: TYPE-PARAMETERS
                                                     :form-in-pf (car untyped-lambda-list)
                                                     :value-type type
                                                     :value-effective-type type))
                     (setq untyped-lambda-list (cdr untyped-lambda-list))))
                  (&optional
                   (destructuring-bind ((name type)
                                        &optional (default nil defaultp)
                                          supplied-p-name)
                       parameter-specifier
                     (when defaultp
                       (ensure-default-form-type default type))
                     (setq parameter
                           (make-polymorph-parameter :local-name name
                                                     :form-in-pf (car untyped-lambda-list)
                                                     :value-type type
                                                     :default-value-form default
                                                     :value-effective-type
                                                     (if defaultp
                                                         `(or null ,type)
                                                         type)
                                                     :supplied-p-name supplied-p-name))
                     (setq untyped-lambda-list (cdr untyped-lambda-list))))
                  (&rest
                   (if (symbolp parameter-specifier)
                       (progn
                         (setq parameter
                               (make-polymorph-parameter :local-name parameter-specifier
                                                         :form-in-pf
                                                         `(nthcdr ,rest-idx ,rest-arg)))
                         (incf rest-idx))
                       (if (listp (car parameter-specifier))
                           ;; LIST for &KEY parameter-specifier
                           (destructuring-bind
                               ((name type)
                                &optional (default nil defaultp)
                                  supplied-p-name)
                               parameter-specifier
                             (when defaultp
                               (ensure-default-form-type default type))
                             (setq parameter
                                   (make-polymorph-parameter :local-name name
                                                             :form-in-pf
                                                             `(ignore-errors
                                                               (getf
                                                                (nthcdr ,rest-idx ,rest-arg)
                                                                ,(intern (symbol-name name)
                                                                         :keyword)))
                                                             :default-value-form default
                                                             :value-type type
                                                             ;; only REQUIRED, KEY or REST
                                                             :value-effective-type
                                                             (if defaultp
                                                                 `(or null ,type)
                                                                 type)
                                                             :supplied-p-name supplied-p-name)))
                           (destructuring-bind (name type) parameter-specifier
                             (setq parameter
                                   (make-polymorph-parameter :local-name name
                                                             :form-in-pf
                                                             `(nth ,rest-idx ,rest-arg)
                                                             :value-type type
                                                             ;; only REQUIRED, KEY or REST
                                                             :value-effective-type type))
                             (incf rest-idx))))
                   (setq untyped-lambda-list (cdr untyped-lambda-list)))
                  (&key
                   (destructuring-bind ((name type)
                                        &optional (default nil defaultp)
                                          supplied-p-name)
                       parameter-specifier
                     (when defaultp
                       (ensure-default-form-type default type))
                     (setq parameter
                           (make-polymorph-parameter :local-name name
                                                     :form-in-pf (car untyped-lambda-list)
                                                     :value-type type
                                                     :default-value-form default
                                                     :value-effective-type
                                                     (if defaultp
                                                         `(or null ,type)
                                                         type)
                                                     :supplied-p-name supplied-p-name))
                     (setq untyped-lambda-list (cdr untyped-lambda-list)))))

                (setf (pp-type-parameters parameter)
                      (type-parameters-from-parametric-type (pp-value-type parameter)))

                (ecase typed-state
                  (:required (push parameter (polymorph-parameters-required parameters)))
                  (&optional (push parameter (polymorph-parameters-optional parameters)))
                  (&key      (push parameter (polymorph-parameters-keyword parameters)))
                  ;; May be we should avoid list for &REST ?
                  (&rest     (push parameter (polymorph-parameters-rest parameters))))))

    (nreversef (polymorph-parameters-required parameters))
    (nreversef (polymorph-parameters-optional parameters))
    (setf (polymorph-parameters-keyword parameters)
          (sort (polymorph-parameters-keyword parameters)
                #'string< :key #'pp-local-name))

    (let* ((min-args (length (polymorph-parameters-required parameters)))
           (max-args (cond ((polymorph-parameters-rest parameters)
                            nil)
                           (t
                            (+ min-args
                               (length (polymorph-parameters-optional parameters))
                               (* 2 (length (polymorph-parameters-keyword parameters))))))))
      (setf (polymorph-parameters-min-args parameters) min-args)
      (setf (polymorph-parameters-max-args parameters) max-args)
      (when (and (member '&rest polymorphic-function-lambda-list)
                 (not (member '&key polymorphic-function-lambda-list)))
        (setq rest-arg (or rest-arg
                           (nth (1+ (position '&rest polymorphic-function-lambda-list))
                                polymorphic-function-lambda-list)))
        (setf (polymorph-parameters-validator-form parameters)
              (let ((num-required (position '&rest polymorphic-function-lambda-list)))
                `(and (<= ,(- min-args num-required)
                          (length ,rest-arg)
                          ,(- (or max-args lambda-parameters-limit)
                              num-required))
                      ,(if (polymorph-parameters-keyword parameters)
                           `(evenp (length (nthcdr ,rest-idx ,rest-arg)))
                           t))))))

    parameters))

(defun map-polymorph-parameters (polymorph-parameters
                                 &key required optional keyword rest default)
  (declare (type (or null function) required optional keyword rest))
  (let ((required-fn (or required default))
        (optional-fn (or optional default))
        (keyword-fn  (or keyword default))
        (rest-fn     (or rest default)))
    (with-slots (required optional keyword rest) polymorph-parameters
      (remove-if #'null
                 (append (when required-fn (mapcar required-fn required))
                         (when optional '(&optional))
                         (when optional-fn (mapcar optional-fn optional))
                         (when rest '(&rest))
                         (when rest-fn (mapcar rest-fn rest))
                         (when keyword '(&key))
                         (when keyword-fn (mapcar keyword-fn keyword)))))))

(defun enhance-run-time-deparameterizer-lambda-body (lambda-body local-name)
  (optima:ematch lambda-body
    ((list* lambda (list parameter) body-decl)
     `(,lambda (,parameter)
        (pflet ((,parameter ,parameter))
          (declare (type-like ,local-name ,parameter))
          ,@body-decl)))
    (name name)))

(defun polymorph-effective-lambda-list (polymorph-parameters)
  "Returns 4 values:
- The first value is the LAMBDA-LIST suitable for constructing polymorph's lambda
- The second value is the TYPE-PARAMETER binding list
- The third value is the TYPE-LIST corresponding to the polymorph
- The fourth value is the EFFECTIVE-TYPE-LIST corresponding to the polymorph"
  (let ((type-parameter-name-deparameterizer-list))
    (values (flet ((populate-type-parameters (pp)
                     (loop :for tp :in (pp-type-parameters pp)
                           :do (with-slots (name
                                            run-time-deparameterizer-lambda-body)
                                   tp
                                 (unless (assoc-value
                                          type-parameter-name-deparameterizer-list
                                          name)
                                   (push `(,name
                                           (,(enhance-run-time-deparameterizer-lambda-body
                                              run-time-deparameterizer-lambda-body
                                              (pp-local-name pp))
                                            ,(pp-local-name pp)))
                                         type-parameter-name-deparameterizer-list))))))
              (append
               (map-polymorph-parameters
                polymorph-parameters
                :required
                (lambda (pp)
                  (populate-type-parameters pp)
                  (pp-local-name pp))
                :optional
                (lambda (pp)
                  (populate-type-parameters pp)
                  (with-slots (local-name default-value-form supplied-p-name)
                      pp
                    (if supplied-p-name
                        (list local-name default-value-form supplied-p-name)
                        (list local-name default-value-form))))
                :rest #'pp-local-name
                :keyword
                (lambda (pp)
                  (populate-type-parameters pp)
                  (with-slots (local-name default-value-form supplied-p-name)
                      pp
                    (if supplied-p-name
                        (list local-name default-value-form supplied-p-name)
                        (list local-name default-value-form)))))))
            type-parameter-name-deparameterizer-list
            (map-polymorph-parameters polymorph-parameters
                                      :required #'pp-value-type
                                      :optional #'pp-value-type
                                      :rest (lambda (arg)
                                              (declare (ignore arg))
                                              nil)
                                      :keyword (lambda (pp)
                                                 (with-slots (local-name value-type) pp
                                                   (list (intern (symbol-name local-name) :keyword)
                                                         value-type))))
            (map-polymorph-parameters polymorph-parameters
                                      :required #'pp-value-effective-type
                                      :optional #'pp-value-effective-type
                                      :rest (lambda (arg)
                                              (declare (ignore arg))
                                              nil)
                                      :keyword (lambda (pp)
                                                 (with-slots (local-name value-effective-type) pp
                                                   (list (intern (symbol-name local-name) :keyword)
                                                         value-effective-type)))))))

(defun lambda-declarations (polymorph-parameters)
  "Returns two values
- The first value is the declaration for the actual polymorph parameters
- The second value is the IGNORABLE declaration for the type parameters "
  (let ((type-parameter-names ())
        (extype-decl-sym (when (find-package :extensible-compound-types)
                           (find-symbol "EXTYPE" :extensible-compound-types))))
    (flet ((type-decl (pp)
             (with-slots (local-name value-type) pp
               (loop :for tp :in (pp-type-parameters pp)
                     :do (pushnew (type-parameter-name tp) type-parameter-names))
               (let ((value-type (deparameterize-type value-type)))
                 (cond ((cl-type-specifier-p value-type)
                        `(type ,value-type ,local-name))
                       (t
                        `(type ,(upgrade-extended-type value-type) ,local-name))))))
           (extype-decl (pp)
             (when extype-decl-sym
               (with-slots (local-name value-type) pp
                 (loop :for tp :in (pp-type-parameters pp)
                       :do (pushnew (type-parameter-name tp) type-parameter-names))
                 (let ((value-type (deparameterize-type value-type)))
                   `(,extype-decl-sym ,(upgrade-extended-type value-type) ,local-name))))))
      (values
       `(declare ,@(set-difference (nconc
                                    (map-polymorph-parameters polymorph-parameters
                                                              :required #'type-decl
                                                              :optional #'type-decl
                                                              :keyword  #'type-decl
                                                              :rest (lambda (pp)
                                                                      (declare (ignore pp))
                                                                      nil))
                                    (map-polymorph-parameters polymorph-parameters
                                                              :required #'extype-decl
                                                              :optional #'extype-decl
                                                              :keyword  #'extype-decl
                                                              :rest (lambda (pp)
                                                                      (declare (ignore pp))
                                                                      nil)))
                                   lambda-list-keywords))
       (when type-parameter-names
         `(declare (ignorable ,@type-parameter-names)))))))



(defun compiler-applicable-p-lambda-body (polymorph-parameters)

  (let ((type-parameters-alist ())
        (may-be-null-forms ()))

    (with-gensyms (form form-type)
      (flet ((app-p-form (param pp)
               (let ((param-supplied-p (etypecase param
                                         (cons (third param))
                                         (symbol nil)))
                     (param (etypecase param
                              (cons (first param))
                              (symbol param))))
                 (with-slots (form-in-pf
                              (type value-type)
                              type-parameters
                              default-value-form)
                     pp
                   (cond ((and (null type-parameters)
                               (type= t type))
                          t)
                         (t
                          (let ((deparameterized-type (deparameterize-type type)))
                            (when type-parameters
                              (loop :for type-parameter :in type-parameters
                                    :do (with-slots
                                              (name
                                               compile-time-deparameterizer-lambda-body)
                                            type-parameter
                                          (push `(,compile-time-deparameterizer-lambda-body
                                                  (cdr ,param))
                                                (assoc-value type-parameters-alist name)))
                                    :finally (return t)))
                            (when (subtypep 'null deparameterized-type)
                              (pushnew `(cdr ,param) may-be-null-forms :test #'equal))
                            `(let ((,form      (car ,param))
                                   (,form-type (cdr ,param)))
                               (cond ((type= t ,form-type)
                                      (signal 'form-type-failure :form ,form))
                                     ((and ',param-supplied-p
                                           (null ,param-supplied-p))
                                      ,(if (null default-value-form)
                                           (typep nil type)
                                           `(signal 'form-type-failure :form ',form-in-pf)))
                                     (t
                                      ,(if param-supplied-p
                                           `(if ,param-supplied-p
                                                (subtypep ,form-type ',deparameterized-type)
                                                t)
                                           `(subtypep ,form-type
                                                      ',deparameterized-type))))))))))))

        (let* ((lambda-list
                 (map-polymorph-parameters polymorph-parameters
                                           :required
                                           (lambda (pp)
                                             (gensym (write-to-string (pp-local-name pp))))
                                           :optional
                                           (lambda (pp)
                                             (list (gensym (write-to-string (pp-local-name pp)))
                                                   nil
                                                   (gensym (concatenate 'string
                                                                        (write-to-string
                                                                         (pp-local-name pp))
                                                                        "-SUPPLIED-P"))))
                                           :keyword
                                           (lambda (pp)
                                             (list (intern (symbol-name (pp-local-name pp))
                                                           :polymorphic-functions)
                                                   nil
                                                   (gensym (concatenate 'string
                                                                        (write-to-string
                                                                         (pp-local-name pp))
                                                                        "-SUPPLIED-P"))))
                                           :rest
                                           (lambda (pp)
                                             (gensym (write-to-string (pp-local-name pp))))))

               (lambda-body-forms
                 (let ((ll lambda-list))
                   (map-polymorph-parameters
                    polymorph-parameters
                    :required
                    (lambda (pp)
                      (let ((form (app-p-form (car ll) pp)))
                        (setq ll (cdr ll))
                        form))
                    :optional
                    (lambda (pp)
                      (loop :while (member (car ll) lambda-list-keywords)
                            :do (setq ll (cdr ll)))
                      (let ((form (app-p-form (car ll) pp)))
                        (setq ll (cdr ll))
                        form))
                    :keyword
                    (lambda (pp)
                      (loop :while (member (car ll) lambda-list-keywords)
                            :do (setq ll (cdr ll)))
                      (let ((form (app-p-form (car ll) pp)))
                        (setq ll (cdr ll))
                        form))
                    :rest
                    (lambda (pp)
                      (declare (ignore pp))
                      nil)))))
          `(cl:lambda ,lambda-list
             (declare (optimize speed)
                      (ignorable ,@(mappend (lambda (elt)
                                              (etypecase elt
                                                (atom (list elt))
                                                (list (list (first elt)
                                                            (third elt)))))
                                            (set-difference lambda-list lambda-list-keywords))))
             (and ,@(set-difference lambda-body-forms lambda-list-keywords)
                  ,@(loop :for (type-param . forms) :in type-parameters-alist
                          :collect
                          (let* ((non-null-form-pos (position-if-not (lambda (form)
                                                                       (member form
                                                                               may-be-null-forms
                                                                               :test #'equal))
                                                                     forms :key #'second))
                                 (non-null-form (when non-null-form-pos
                                                  (nth non-null-form-pos forms))))
                            (if (null non-null-form-pos)
                                'cl:t
                                `(and (nth-value 1 ,non-null-form)
                                      ,@(loop :for pos :from 0
                                              :for form :in forms
                                              :if (/= pos non-null-form-pos)
                                                :collect (if (member (second form)
                                                                     may-be-null-forms
                                                                     :test #'equal)
                                                             `(or (null ,form)
                                                                  (equal ,non-null-form
                                                                         ,form))
                                                             `(equal ,non-null-form
                                                                     ,form))))))))))))))


(defun run-time-applicable-p-form (polymorph-parameters)
  (let ((type-parameter-alist ())
        (may-be-null-forms-in-pf ()))
    (flet ((process (pp)
             (with-slots (form-in-pf value-effective-type) pp
               (when-let (type-parameters (pp-type-parameters pp))
                 (loop :for type-parameter :in type-parameters
                       :do (with-slots (name run-time-deparameterizer-lambda-body)
                               type-parameter
                             (push (cons form-in-pf
                                         `(,run-time-deparameterizer-lambda-body
                                           ,form-in-pf))
                                   (assoc-value type-parameter-alist name)))
                       :finally (return nil)))
               (let ((deparameterized-type (deparameterize-type value-effective-type)))
                 (when (subtypep 'null deparameterized-type)
                   (pushnew form-in-pf may-be-null-forms-in-pf :test #'equal))
                 `(typep ,form-in-pf ',deparameterized-type)))))
      (let ((type-forms
              (map-polymorph-parameters polymorph-parameters
                                        :required #'process
                                        :optional #'process
                                        :keyword #'process
                                        :rest
                                        (lambda (pp)
                                          (declare (ignore pp))
                                          nil))))
        `(and ,(or (polymorph-parameters-validator-form polymorph-parameters)
                   t)
              ,@(set-difference type-forms lambda-list-keywords)
              ,@(loop :for (name . form-specs) :in type-parameter-alist
                      :collect
                      (let* ((non-null-form-pos (position-if-not (lambda (form-in-pf)
                                                                   (member form-in-pf
                                                                           may-be-null-forms-in-pf
                                                                           :test #'equal))
                                                                 form-specs :key #'car))
                             (non-null-form (when non-null-form-pos
                                              (cdr (nth non-null-form-pos form-specs)))))
                        (if (null non-null-form-pos)
                            'cl:t
                            `(and ,@(loop :for pos :from 0
                                          :for (form-in-pf . form) :in form-specs
                                          :if (/= pos non-null-form-pos)
                                            :collect (if (member form-in-pf may-be-null-forms-in-pf
                                                                 :test #'equal)
                                                         `(or (null ,form-in-pf)
                                                              (equal ,non-null-form
                                                                     ,form))
                                                         `(equal ,non-null-form
                                                                 ,form))))))))))))



(defun enhanced-lambda-declarations (polymorph-parameters arg-types &optional return-type)

  (let* ((processed-for-keyword-arguments nil)
         (new-type-parameters nil)
         (extype-decl-sym (when (find-package :extensible-compound-types)
                            (find-symbol "EXTYPE" :extensible-compound-types))))

    (flet ((populate-deparameterizer-alist (pp arg-type)
             (when-let (type-parameters (pp-type-parameters pp))
               (let* ((type-parameter-names (mapcar #'type-parameter-name type-parameters)))
                 (loop :for name :in type-parameter-names
                       :do (unless (member name new-type-parameters)
                             (pushnew name new-type-parameters)
                             (setf (assoc-value *deparameterizer-alist* name)
                                   (funcall
                                    (type-parameter-compile-time-deparameterizer-lambda
                                     (find name type-parameters :key #'type-parameter-name))
                                    arg-type))))))))

      (let ((type-forms
              (map-polymorph-parameters
               polymorph-parameters
               :required
               (lambda (pp)
                 (let ((arg-type  (car arg-types)))
                   (setq arg-types (cdr arg-types))
                   (populate-deparameterizer-alist pp arg-type)
                   `(type ,arg-type ,(pp-local-name pp))))
               :optional
               (lambda (pp)
                 (let ((arg-type (car arg-types)))
                   (setq arg-types (cdr arg-types))
                   (populate-deparameterizer-alist pp arg-type)
                   `(type ,(or arg-type (let ((type (pp-value-type pp)))
                                          (if (cl-type-specifier-p type)
                                              type
                                              (upgrade-extended-type type))))
                          ,(pp-local-name pp))))
               :keyword
               (lambda (pp)
                 (unless processed-for-keyword-arguments
                   (setq processed-for-keyword-arguments t)
                   (setq arg-types
                         (loop :for i :from 0
                               :for arg-type :in arg-types
                               :if (evenp i)
                                 :collect
                                 (progn
                                   (assert (and (member (first arg-type)
                                                        '(member eql))
                                                (= 2 (length arg-type)))
                                           ()
                                           ;; FIXME: Something better than generic error?
                                           "Unable to derive keyword from arg-type ~S"
                                           arg-type)
                                   (second arg-type))
                               :else
                                 :collect arg-type)))
                 (let ((arg-type (getf arg-types
                                       (intern (symbol-name (pp-local-name pp)) :keyword))))
                   (populate-deparameterizer-alist pp arg-type)
                   `(type ,(or arg-type (let ((type (pp-value-type pp)))
                                          (if (cl-type-specifier-p type)
                                              type
                                              (upgrade-extended-type type))))
                          ,(pp-local-name pp))))
               :rest
               (lambda (pp)
                 (declare (ignore pp))
                 nil))))

        (values `(declare ,@(loop :for type-form :in type-forms
                                  :if (not (member type-form lambda-list-keywords))
                                    ;; LOOP instead of SET-DIFFERENCE to preserver order
                                    :collect type-form)
                          ,@(when extype-decl-sym
                              (loop :for type-form :in type-forms
                                    :if (not (member type-form lambda-list-keywords))
                                      ;; LOOP instead of SET-DIFFERENCE to preserver order
                                      :collect `(,extype-decl-sym ,@(rest type-form)))))
                `(declare (ignorable ,@new-type-parameters))
                `(declare ,@(loop :for (type-parameter . value)
                                    :in *deparameterizer-alist*
                                  :if (member type-parameter new-type-parameters)
                                    :collect `(type (eql ,value) ,type-parameter))
                          ,@(when extype-decl-sym
                              (loop :for (type-parameter . value)
                                      :in *deparameterizer-alist*
                                    :if (member type-parameter new-type-parameters)
                                      :collect `(,extype-decl-sym (eql ,value)
                                                                  ,type-parameter))))
                (translate-body return-type *deparameterizer-alist*))))))

(defun accepts-argument-of-type-p (polymorph-parameters type)
  (flet ((%subtypep (pp) (subtypep type (pp-value-type pp))))
    (some (lambda (arg)
            (eq t arg))
          (map-polymorph-parameters polymorph-parameters
                                    :required #'%subtypep
                                    :optional #'%subtypep
                                    :keyword  #'%subtypep))))
