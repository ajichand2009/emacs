;;; loadhist.el --- lisp functions for working with feature groups  -*- lexical-binding: t -*-

;; Copyright (C) 1995, 1998, 2000-2025 Free Software Foundation, Inc.

;; Author: Eric S. Raymond <esr@thyrsus.com>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: internal

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; These functions exploit the load-history system variable.
;; Entry points include `unload-feature', `symbol-file', and
;; `feature-file', documented in the Emacs Lisp manual.

;;; Code:

(eval-when-compile (require 'cl-lib))

(defun feature-symbols (feature)
  "Return the file and list of definitions associated with FEATURE.
The value is actually the element of `load-history'
for the file that did (provide FEATURE)."
  (catch 'foundit
    (let ((element (cons 'provide feature)))
      (dolist (x load-history nil)
	(when (member element (cdr x))
	  (throw 'foundit x))))))

(defun feature-file (feature)
  "Return the file name from which a given FEATURE was loaded.
Actually, return the load argument, if any; this is sometimes the name of a
Lisp file without an extension.  If the feature came from an `eval-buffer' on
a buffer with no associated file, or an `eval-region', return nil."
  (if (not (featurep feature))
      (error "%S is not a currently loaded feature" feature)
    (car (feature-symbols feature))))

(defun file-loadhist-lookup (file)
  "Return the `load-history' element for FILE.
FILE can be a file name, or a library name.
A library name is equivalent to the file name that `load-library' would load."
  ;; First look for FILE as given.
  (let ((symbols (assoc file load-history)))
    ;; Try converting a library name to an absolute file name.
    (and (null symbols)
	 (let ((absname
		(locate-file file load-path (get-load-suffixes))))
	   (and absname (not (equal absname file))
		(setq symbols (cdr (assoc absname load-history))))))
    symbols))

(defun file-provides (file)
  "Return the list of features provided by FILE as it was loaded.
FILE can be a file name, or a library name.
A library name is equivalent to the file name that `load-library' would load."
  (let (provides)
    (dolist (x (file-loadhist-lookup file) provides)
      (when (eq (car-safe x) 'provide)
	(push (cdr x) provides)))))

(defun file-requires (file)
  "Return the list of features required by FILE as it was loaded.
FILE can be a file name, or a library name.
A library name is equivalent to the file name that `load-library' would load."
  (let (requires)
    (dolist (x (file-loadhist-lookup file) requires)
      (when (eq (car-safe x) 'require)
	(push (cdr x) requires)))))

(defun file-dependents (file)
  "Return the list of loaded libraries that depend on FILE.
This can include FILE itself.
FILE can be a file name, or a library name.
A library name is equivalent to the file name that `load-library' would load."
  (let ((provides (file-provides file))
	(dependents nil))
    (dolist (x load-history dependents)
      (when (and (stringp (car x))
                 (seq-intersection provides (file-requires (car x)) #'eq))
	(push (car x) dependents)))))

(defun read-feature (prompt &optional loaded-p)
  "Read feature name from the minibuffer, prompting with string PROMPT.
If optional second arg LOADED-P is non-nil, the feature must be loaded
from a file."
  (intern (completing-read
           prompt
           (mapcar #'symbol-name
                   (if loaded-p
                       (delq nil
                             (mapcar
                              (lambda (x) (and (feature-file x) x))
                              features))
                     features)))))

(define-obsolete-variable-alias 'loadhist-hook-functions
  'unload-feature-special-hooks "30.1")
(defvar unload-feature-special-hooks
  '(after-change-functions after-insert-file-functions
    after-make-frame-functions auto-coding-functions
    auto-fill-function before-change-functions
    blink-paren-function buffer-access-fontify-functions
    choose-completion-string-functions
    comint-output-filter-functions command-line-functions
    comment-indent-function compilation-finish-functions
    delete-frame-functions disabled-command-function
    fill-nobreak-predicate find-directory-functions
    find-file-not-found-functions
    font-lock-fontify-buffer-function
    font-lock-fontify-region-function
    font-lock-mark-block-function
    font-lock-syntactic-face-function
    font-lock-unfontify-buffer-function
    font-lock-unfontify-region-function
    kill-buffer-query-functions kill-emacs-query-functions
    lisp-indent-function mouse-position-function
    suspend-tty-functions
    temp-buffer-show-function window-scroll-functions
    window-size-change-functions write-contents-functions
    write-file-functions write-region-annotate-functions)
  "A list of special hooks from Info node `(elisp)Standard Hooks'.

These are symbols with hooklike values whose names don't end in
`-hook' or `-hooks', from which `unload-feature' should try to remove
pertinent symbols.")

(defvar unload-function-defs-list nil
  "List of definitions in the Lisp library being unloaded.

This is meant to be used by `FEATURE-unload-function'; see the
documentation of `unload-feature' for details.")

(defun unload--set-major-mode ()
  (save-current-buffer
    (dolist (buffer (buffer-list))
      (set-buffer buffer)
      (let ((proposed (derived-mode-all-parents major-mode)))
        ;; Look for a predecessor mode not defined in the feature we're processing
        (while (and proposed (rassq (car proposed) unload-function-defs-list))
          (setq proposed (cdr proposed)))
        (unless (eq (car proposed) major-mode)
          ;; Two cases: either proposed is nil, and we want to switch to fundamental
          ;; mode, or proposed is not nil and not major-mode, and so we use it.
          (funcall (or (car proposed) 'fundamental-mode)))))))

(defvar loadhist-unload-filename nil)

(cl-defgeneric loadhist-unload-element (x)
  "Unload an element from the `load-history'.
The variable `loadhist-unload-filename' holds the name of the file we're
unloading."
  (message "Unexpected element %S in load-history" x))

(cl-defmethod loadhist-unload-element ((x (head defun)))
  (let* ((fun (cdr x))
         (hist (get fun 'function-history)))
    (cond
     ((null hist)
      (defalias fun nil)
      ;; FIXME: Arguably these properties should be applied via
      ;; `define-symbol-prop', but most code still uses just `put'.
      ;; FIXME: Maybe these properties should be attached to the
      ;; function itself (as for `advertised-calling-convention')
      ;; rather than to its symbol.
      (if (get fun 'compiler-macro) (put fun 'compiler-macro nil))
      (if (get fun 'gv-expander)    (put fun 'gv-expander nil))
      ;; Override the change that `defalias' just recorded.
      (put fun 'function-history nil))
     ((equal (car hist) loadhist-unload-filename)
      (defalias fun (cadr hist))
      ;; Set the history afterwards, to override the change that
      ;; `defalias' records otherwise.
      (put fun 'function-history (cddr hist)))
     (t
      ;; Unloading a file whose definition is "inactive" (i.e. has been
      ;; overridden by another file): just remove it from the history,
      ;; so future unloading of that other file has a chance to DTRT.
      (let* ((tmp (plist-member hist loadhist-unload-filename))
             (pos (- (length hist) (length tmp))))
        (cl-assert (> pos 1))
        (setcdr (nthcdr (- pos 2) hist) (cdr tmp)))))))

(cl-defmethod loadhist-unload-element ((_ (head require))) nil)
(cl-defmethod loadhist-unload-element ((_ (head defface))) nil)

(cl-defmethod loadhist-unload-element ((x (head provide)))
  ;; Remove any feature names that this file provided.
  (setq features (delq (cdr x) features)))

(cl-defmethod loadhist-unload-element ((x symbol))
  ;; Kill local values as much as possible.
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (if (and (boundp x) (timerp (symbol-value x)))
	  (cancel-timer (symbol-value x)))
      (kill-local-variable x)))
  (if (and (boundp x) (timerp (symbol-value x)))
      (cancel-timer (symbol-value x)))
  (cond
   ;; "Unbind" indirect variable.
   ((not (eq (indirect-variable x) x))
    (internal-delete-indirect-variable x))
   ;; Get rid of the default binding if we can.
   ((not (local-variable-if-set-p x))
    (makunbound x))))

(cl-defmethod loadhist-unload-element ((x (head define-type)))
  (let* ((name (cdr x)))
    ;; Remove the struct.
    (setf (cl--find-class name) nil)))

(cl-defmethod loadhist-unload-element ((x (head define-symbol-props)))
  (pcase-dolist (`(,symbol . ,props) (cdr x))
    (dolist (prop props)
      (put symbol prop nil))))

;;;###autoload
(defun unload-feature (feature &optional force)
  "Unload the library that provided FEATURE.
If the feature is required by any other loaded code, and prefix arg FORCE
is nil, raise an error.

Standard unloading activities include restoring old autoloads for
functions defined by the library, removing such functions from
hooks and `auto-mode-alist', undoing their ELP profiling,
unproviding any features provided by the library, and canceling
timers held in variables defined by the library.

If a function `FEATURE-unload-function' is defined, this function
calls it with no arguments, before doing anything else.  That function
can do whatever is appropriate to undo the loading of the library.  If
`FEATURE-unload-function' returns non-nil, that suppresses the
standard unloading of the library.  Otherwise the standard unloading
proceeds.

`FEATURE-unload-function' has access to the package's list of
definitions in the variable `unload-function-defs-list' and could
remove symbols from it in the event that the package has done
something strange, such as redefining an Emacs function."
  (interactive
   (list
    (read-feature "Unload feature: " t)
    current-prefix-arg))
  (unless (featurep feature)
    (error "%s is not a currently loaded feature" (symbol-name feature)))
  (unless force
    (let* ((file (feature-file feature))
	   (dependents (delete file (copy-sequence (file-dependents file)))))
      (when dependents
	(error "Loaded libraries %s depend on %s"
	       (prin1-to-string dependents) file))))
  (let* ((unload-function-defs-list (feature-symbols feature))
         (file (pop unload-function-defs-list))
         (loadhist-unload-filename file)
	 (name (symbol-name feature))
         (unload-hook (intern-soft (concat name "-unload-hook")))
	 (unload-func (intern-soft (concat name "-unload-function"))))
    ;; If FEATURE-unload-function is defined and returns non-nil,
    ;; don't try to do anything more; otherwise proceed normally.
    (unless (and (fboundp unload-func)
		 (funcall unload-func))
      ;; Try to avoid losing badly when hooks installed in critical
      ;; places go away.  (Some packages install things on
      ;; `kill-buffer-hook', `activate-menubar-hook' and the like.)
      (if unload-hook
	  ;; First off, provide a clean way for package FOO to arrange
	  ;; this by adding hooks on the variable `FOO-unload-hook'.
	  ;; This is obsolete; FEATURE-unload-function should be used now.
	  (run-hooks unload-hook)
	;; Otherwise, do our best.  Look through the obarray for symbols
	;; which seem to be hook variables or special hook functions and
	;; remove anything from them which matches the feature-symbols
	;; about to get zapped.  Obviously this won't get anonymous
	;; functions which the package might just have installed, and
	;; there might be other important state, but this tactic
	;; normally works.
        (let ((removables (cl-loop for def in unload-function-defs-list
                                   when (and (eq (car-safe def) 'defun)
                                             (not (get (cdr def) 'autoload)))
                                   collect (cdr def))))
          (mapatoms
	   (lambda (x)
	     (when (and (boundp x)
		        (or (and (consp (symbol-value x)) ; Random hooks.
			         (string-match "-hooks?\\'" (symbol-name x)))
                            ;; Known abnormal hooks etc.
			    (memq x unload-feature-special-hooks)))
	       (dolist (func removables)
	         (remove-hook x func)))))
          (save-current-buffer
            (dolist (buffer (buffer-list))
              (pcase-dolist (`(,sym . ,val) (buffer-local-variables buffer))
                (when (or (and (consp val)
                               (string-match "-hooks?\\'" (symbol-name sym)))
                          (memq sym unload-feature-special-hooks))
                  (set-buffer buffer)
                  (dolist (func removables)
                    (remove-hook sym func t))))))
          ;; Remove any feature-symbols from auto-mode-alist as well.
          (dolist (func removables)
            (setq auto-mode-alist
                  (rassq-delete-all func auto-mode-alist)))))

      ;; Change major mode in all buffers using one defined in the feature being unloaded.
      (unload--set-major-mode)

      (mapc #'loadhist-unload-element unload-function-defs-list)
      ;; Delete the load-history element for this file.
      (setq load-history (delq (assoc file load-history) load-history))))
  ;; Don't return load-history, it is not useful.
  nil)

;; Obsolete.

(defsubst file-set-intersect (p q)
  "Return the set intersection of two lists."
  (declare (obsolete seq-intersection "28.1"))
  (nreverse (seq-intersection p q #'eq)))

(provide 'loadhist)

;;; loadhist.el ends here
