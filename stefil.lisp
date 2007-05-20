;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :stefil)

#.(file-header)

;; Warning: setf-ing these variables in not a smart idea because other systems may rely on their default value.
;; It's smarter to rebind them in an :around method from your .asd or shadow stefil:deftest with your own that sets
;; their keyword counterparts.
(defvar *suite*)
(defvar *root-suite*)
(defvar *print-test-run-progress* #t)
(defvar *compile-tests-before-run* #f)
(defvar *compile-tests-with-debug* #f)
(defvar *test-progress-print-right-margin* 100)
(defvar *debug-on-unexpected-error* #t)
(defvar *debug-on-assertion-failure* #t)
(defvar *test-result-history* '())
(defvar *last-test-result* nil)

(defparameter *tests* (make-hash-table :test 'eql)) ; this is not thread-safe, but...

(defmacro without-debugging (&body body)
  `(bind ((*debug-on-unexpected-error* #f)
         (*debug-on-assertion-failure* #f))
    ,@body))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; conditions

(defcondition* test-related-condition ()
  ((test nil)))

(defcondition* test-style-warning (style-warning test-related-condition simple-warning)
  ())

(defcondition* assertion-failed (test-related-condition error)
  ((failure-description))
  (:report (lambda (c stream)
             (format stream "Test assertion failed:~%~%")
             (describe (failure-description-of c) stream))))

(defcondition* error-in-teardown (error)
  ((condition)
   (fixture))
  (:report (lambda (c stream)
             (format stream "Error while running teardown of fixture ~A:~%~%~A" (fixture-of c) (condition-of c)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; some classes

(defclass* testable ()
  ((name :type symbol)
   (parent nil :initarg nil :type (or null testable))
   (children (make-hash-table) :documentation "A mapping from testable names to testables")
   (auto-call #t :type boolean :documentation "Controls whether to automatically call this test when its parent suite is invoked. Enabled by default.")))

(defprint-object (self testable :identity #f :type #f)
  (format t "test ~S" (name-of self))
  (bind ((children (count-tests self)))
    (unless (zerop children)
      (format t " :tests ~S" children))))

(defmethod shared-initialize :after ((self testable) slot-names
                                     &key (in (or (parent-of self)
                                                  (and (boundp '*suite*)
                                                       *suite*)))
                                     &allow-other-keys)
  (assert (name-of self))
  (setf (find-test (name-of self)) self)
  ;; make sure the specialized writer below is triggered
  (setf (parent-of self) in))

(defmethod (setf parent-of) :around (new-parent (self testable))
  (assert (typep new-parent '(or null testable)))
  (when (and new-parent
             (symbol-package (name-of self)) ; leave alone tests named by uninterned symbols
             (not (eq new-parent *root-suite*))
             (not (eq (symbol-package (name-of new-parent))
                      (symbol-package (name-of self)))))
    (warn 'test-style-warning :test self
          :format-control "Adding test under parent ~S which is in a different package (parent: ~A, child: ~A). Maybe a missing (in-root-suite)?"
          :format-arguments (list new-parent (symbol-package (name-of new-parent)) (symbol-package (name-of self)))))
  (bind ((old-parent (parent-of self)))
    (when old-parent
      (remhash (name-of self) (children-of old-parent)))
    (prog1
        (call-next-method)
      (when new-parent
        (setf (gethash (name-of self) (children-of new-parent)) self)))))

(defgeneric count-tests (testable)
  (:method ((self testable))
           (+ (hash-table-count (children-of self))
              (iter (for (nil child) :in-hashtable (children-of self))
                    (summing (count-tests child))))))

(defclass* test (testable)
  ((package nil)
   (lambda-list nil)
   (compile-before-run #t :type boolean)
   (declarations nil)
   (documentation nil)
   (body nil)))

(defun make-test (name &rest args &key &allow-other-keys)
  (apply #'make-instance 'test :name name args))

(defun make-suite (name &rest args &key &allow-other-keys)
  (apply #'make-instance 'test :name name args))


(defclass* failure-description ()
  ((test-context-backtrace)
   (progress-char #\X :allocation :class)))

(defclass* failed-assertion (failure-description)
  ((form)
   (format-control)
   (format-arguments)))

(defmethod describe-object ((self failed-assertion) stream)
  (let ((*print-circle* nil))
    (apply #'format stream (format-control-of self) (format-arguments-of self))))

(defprint-object (self failed-assertion :identity #f :type #f)
  (format t "failure ~S backtrace: ~{~A~^,~}"
          (form-of self)
          (mapcar (compose #'name-of #'test-of)
                  (test-context-backtrace-of self))))

(defclass* missing-condition (failure-description)
  ((form)
   (condition)))

(defmethod describe-object ((self missing-condition) stream)
  (let ((*print-circle* nil))
    (format stream "~S failed to signal condition ~S" (form-of self) (condition-of self))))

(defclass* unexpected-error (failure-description)
  ((condition)
   (progress-char #\E :allocation :class)))

(defprint-object (self unexpected-error :identity #f :type #f)
  (format t "error ~{~A~^,~}: ~S"
          (mapcar (compose #'name-of #'test-of)
                  (reverse (test-context-backtrace-of self)))
          (condition-of self)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; test repository

(defun find-test (name &key (otherwise :error))
  (bind (((values test found-p) (if (typep name 'testable)
                                    (values name t)
                                    (gethash name *tests*))))
    (when (and (not found-p)
               otherwise)
      (etypecase otherwise
        (symbol (ecase otherwise
                  (:error (error "Testable called ~A was not found" name))))
        (function (funcall otherwise))
        (t (setf test otherwise))))
    (values test found-p)))

(defun (setf find-test) (new-value key)
  (if new-value
      (progn
        (when (gethash key *tests*)
          (warn 'test-style-warning
                :format-control "redefining test ~A"
                :format-arguments (list (let ((*package* #.(find-package "KEYWORD")))
                                          (format nil "~S" key)))))
        (setf (gethash key *tests*) new-value))
      (rem-test key)))

(defun rem-test (name &rest args)
  (bind ((test (apply #'find-test name args))
         (parent (when test
                   (parent-of test))))
    (when test
      (assert (or (not (eq *suite* test))
                  (parent-of test))
              () "You can not remove a test which is the current suite and has no parent")
      (remhash name *tests*)
      (setf (parent-of test) nil)
      (fmakunbound (name-of test))
      (iter (for (nil subtest) :in-hashtable (children-of test))
            (rem-test (name-of subtest)))
      (when (eq *suite* test)
        (setf *suite* parent)))
    test))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; the real thing

(define-dynamic-context* global-context
  ((failure-descriptions (make-array 8 :adjustable #t :fill-pointer 0))
   (assertion-count 0)
   (progress-char-count 0)
   (print-test-run-progress-p *print-test-run-progress* :type boolean)
   (debug-on-unexpected-error-p *debug-on-unexpected-error* :type boolean)
   (debug-on-assertion-failure-p *debug-on-assertion-failure* :type boolean)
   (toplevel-context nil)
   (current-test nil)
   (run-tests (make-hash-table) :documentation "test -> context mapping")
   (run-fixtures (make-hash-table))
   (test-lambdas (make-hash-table) :documentation "test -> compiled test lambda mapping for this test run")))

(defprint-object (self global-context :identity #f :type #f)
  (format t "test-run ~A tests, ~A assertions, ~A failures in ~A sec"
          (hash-table-count (run-tests-of self)) (assertion-count-of self) (length (failure-descriptions-of self))
          (bind ((toplevel-context (toplevel-context-of self))
                 (real-time-spent-in-seconds
                  (when toplevel-context
                    (real-time-spent-in-seconds toplevel-context))))
            (if (and toplevel-context
                     real-time-spent-in-seconds)
                real-time-spent-in-seconds
                "?"))))

(defmacro without-test-progress-printing (&body body)
  (with-unique-names (old-state)
    `(let ((,old-state (print-test-run-progress-p *global-context*)))
      (unwind-protect
           (progn
             (setf (print-test-run-progress-p *global-context*) #f)
             ,@body)
        (setf (print-test-run-progress-p *global-context*) ,old-state)))))

(defmacro with-toplevel-restarts (&body body)
  `(block restart-wrapper
     (restart-bind
         ((continue-without-debugging
           (lambda ()
             (setf (debug-on-unexpected-error-p global-context) #f)
             (setf (debug-on-assertion-failure-p global-context) #f)
             (continue))
           :report-function (lambda (stream)
                              (format stream "~@<Turn off debugging for this test session and invoke the first CONTINUE restart~@:>")))
          (abort-testing
           (lambda ()
             (return-from restart-wrapper))
           :report-function (lambda (stream)
                              (format stream "~@<Abort the entire test session~@:>"))))
       (bind ((swank::*sldb-quit-restart* 'abort-testing))
         ,@body))))

(defun test-was-run-p (test)
  (declare (type testable test))
  (in-global-context context
    (and (gethash test (run-tests-of context))
         (not (eq (current-test-of context) test)))))

(defun register-test-being-run (test)
  (declare (type testable test))
  (in-global-context context
    (setf (gethash test (run-tests-of context)) (current-context))
    (setf (current-test-of context) test)))

(defgeneric get-test-lambda (test global-context)
  (:method ((test test) (context global-context))
           (bind (((values test-lambda found-p) (gethash test (test-lambdas-of context))))
             (unless found-p
               (setf test-lambda (bind ((*package* (package-of test))
                                        (*readtable* (copy-readtable)))
                                   (compile nil `(lambda ,(lambda-list-of test)
                                                  ,@(body-of test)))))
               (setf (gethash test (test-lambdas-of context)) test-lambda))
             test-lambda)))

(define-dynamic-context* context
  ((test)
   (internal-realtime-spent-with-test nil)
   (test-arguments)
   (number-of-added-failure-descriptions 0))
  :chain-parents #t)

(defprint-object (self context :identity #f :type #f)
  (format t "test-run ~@<(~S~{~^ ~S~})~@:>"
          (name-of (test-of self))
          (bind ((result (lambda-list-to-funcall-list (lambda-list-of (test-of self)))))
            (mapcar (lambda (arg-cell)
                      (setf result (substitute (cdr arg-cell) (car arg-cell) result :test #'eq)))
                    (test-arguments-of self))
            result)))

(defgeneric real-time-spent-in-seconds (context)
  (:method ((self context))
           (awhen (internal-realtime-spent-with-test-of self)
             (coerce (/ it
                        internal-time-units-per-second)
                     'float))))

(defmacro run-failed-tests (&optional (test-result-place '*last-test-result*))
  (with-unique-names (global-context)
    `(progn
      (with-new-global-context ()
        (in-global-context ,global-context
          (if (> (length (failure-descriptions-of ,test-result-place)) 0)
              (progn
                (%run-failed-tests ,test-result-place)
                (push ,global-context *test-result-history*)
                (setf *last-test-result* ,global-context)
                (setf ,test-result-place ,global-context))
              (progn
                (warn "There are no failed tests in ~S" ',test-result-place)
                (values))))))))

(defun %run-failed-tests (global-context-to-be-processed)
  (warn "Re-running failed tests without considering their dynamic environment, which may affect their behaviour!")
  (in-global-context global-context
    (with-toplevel-restarts
      (iter (for failure :in-sequence (failure-descriptions-of global-context-to-be-processed))
            (for context = (elt (test-context-backtrace-of failure) 0))
            (apply (name-of (test-of context)) (mapcar #'cdr (test-arguments-of context))))
      (when (print-test-run-progress-p global-context)
        (terpri *debug-io*)))))

(defun run-test-body-in-handlers (test function)
  (declare (type test test)
           (type function function))
  (in-global-context global-context
    (in-context context
      (register-test-being-run test)
      (labels ((prune-failure-descriptions ()
                 ;; drop failures recorded by the previous run of this test
                 (loop repeat (number-of-added-failure-descriptions-of context)
                   do (vector-pop (failure-descriptions-of global-context)))
                 (setf (number-of-added-failure-descriptions-of context) 0))
               (run-test-body ()
                 (handler-bind
                     ((assertion-failed (lambda (c)
                                          (declare (ignore c))
                                          (unless (debug-on-assertion-failure-p global-context)
                                            (continue))))
                      (error (lambda (c)
                               (unless (typep c 'assertion-failed)
                                 (record-failure* 'unexpected-error
                                                  :description-initargs (list :condition c)
                                                  :signal-assertion-failed #f)
                                 (when (debug-on-unexpected-error-p global-context)
                                   (invoke-debugger c))
                                 (return-from run-test-body)))))
                   (restart-case
                       (bind ((*package* (package-of test))
                              (*readtable* (copy-readtable))
                              (start-time (get-internal-run-time)))
                         (multiple-value-prog1
                             (funcall function)
                           (setf (internal-realtime-spent-with-test-of context)
                                 (- (get-internal-run-time) start-time))))
                     (continue ()
                       :report (lambda (stream)
                                 (format stream "~@<Skip the rest of the test ~S and continue by returning (values)~@:>" (name-of test)))
                       (values))
                     (retest ()
                       :report (lambda (stream)
                                 (format stream "~@<Rerun the test ~S~@:>" (name-of test)))
                       ;; TODO: this will only prune the failures that were recorded in the current context.
                       ;; in case of nesting it will leave alone the failures recorded in deeper levels.
                       (prune-failure-descriptions)
                       (return-from run-test-body (run-test-body)))))))
        (run-test-body)))))

(defun run-test-body (test function arguments toplevel-p)
  (declare (type test test))
  (in-global-context global-context
    (bind ((result-values '()))
      (flet ((body ()
               (with-new-context (:test test :test-arguments arguments)
                 (when toplevel-p
                   (setf (toplevel-context-of global-context) (current-context)))
                 (setf result-values (multiple-value-list (run-test-body-in-handlers test function))))))
        (if toplevel-p
            (with-toplevel-restarts
              (body))
            (body))
        (if toplevel-p
            (progn
              (when (print-test-run-progress-p global-context)
                (terpri *debug-io*))
              (if result-values
                  (values-list (append result-values (list global-context)))
                  global-context))
            (values-list result-values))))))

(defmacro deftest (&whole whole name args &body body)
  (bind (((values remaining-forms declarations documentation) (parse-body body :documentation #t :whole whole))
         ((name &rest test-args &key (compile-before-run *compile-tests-before-run*) in &allow-other-keys) (ensure-list name))
         (in-p (get-properties test-args '(:in))))
    (remf-keywords test-args :in)
    (unless (or (not (symbol-package name))
                (eq (symbol-package name) *package*))
      (warn 'test-style-warning :test name
            :format-control "Defining test on symbol ~S whose home package is not *package* which is ~A"
            :format-arguments (list name *package*)))
    (with-unique-names (test test-lambda global-context toplevel-p body)
      `(progn
        (eval-when (:load-toplevel :execute)
          (make-test ',name
           :package ,*package*
           :lambda-list ',args
           :declarations ',declarations
           :documentation ',documentation
           :body ',remaining-forms
           ,@(when in-p
                   (if in
                       `(:in (find-test ',in))
                       '(:in nil)))
           ,@test-args))
        (defun ,name ,args
          ,@(when documentation (list documentation))
          ,@declarations
          ,@(when *compile-tests-with-debug*
                  `((declare (optimize (debug 3)))))
          (bind ((,test (find-test ',name))
                 (,toplevel-p (not (has-global-context)))
                 (,global-context (unless ,toplevel-p
                                    (current-global-context))))
            ;; for convenience we define a function in a LABELS with the test name, so the debugger shows it in the backtrace
            (labels (,@(unless compile-before-run
                               `((,name ()
                                  ,@remaining-forms)))
                       (,body ()
                         ,(if compile-before-run
                              `(bind ((,test-lambda (get-test-lambda ,test ,global-context)))
                                (run-test-body ,test
                                 (lambda ()
                                   ,(lambda-list-to-funcall-expression test-lambda args))
                                 ,(lambda-list-to-value-list-expression args)
                                 ,toplevel-p))
                              `(run-test-body ,test
                                #',name
                                ,(lambda-list-to-value-list-expression args)
                                ,toplevel-p))))
              (declare (dynamic-extent ,@(unless compile-before-run `(#',name))
                                       #',body))
              (if ,toplevel-p
                  (with-new-global-context ()
                    (setf ,global-context (current-global-context))
                    (push ,global-context *test-result-history*)
                    (setf *last-test-result* ,global-context)
                    (,body))
                  (,body)))))))))


(defmacro defixture (name &body body)
  "Fixtures are defun's that only execute the :setup part of their body once per test session if there is any at the time of calling."
  (with-unique-names (global-context nesting-count phase)
    (bind (setup-body
           teardown-body)
      (iter (for entry :in body)
            (if (and (consp body)
                     (member (first entry) '(:setup :teardown)))
                (ecase (first entry)
                  (:setup
                   (assert (not setup-body) () "Multiple :setup's for fixture ~S" name)
                   (setf setup-body (rest entry)))
                  (:teardown
                   (assert (not teardown-body) () "Multiple :teardown's for fixture ~S" name)
                   (setf teardown-body (rest entry))))
                (progn
                  (assert (and (not setup-body)
                               (not teardown-body))
                          () "Error parsing body of fixture ~A" name)
                  (setf setup-body body)
                  (leave))))
      `(defun ,name (&optional (,phase :setup))
        (declare (optimize (debug 3)))
        (bind ((,global-context (and (has-global-context)
                                     (current-global-context)))
               (,nesting-count (or (and ,global-context
                                        (gethash ',name (run-fixtures-of ,global-context)))
                                   0)))
          (assert (>= ,nesting-count 0))
          (ecase ,phase
            (:setup
             (incf ,nesting-count)
             (prog1
                 (if (and ,global-context
                          (> ,nesting-count 1))
                     #f
                     (progn
                       ,@setup-body
                       #t))
               (when ,global-context
                 (setf (gethash ',name (run-fixtures-of ,global-context)) ,nesting-count))))
            (:teardown
             (decf ,nesting-count)
             (prog1
                 (if (and ,global-context
                          (> ,nesting-count 0))
                     #f
                     (progn
                       (setf ,nesting-count 0)
                       ,@teardown-body
                       #t))
               (when ,global-context
                 (setf (gethash ',name (run-fixtures-of ,global-context))
                       ,nesting-count))))))))))

(defmacro with-fixture (name &body body)
  (with-unique-names (whole-fixture-body)
    `(flet ((,whole-fixture-body ()
             (,name :setup)
             (unwind-protect (progn ,@body)
               (block teardown-block
                 (handler-bind
                     ((serious-condition
                       (lambda (c)
                         (with-simple-restart
                             (continue ,(let ((*package* (find-package :common-lisp)))
                                          (format nil "Skip teardown of ~S and continue" name)))
                           (error 'error-in-teardown :condition c :fixture ',name))
                         (return-from teardown-block))))
                   (,name :teardown))))))
      (declare (dynamic-extent ,whole-fixture-body))
      (if (has-global-context)
          (,whole-fixture-body)
          (with-new-global-context ()
            (,whole-fixture-body))))))

(defmacro with-fixtures (fixtures &body body)
  (if fixtures
      `(with-fixture ,(first fixtures)
        (with-fixtures ,(rest fixtures)
          ,@body))
      `(progn ,@body)))

(defun record-failure (description-type &rest args)
  (record-failure* description-type :description-initargs args))

(defun record-failure* (type &key (signal-assertion-failed #t) description-initargs)
  (bind ((description (apply #'make-instance type
                             :test-context-backtrace (when (has-context)
                                                       (iter (for context :first (current-context) :then (parent-context-of context))
                                                             (while context)
                                                             (collect context)))
                             description-initargs)))
    (if (and (has-global-context)
             (has-context))
        (in-global-context global-context
          (in-context context
            (vector-push-extend description (failure-descriptions-of global-context))
            (incf (number-of-added-failure-descriptions-of context))
            (write-progress-char (progress-char-of description))
            (when signal-assertion-failed
              (restart-case (error 'assertion-failed
                              :test (test-of context)
                              :failure-description description)
                (continue ()
                  :report (lambda (stream)
                            (format stream "~@<Roger, go on testing...~@:>")))))))
        (progn
          (describe description *debug-io*)
          (when *debug-on-assertion-failure* ; we have no global-context
            (restart-case (error 'assertion-failed
                                 :failure-description description)
              (continue ()
                :report (lambda (stream)
                          (format stream "~@<Ignore the failure and continue~@:>")))))))))

(defun extract-assert-expression-and-message (input-form)
  (bind ((negatedp #f)
         (predicate)
         (arguments '()))
    (labels ((process (form)
               (if (consp form)
                   (case (first form)
                     ((not)
                      (assert (= (length form) 2))
                      (setf negatedp (not negatedp))
                      (process (second form)))
                     (t (setf predicate (first form))
                        (setf arguments (rest form))))
                   (setf predicate form))))
      (process input-form)
      (cond ((ignore-errors
               (macro-function predicate))
             (values '() input-form "Macro expression ~A evaluated to false." (list `(quote ,input-form))))
            ((ignore-errors
               (fdefinition predicate))
             (cond ((= (length arguments) 0)
                    (values '()
                            input-form
                            "Expression ~A evaluated to false."
                            (list `(quote ,input-form))))
                   ((= (length arguments) 2)
                    (with-unique-names (x y)
                      (values `((,x ,(first arguments))
                                (,y ,(second arguments)))
                              (if negatedp
                                  `(not (,predicate ,x ,y))
                                  `(,predicate ,x ,y))
                              "Binary predicate ~A failed.~%~
                               x: ~S => ~S~%~
                               y: ~S => ~S"
                              (list (if negatedp
                                        `(quote (not (,predicate x y)))
                                        `(quote (,predicate x y)))
                                    `(quote ,(first arguments)) x
                                    `(quote ,(second arguments)) y))))
                   (t (bind ((arg-values (mapcar (lambda (el) (declare (ignore el)) (gensym)) arguments))
                             (bindings (iter (for arg :in arguments)
                                             (for arg-value :in arg-values)
                                             (collect `(,arg-value ,arg))))
                             (expression (if negatedp
                                             `(not (,predicate ,@arg-values))
                                             `(,predicate ,@arg-values)))
                             ((values message message-args) (iter (with message = "Expression ~A evaluated to ~A")
                                                                  (for arg :in arguments)
                                                                  (for idx :upfrom 0)
                                                                  (for arg-value :in arg-values)
                                                                  (setf message (concatenate 'string message "~%~D: ~A => ~S"))
                                                                  (appending `(,idx (quote ,arg) ,arg-value) :into message-args)
                                                                  (finally (return (values message message-args))))))
                        (values bindings
                                expression
                                message
                                (nconc (list `(quote (,predicate ,@arguments)) (if negatedp "true" "false")) message-args))))))
            (t
             (values '() input-form "Expression ~A evaluated to false." (list `(quote ,input-form))))))))

(defun write-progress-char (char)
  (bind ((context (when (has-global-context)
                    (current-global-context))))
    (when (and context
               (print-test-run-progress-p context))
      (when (and (not (zerop (progress-char-count-of context)))
                 (zerop (mod (progress-char-count-of context)
                             *test-progress-print-right-margin*)))
        (terpri *debug-io*))
      (incf (progress-char-count-of context)))
    (when (or (and context
                   (print-test-run-progress-p context))
              (and (not context)
                   *print-test-run-progress*))
      (write-char char *debug-io*))))

(defun register-assertion-was-successful ()
  (write-progress-char #\.))

(defun register-assertion ()
  (when (has-global-context)
    (in-global-context context
      (incf (assertion-count-of context)))))

(defmacro is (&whole whole form &optional (message nil message-p) &rest message-args)
  (bind (((values bindings expression message message-args)
          (if message-p
              (values nil form message message-args)
              (extract-assert-expression-and-message form))))
    (with-unique-names (result)
      `(progn
        (register-assertion)
        (bind ,bindings
          (bind ((,result (multiple-value-list ,expression)))
            (if (first ,result)
                (register-assertion-was-successful)
                (record-failure 'failed-assertion :form ',whole
                                :format-control ,message :format-arguments (list ,@message-args)))
            (values-list ,result)))))))

(defmacro signals (what &body body)
  (bind ((condition-type what))
    `(progn
      (register-assertion)
      (block test-block
        (handler-bind ((,condition-type (lambda (c)
                                          (declare (ignore c))
                                          (return-from test-block (values)))))
          ,@body
          (register-assertion-was-successful))
        (record-failure 'missing-condition
                        :form (list* 'progn ',body)
                        :condition ',condition-type))
      (values))))

(defmacro finishes (&body body)
  `(progn
    (register-assertion)
    (multiple-value-prog1
        (progn
          ,@body)
      (register-assertion-was-successful))))

(defmacro runs-without-failure? (&body body)
  (with-unique-names (context old-failure-count)
    `(in-global-context ,context
      (bind ((,old-failure-count (length (failure-descriptions-of ,context))))
        ,@body
        (= ,old-failure-count (length (failure-descriptions-of ,context)))))))



;;;;;;;;;;;;;;;;;;;;;;;;
;;; some utils

(defmacro with-lambda-parsing ((lambda-form &key finally) &body body)
  (with-unique-names (cell)
    `(iter
      (with -in-keywords- = #f)
      (with -in-optionals- = #f)
      (with -rest-variable-name- = nil)
      (for ,cell :first ,lambda-form :then (cdr ,cell))
      (while ,cell)
      (for -variable-name- = (if (or -in-optionals-
                                     -in-keywords-)
                                 (first (ensure-list (car ,cell)))
                                 (car ,cell)))
      (for -default-value- = (if (or -in-optionals-
                                     -in-keywords-)
                                 (second (ensure-list (car ,cell)))
                                 (car ,cell)))
      (case -variable-name-
        (&optional (setf -in-optionals- #t))
        (&key (setf -in-keywords- #t)
              (setf -in-optionals- #f))
        (&allow-other-keys)
        (&rest (setf -rest-variable-name- (car (cdr ,cell)))
               (setf ,cell (cdr ,cell)))
        (t ,@body))
      (finally ,@finally))))

(defun lambda-list-to-funcall-list (args)
  (with-lambda-parsing (args :finally ((return (values result -rest-variable-name-))))
    (if -in-keywords-
        (progn
          (collect (intern (symbol-name (first (ensure-list -variable-name-)))
                           #.(find-package "KEYWORD")) :into result)
          (collect -variable-name- :into result))
        (collect -variable-name- :into result))))

(defun lambda-list-to-funcall-expression (function args)
  (bind (((values arg-list rest-variable) (lambda-list-to-funcall-list args)))
    (if rest-variable
        `(apply ,function ,@arg-list ,rest-variable)
        `(funcall ,function ,@arg-list))))

(defun lambda-list-to-value-list-expression (args)
  `(list ,@(with-lambda-parsing (args)
             (collect `(cons ',-variable-name- ,-variable-name-)))))

(defun lambda-list-to-variable-list (args &key (include-defaults #f) (include-&rest #f))
  (with-lambda-parsing (args :finally ((return (if (and include-&rest
                                                        -rest-variable-name-)
                                                   (cons -rest-variable-name- result)
                                                   result))))
    (collect (if include-defaults
                 (list -variable-name- -default-value-)
                 -variable-name-)
      :into result)))

(defun funcall-test-with-feedback-message (test-function &rest args)
  "Run the given test non-interactively and print the results to *standard-output*.
This function is ideal for ASDF:TEST-OP's."
  (aprog1
      (without-debugging (apply test-function args))
    (let ((*package* (find-package :common-lisp)))
      (format *standard-output*
"The result of ~S is:

  ~A

For more details run it from the REPL and use the customized Slime inspector
to inspect the results (ASDF eats up the return values). Some inspector
features may be available only on the Slime branch at
darcs get --partial http://common-lisp.net/project/cl-wdim/darcs/slime
but the official Slime should also work fine."
              test-function it))))
