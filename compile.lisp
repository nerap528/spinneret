;;; Functions used only at compile time.

(in-package #:spinneret)

(defun parse-html (form env)
  (labels ((rec (form)
             (cond ((atom form) form)
                   ((dotted-list? form) form)
                   ((constantp form env) form)
                   ((eql (car form) 'with-tag) form)
                   ((keywordp (car form))
                    (let ((form (pseudotag-expand (car form) (cdr form))))
                      (if (keywordp (car form))
                          (multiple-value-bind (name attrs body)
                              (tag-parts form)
                            (if (valid? name)
                                `(with-tag (,name ,@attrs)
                                   ,@(mapcar #'rec body))
                                (cons (car form)
                                      (mapcar #'rec (cdr form)))))
                          form)))
                   ((stringp (car form))
                    (destructuring-bind (control-string . args)
                        form
                      (let ((cs (parse-as-markdown control-string)))
                        `(format-text
                          ,@(if (and args (every (lambda (arg) (constantp arg env)) args))
                                (list (apply #'format nil cs
                                             (mapcar #'escape-to-string args)))
                                `((formatter ,cs)
                                  ,@(loop for arg in args
                                          ;; Escape literal strings at
                                          ;; compile time.
                                          if (typep arg 'string env)
                                            collect (escape-to-string arg)
                                          else collect `(xss-escape ,arg))))))))
                   (t (cons (rec (car form))
                            (mapcar #'rec (cdr form)))))))
    (rec form)))

(defun dotted-list? (list)
  (declare (cons list))
  (not (null (cdr (last list)))))

(defun tag-parts (form)
  "Divide a form into an element, attributes, and a body. Provided
the form qualifies as a tag, the element is the car, the attributes
are all the following key-value pairs, and the body is what remains."
  (when (keywordp (car form))
    (let ((tag (car form))
          (body (cdr form))
          attrs classes)
      ;; Expand inline classes and ids.
      (let ((parts (ppcre:split "([.#])" (string-downcase tag) :with-registers-p t)))
        (setf tag (make-keyword (string-upcase (first parts))))
        (labels ((rec (parts)
                   (optima:match parts
                     ((list))
                     ((list* "." class rest)
                      (setf body (list* :class class body))
                      (rec rest))
                     ((list* "#" id rest)
                      (setf body (list* :id id body))
                      (rec rest)))))
          (rec (rest parts))))
      (loop (if (keywordp (car body))
                (if (eql (car body) :class)
                    (progn
                      (push (nth 1 body) classes)
                      (setf body (cddr body)))
                    (setf attrs (nconc attrs
                                       ;; Rather than subseq, in case of
                                       ;; an empty attribute.
                                       (list (nth 0 body)
                                             (nth 1 body)))
                          body (cddr body)))
                (return
                  (values
                   tag
                   (nconc
                    (when classes
                      `(:class
                        ,(if (every #'stringp classes)
                             (apply #'class-union (nreverse classes))
                             `(class-union ,@(nreverse classes)))))
                    attrs)
                   body)))))))

(defun class-union (&rest classes)
  (let ((classes (remove-duplicates (remove nil classes)
                                    :test #'equal)))
    (when classes
      (with-output-to-string (s)
        (write-string (car classes) s)
        (when (cdr classes)
          (dolist (c (cdr classes))
            (write-char #\Space s)
            (write-string c s)))))))

(defmacro with-tag ((name &rest attributes) &body body)
  (let ((empty? (not body))
        (pre? (not (null (preformatted? name))))
        (tag-fn (or (tag-fn name) (error "No such tag: ~a" name))))
    (with-gensyms (thunk)
      `(prog1 nil
         (flet ((,thunk ()
                  ,@(loop for expr in body
                          collect `(catch-output ,expr))))
           (declare (dynamic-extent (function ,thunk)))
           (,tag-fn (list ,@(escape-attrs name attributes))
                    #',thunk
                    ,pre?
                    ,empty?))))))

(defun escape-attrs (tag attrs)
  (let ((attrs
          (loop for (attr val . rest) on attrs by #'cddr
                if (eql attr :dataset)
                  append (escape-attrs
                          tag
                          (loop for (attr val . rest) on val by #'cddr
                                collect (make-keyword (format nil "~:@(data-~A~)" attr))
                                collect val))
                else if (eql attr :attrs)
                       collect attr and collect val
                else if (or (stringp val)
                            (numberp val)
                            (characterp val))
                       collect attr and collect (escape-value val)
                else
                  collect attr and collect `(escape-value ,val))))
    (loop for (attr val . rest) on attrs by #'cddr
          unless (valid-attribute? tag attr )
            do (warn "~A is not a valid attribute for <~A>"
                     attr tag))
    attrs))

(defun parse-as-markdown (string)
  "Expand STRING as markdown only if it contains markdown."
  (declare (string string))
  (let ((expansion
          (with-output-to-string (s)
            (let (markdown:*parse-active-functions*
                  markdown:*render-active-functions*)
              (markdown:markdown string
                                 :stream s
                                 :format :html)))))
    (if (search string expansion)
        string
        (if (find #\Newline string)
            expansion
            (trim-ends "<p>" expansion "</p>")))))

(defun trim-ends (prefix string suffix)
  (declare (string prefix string suffix))
  (let ((pre (mismatch string prefix))
        (suf (mismatch string suffix :from-end t)))
    (subseq string
            (if (= pre (length prefix)) pre 0)
            (if (= suf (- (length string) (length suffix)))
                suf
                (length string)))))
