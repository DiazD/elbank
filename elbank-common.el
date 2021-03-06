;;; elbank-common.el --- Elbank common use functions and variables  -*- lexical-binding: t; -*-

;; Copyright (C) 2017  Nicolas Petton

;; Author: Nicolas Petton <nicolas@petton.fr>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file defines common data structures, variables and functions used in
;; Elbank.

;;; Code:

(require 'map)
(require 'seq)
(require 'json)
(eval-and-compile (require 'cl-lib))

(declare-function elbank-report "elbank-report.el")

;;;###autoload
(defgroup elbank nil
  "Elbank"
  :prefix "elbank-"
  :group 'tools)

;;;###autoload
(defcustom elbank-data-file (locate-user-emacs-file "elbank-data.json")
  "Location of the file used to store elbank data."
  :type '(file))

;;;###autoload
(defcustom elbank-categories nil
  "Alist of categories of transactions.

Each category has an associated list of regular expressions.
A transaction's category is found by testing each regexp in order.

Example of categories

 (setq elbank-categories
   \\='((\"Expenses:Groceries\" . (\"walmart\" \"city market\"))
     (\"Income:Salary\" . (\"paycheck\"))))"
  :type '(alist :key-type (string :tag "Category name")
		:value-type (repeat (string :tag "Regexp"))))

(defface elbank-header-face '((t . (:inherit font-lock-keyword-face
					     :height 1.3)))
  "Face for displaying header in elbank."
  :group 'elbank)

(defface elbank-subheader-face '((t . (:weight bold
				       :height 1.1)))
  "Face for displaying sub headers in elbank."
  :group 'elbank)

(defface elbank-positive-amount-face '((t . (:inherit success :weight normal)))
  "Face for displaying positive amounts."
  :group 'elbank)

(defface elbank-negative-amount-face '((t . (:inherit error :weight normal)))
  "Face for displaying positive amounts."
  :group 'elbank)

(defface elbank-entry-face '((t . ()))
  "Face for displaying entries in elbank."
  :group 'elbank)

(defvar elbank-data nil
  "Alist of all accounts and transactions.")

(defvar elbank-report-available-columns '(date rdate label raw category amount)
  "List of all available columns in reports.")


(defun elbank-read-data ()
  "Return an alist of boobank data read from `elbank-data-file'.
Data is cached to `elbank-data'."
  (let ((data (when (file-exists-p (expand-file-name elbank-data-file))
		(json-read-file elbank-data-file))))
    (setq elbank-data data)))

(defun elbank-write-data (data)
  "Write DATA to `elbank-data-file'."
  (make-directory (file-name-directory elbank-data-file) t)
  (with-temp-file elbank-data-file
    (insert (json-encode data))))

(defun elbank-list-transactions (account)
  "Display the list of transactions for ACCOUNT."
  (elbank-report :account-id (intern (map-elt account 'id))
		 :reverse-sort t))

(defun elbank-transaction-category (transaction)
  "Return the category TRANSACTION belongs to.
If TRANSACTION matches no category, return nil."
  (seq-find #'identity
	    (map-apply (lambda (key category)
			 (when (seq-find
				(lambda (regexp)
				  (string-match-p (downcase regexp)
						  (downcase (map-elt transaction
								     'raw))))
				category)
			   key))
		       elbank-categories)))

(cl-defun elbank-filter-transactions (&key account-id period category)
  "Filter transactions, all keys are optional.

Return transactions in the account with id ACCOUNT-ID for a PERIOD
that belong to CATEGORY.

ACCOUNT-ID is a symbol, PERIOD is a list of the form `(type
time)', CATEGORY is a category string."
  (elbank-filter-transactions-period
   (elbank-filter-transactions-category
    (if account-id
	(map-elt (map-elt elbank-data 'transactions) account-id)
      (elbank-all-transactions))
    category)
   period))

(defun elbank-filter-transactions-category (transactions category)
  "Return the subset of TRANSACTIONS that belong to CATEGORY.

CATEGORY is a string of the form \"cat:subcat:subsubcat\"
representing the path of a category."
  (if category
      (seq-filter (lambda (transaction)
		    (elbank-transaction-in-category-p transaction category))
		  transactions)
    transactions))

(defun elbank-transaction-in-category-p (transaction category)
  "Return non-nil if TRANSACTION belongs to CATEGORY."
  (string-prefix-p (downcase category)
		   (downcase (or (elbank-transaction-category
				  transaction)
				 ""))))


(defun elbank-filter-transactions-period (transactions period)
  "Return the subset of TRANSACTIONS that are within PERIOD.

PERIOD is a list of the form `(type time)', with `type' a
symbol (`month' or `year'), and `time' an encoded time."
  (pcase (car period)
    (`year (elbank--filter-transactions-period-format transactions
						      (cadr period)
						      "%Y"))
    (`month (elbank--filter-transactions-period-format transactions
						       (cadr period)
						       "%Y-%m"))
    (`nil transactions)
    (_ (error "Invalid period type %S" (car period)))))

(defun elbank--filter-transactions-period-format (transactions time format)
  "Return the subset of TRANSACTIONS within TIME.
Comparison is done by formatting periods using FORMAT."
  (seq-filter (lambda (transaction)
		(let ((tr-time (elbank--transaction-time transaction)))
		  (string= (format-time-string format time)
			   (format-time-string format tr-time))))
	      transactions))

(defun elbank--transaction-time (transaction)
  "Return the encoded time for TRANSACTION."
  (apply #'encode-time
	 (seq-map (lambda (el)
		    (or el 0))
		  (parse-time-string (map-elt transaction 'date)))))

(defun elbank-sum-transactions (transactions)
  "Return the sum of all TRANSACTIONS.
TRANSACTIONS are expected to all use the same currency."
  (seq-reduce (lambda (acc transaction)
		(+ acc
		   (string-to-number (map-elt transaction 'amount))))
	      transactions
	      0))

(defun elbank-transaction-years ()
  "Return all years for which there is a transaction."
  (seq-sort #'time-less-p
	    (seq-uniq
	     (seq-map (lambda (transaction)
			(encode-time 0 0 0 1 1 (seq-elt (decode-time
							 (elbank--transaction-time transaction))
							5)))
		      (elbank-all-transactions)))))

(defun elbank-transaction-months ()
  "Return all months for which there is a transaction."
  (seq-sort #'time-less-p
	    (seq-uniq
	     (seq-map (lambda (transaction)
			(let ((time (decode-time
				     (elbank--transaction-time transaction))))
			  (encode-time 0 0 0 1 (seq-elt time 4) (seq-elt time 5))))
		      (elbank-all-transactions)))))

(defun elbank-all-transactions ()
  "Return all transactions for all accounts."
  (seq-remove #'seq-empty-p
	      (apply #'seq-concatenate
		     'vector
		     (map-values (map-elt elbank-data 'transactions)))))

(defun elbank-account (id)
  "Return the account with ID, or nil."
  (unless (stringp id)
    (setq id (symbol-name id)))
  (seq-find (lambda (account)
	      (string= id (map-elt account 'id)))
	    (map-elt elbank-data 'accounts)))

(defun elbank--longest-account-label ()
  "Return the longest account label from all accoutns."
  (seq-reduce (lambda (label1 label2)
		(if (> (seq-length label1)
		       (seq-length label2))
		    label1
		  label2))
	      (seq-map (lambda (account)
			 (map-elt account 'label))
		       (map-elt elbank-data 'accounts))
	      ""))

(defun elbank--insert-amount (amount &optional currency)
  "Insert AMOUNT as a float with a precision of 2 decimals.
When CURRENCY is non-nil, append it to the inserted text.
AMOUNT is fontified based on whether it is negative or positive."
  (let ((beg (point))
	(number (if (numberp amount)
		    amount
		  (string-to-number amount))))
    (insert (format "%.2f %s" number (or currency "")))
    (put-text-property beg (point)
		       'face
		       (if (< number 0)
			   'elbank-negative-amount-face
			 'elbank-positive-amount-face))))

(defun elbank--propertize-amount (amount &optional currency)
  "Fontify AMOUNT based on whether it is positive or not.
When CURRENCY is non-nil, append it to the inserted text."
  (with-temp-buffer
    (elbank--insert-amount amount currency)
    (buffer-string)))

(defun elbank-format-period (period)
  "Return the string representation of PERIOD."
  (pcase (car period)
    (`year (format-time-string "Year %Y" (cadr period)))
    (`month (format-time-string "%B %Y" (cadr period)))
    (`nil "")
    (`_ "Invalid period")))

(defun elbank-quit ()
  "Kill the current buffer."
  (interactive)
  (quit-window t))

;;;
;;; Common major-mode for reports
;;;

(defvar elbank-report-update-hook nil
  "Hook run when a report update is requested.")

(defvar elbank-report-period nil
  "Period filter used in a report buffer.")
(make-variable-buffer-local 'elbank-report-period)

(defvar elbank-base-report-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'elbank-quit)
    (define-key map (kbd "n") #'forward-button)
    (define-key map (kbd "p") #'backward-button)
    (define-key map [tab] #'forward-button)
    (define-key map [backtab] #'backward-button)
    (define-key map (kbd "M-n") #'elbank-base-report-forward-period)
    (define-key map (kbd "M-p") #'elbank-base-report-backward-period)
    (define-key map (kbd "g") #'elbank-base-report-refresh)
    map)
  "Keymap for `elbank-base-report-mode'.")

(define-derived-mode elbank-base-report-mode nil "Base elbank reports"
  "Base major mode for viewing a report.

\\{elbank-base-report-mode-map}"
  (setq-local truncate-lines nil)
  (read-only-mode))

(defun elbank-base-report-refresh ()
  "Request an update of the current report."
  (interactive)
  (run-hooks 'elbank-base-report-refresh-hook))

(defun elbank-base-report-forward-period (&optional n)
  "Select the next N period and update the current report.
If there is no period filter, signal an error."
  (interactive "p")
  (unless elbank-report-period
    (user-error "No period filter for the current report"))
  (let* ((periods (pcase (car elbank-report-period)
		    (`year (elbank-transaction-years))
		    (`month (elbank-transaction-months))))
	 (cur-index (seq-position periods (cadr elbank-report-period)))
	 (new-index (+ n cur-index))
	 (period (seq-elt periods new-index)))
    (if period
	(progn
	  (setq elbank-report-period (list (car elbank-report-period)
					   period))
	  (elbank-base-report-refresh))
      (user-error "No more periods"))))

(defun elbank-base-report-backward-period (&optional n)
  "Select the previous N period and update the current report.
If there is no period filter, signal an error."
  (interactive "p")
  (elbank-base-report-forward-period (- n)))

(provide 'elbank-common)
;;; elbank-common.el ends here
