;; register.lisp

(declaim (optimize (safety 3) (debug 3) (speed 1) (space 0)))

(in-package :ledger)

(defun abbreviate-string (name width &key
			  (elision-style 'abbreviate)
			  (account-p nil)
			  (abbrev-length 3))
  (let ((len (length name)))
    (if (<= len width)
	name
	(cond
	  ((eq elision-style 'leading)
	   (concatenate 'string ".." (subseq name (- len (- width 2)))))

	  ((eq elision-style 'middle)
	   (concatenate 'string (subseq name 0 (1- (/ width 2))) ".."
			(subseq name (1+ (/ width 2)))))

	  ((and (eq elision-style 'abbreviate)
		account-p)
	   (let* ((parts (split-string-at-char name #\:))
		  (final-part (car (last parts))) last-part
		  (abbrev
		   (reduce
		    #'(lambda (left right)
			(if (eq right final-part)
			    (concatenate
			     'string
			     (or last-part
				 (subseq left 0 abbrev-length))
			     ":" right)
			    (let ((left-abbrev
				   (or last-part
				       (subseq left 0 abbrev-length)))
				  (right-abbrev
				   (subseq right 0 abbrev-length)))
			      (setf last-part
				    (concatenate 'string left-abbrev ":"
						 right-abbrev)))))
		    parts)))
	     (if (> (length abbrev) width)
		 (abbreviate-string abbrev width :elision-style 'leading)
		 abbrev)))
	  (t
	   (concatenate 'string (subseq name 0 (- width 2)) ".."))))))

(export 'abbreviate-string)

(defun register-reporter (&key (output-stream *standard-output*))
  (let (last-entry)
    (lambda (xact)
      (if (or (null last-entry)
	      (not (eq last-entry (xact-entry xact))))
	  (progn
	    (format output-stream "~10A ~20A "
		    ;; jww (2007-11-19): What if the transaction has its own date
		    ;; set?
		    (strftime (xact-date xact))
		    (abbreviate-string (entry-payee (xact-entry xact)) 20))
	    (setf last-entry (xact-entry xact)))
	  (format output-stream "~32A" " "))
      (format output-stream "~22A ~A ~A~%"
	      (abbreviate-string (account-fullname (xact-account xact)) 22
				 :account-p t)
	      (format-value (xact-resolve-amount xact)
			    :width 12 :latter-width 67)
	      (format-value (or (xact-value xact :running-total)
				0) :width 12 :latter-width 80)))))

(defun register-report (xact-series &key (output-stream *standard-output*))
  (let ((reporter (register-reporter :output-stream output-stream))
	(count 0))
    (iterate ((xact xact-series))
	     (funcall reporter xact)
	     (incf count))
    count))

(export 'register-report)

(defun extract-keywords (keyword-or-list args)
  (declare (type (or list keyword) keyword-or-list))
  (declare (type list args))
  (let ((cell (member-if #'(lambda (arg)
			     (if (keywordp keyword-or-list)
				 (eq keyword-or-list arg)
				 (member arg keyword-or-list)))
			 args))
	value)
    (if cell
	(values (setf value (cadr cell))
		(delete-if #'(lambda (cons)
			       (or (eq cons (car cell))
				   (eq cons value))) args))
	(values nil args))))

(defun register (binder &rest args)
  "This is a convenience function for quickly making register reports.

  A typical usage might be:

    (ledger:register \"/path/to/ledger.dat\"
                     :begin \"2007/08/26\" :account \"food\")

  "
  (let ((binder (etypecase binder
		  ((or string pathname) (read-binder binder))
		  (binder binder)))
	total amount
	head tail
	period)

    (multiple-value-setq (total args)
      (extract-keywords :total args))
    (multiple-value-setq (amount args)
      (extract-keywords :amount args))
    (multiple-value-setq (head args)
      (extract-keywords '(:head :first :top) args))
    (multiple-value-setq (tail args)
      (extract-keywords '(:tail :last :bottom) args))
    (multiple-value-setq (period args)
      (extract-keywords '(:period :group) args))

    (let ((xacts (scan-normalized-transactions binder)))

      (if args
	  (setf xacts (choose-if (apply #'compose-predicate args)
				 xacts)))

      (if period
	  (setf xacts
		(group-by-period xacts (if (stringp period)
					   (parse-time-period period)
					   period))))

      (setf xacts (calculate-totals xacts :amount amount :total total))
      
      (cond
	(head
	 (register-report (choose (latch xacts :after head) xacts)))
	(tail
	 ;; Tail is expensive, because we don't know the length of the
	 ;; transaction series until every element has been seen (and hence
	 ;; computed).  Expect a large pause for giant data sets.
	 (let ((length (collect-length xacts)))
	   (register-report (choose (latch xacts :after (- length tail)
						 :pre nil) xacts))))
	(t
	 (register-report xacts))))))

(provide 'register)

;; register.lisp ends here