;;; jka-cmpr-hook.el --- preloaded code to enable jka-compr.el  -*- lexical-binding: t; -*-

;; Copyright (C) 1993-1995, 1997, 1999-2000, 2002-2025 Free Software
;; Foundation, Inc.

;; Author: Jay K. Adams <jka@ece.cmu.edu>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: data
;; Package: emacs

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

;; This file contains the code to enable and disable Auto-Compression mode.
;; It is preloaded.  The guts of this mode are in jka-compr.el, which
;; is loaded only when you really try to uncompress something.

;;; Code:

(defgroup compression nil
  "Data compression utilities."
  :group 'data)

(defgroup jka-compr nil
  "jka-compr customization."
  :group 'compression)

(defcustom jka-compr-verbose t
  "If non-nil, output messages whenever compressing or uncompressing files."
  :version "24.1"
  :type 'boolean
  :group 'jka-compr)

;; List of all the elements we actually added to file-coding-system-alist.
(defvar jka-compr-added-to-file-coding-system-alist nil)

(defvar jka-compr-file-name-handler-entry
  nil
  "`file-name-handler-alist' entry used by jka-compr I/O functions.")

;; Compiler defvars.  These three variables will be defined later with
;; `defcustom' when everything used in the :set functions is defined.
(defvar jka-compr-compression-info-list)
(defvar jka-compr-mode-alist-additions)
(defvar jka-compr-load-suffixes)

(defvar jka-compr-compression-info-list--internal nil
  "Stored value of `jka-compr-compression-info-list'.
If Auto Compression mode is enabled, this is the value of
`jka-compr-compression-info-list' when `jka-compr-install' was last called.
Otherwise, it is nil.")

(defvar jka-compr-mode-alist-additions--internal nil
  "Stored value of `jka-compr-mode-alist-additions'.
If Auto Compression mode is enabled, this is the value of
`jka-compr-mode-alist-additions' when `jka-compr-install' was last called.
Otherwise, it is nil.")

(defvar jka-compr-load-suffixes--internal nil
  "Stored value of `jka-compr-load-suffixes'.
If Auto Compression mode is enabled, this is the value of
`jka-compr-load-suffixes' when `jka-compr-install' was last called.
Otherwise, it is nil.")


(defun jka-compr-build-file-regexp ()
  (let ((re-anchored '())
        (re-free '()))
    (dolist (e jka-compr-compression-info-list)
      (let ((re (jka-compr-info-regexp e)))
        (if (string-match "\\\\'\\'" re)
            (push (substring re 0 (match-beginning 0)) re-anchored)
          (push re re-free))))
    (concat
     (if re-free (concat (mapconcat 'identity re-free "\\|") "\\|"))
     "\\(?:"
     (mapconcat 'identity re-anchored "\\|")
     "\\)" file-name-version-regexp "?\\'")))

;; Functions for accessing the return value of jka-compr-get-compression-info
;; FIXME: Use cl-defstruct!
(defun jka-compr-info-regexp               (info)  (aref info 0))
(defun jka-compr-info-compress-message     (info)  (aref info 1))
(defun jka-compr-info-compress-program     (info)  (aref info 2))
(defun jka-compr-info-compress-args        (info)  (aref info 3))
(defun jka-compr-info-uncompress-message   (info)  (aref info 4))
(defun jka-compr-info-uncompress-program   (info)  (aref info 5))
(defun jka-compr-info-uncompress-args      (info)  (aref info 6))
(defun jka-compr-info-can-append           (info)  (aref info 7))
(defun jka-compr-info-strip-extension      (info)  (aref info 8))
(defun jka-compr-info-file-magic-bytes     (info)  (aref info 9))
(defun jka-compr-info-uncompress-function  (info)
  (and (> (length info) 10)
       (aref info 10)))


(defun jka-compr-get-compression-info (filename)
  "Return information about the compression scheme of FILENAME.
The determination as to which compression scheme, if any, to use is
based on the filename itself and `jka-compr-compression-info-list'."
  (setq filename (file-name-sans-versions filename))
  (catch 'compression-info
    (let ((case-fold-search nil))
      (dolist (x jka-compr-compression-info-list)
        (and (string-match (jka-compr-info-regexp x) filename)
             (throw 'compression-info x)))
      nil)))

(defun jka-compr-install ()
  "Install jka-compr.
This adds entries to `file-name-handler-alist' and `auto-mode-alist'
and `inhibit-local-variables-suffixes'."

  (setq jka-compr-file-name-handler-entry
	(cons (jka-compr-build-file-regexp) 'jka-compr-handler))

  (push jka-compr-file-name-handler-entry file-name-handler-alist)

  (setq jka-compr-compression-info-list--internal
	jka-compr-compression-info-list
	jka-compr-mode-alist-additions--internal
	jka-compr-mode-alist-additions
	jka-compr-load-suffixes--internal
	jka-compr-load-suffixes)

  (dolist (x jka-compr-compression-info-list)
    ;; Don't do multibyte encoding on the compressed files.
    (let ((elt (cons (jka-compr-info-regexp x)
                     '(no-conversion . no-conversion))))
      (push elt file-coding-system-alist)
      (push elt jka-compr-added-to-file-coding-system-alist))

    (and (jka-compr-info-strip-extension x)
         ;; Make entries in auto-mode-alist so that modes
         ;; are chosen right according to the file names
         ;; sans `.gz'.
         (push (list (jka-compr-info-regexp x) nil 'jka-compr) auto-mode-alist)
         ;; Also add these regexps to inhibit-local-variables-suffixes,
         ;; so that a -*- line in the first file of a compressed tar file,
         ;; or a Local Variables section in a member file at the end of
         ;; the tar file don't override tar-mode.
         (push (jka-compr-info-regexp x)
               inhibit-local-variables-suffixes)))
  (setq auto-mode-alist
	(append auto-mode-alist jka-compr-mode-alist-additions))

  ;; Make sure that (load "foo") will find /bla/foo.el.gz.
  (dolist (suff jka-compr-load-suffixes load-file-rep-suffixes)
    (add-to-list 'load-file-rep-suffixes suff t)))

(defun jka-compr-installed-p ()
  "Return non-nil if jka-compr is installed.
The return value is the entry in `file-name-handler-alist' for jka-compr."

  (let ((fnha file-name-handler-alist)
	(installed nil))

    (while (and fnha (not installed))
     (and (eq (cdr (car fnha)) 'jka-compr-handler)
	   (setq installed (car fnha)))
      (setq fnha (cdr fnha)))

    installed))

(defun jka-compr-update ()
  "Update Auto Compression mode for changes in option values.
If you change the options `jka-compr-compression-info-list',
`jka-compr-mode-alist-additions' or `jka-compr-load-suffixes'
outside Custom, while Auto Compression mode is already enabled
\(as it is by default), then you have to call this function
afterward to properly update other variables.  Setting these
options through Custom does this automatically."
  (when (jka-compr-installed-p)
    (jka-compr-uninstall)
    (jka-compr-install)))

(defun jka-compr-set (variable value)
  "Internal Custom :set function."
  (set-default variable value)
  (jka-compr-update))

;; I have this defined so that .Z files are assumed to be in unix
;; compress format; and .gz files, in gzip format, and .bz2 files in bzip fmt.
(defcustom jka-compr-compression-info-list
  ;;[regexp
  ;; compr-message  compr-prog  compr-args
  ;; uncomp-message uncomp-prog uncomp-args
  ;; can-append strip-extension-flag file-magic-bytes
  ;; uncompress-function]
  `(["\\.Z\\'"
     "compressing"    "compress"     ("-c")
     ;; gzip is more common than uncompress. It can only read, not write.
     "uncompressing"  "gzip"   ("-c" "-q" "-d")
     nil t "\037\235"
     zlib-decompress-region]
     ;; Formerly, these had an additional arg "-c", but that fails with
     ;; "Version 0.1pl2, 29-Aug-97." (RedHat 5.1 GNU/Linux) and
     ;; "Version 0.9.0b, 9-Sept-98".
    ["\\.bz2\\'"
     "bzip2ing"        "bzip2"         nil
     "bunzip2ing"      "bzip2"         ("-d")
     nil t "BZh"]
    ["\\.tbz2?\\'"
     "bzip2ing"        "bzip2"         nil
     "bunzip2ing"      "bzip2"         ("-d")
     nil nil "BZh"]
    ["\\.\\(?:tgz\\|svgz\\|sifz\\)\\'"
     "compressing"        "gzip"         ("-c" "-q")
     "uncompressing"      "gzip"         ("-c" "-q" "-d")
     t nil "\037\213"
     zlib-decompress-region]
    ["\\.g?z\\'"
     "compressing"        "gzip"         ("-c" "-q")
     "uncompressing"      "gzip"         ("-c" "-q" "-d")
     t t "\037\213"
     zlib-decompress-region]
    ["\\.lz\\'"
     "Lzip compressing"   "lzip"         ("-c" "-q")
     "Lzip uncompressing" "lzip"         ("-c" "-q" "-d")
     t t "LZIP"]
    ["\\.lzma\\'"
     "LZMA compressing"   "lzma"         ("-c" "-q" "-z")
     "LZMA uncompressing" "lzma"         ("-c" "-q" "-d")
     t t ""]
    ["\\.xz\\'"
     ;; On MacOS, gzip can uncompress xz files.
     "XZ compressing" ,(if (featurep 'ns) "gzip" "xz") ("-c" "-q")
     "XZ uncompressing"   "xz"           ("-c" "-q" "-d")
     t t "\3757zXZ\0"]
    ["\\.txz\\'"
     "XZ compressing"     "xz"           ("-c" "-q")
     "XZ uncompressing"   "xz"           ("-c" "-q" "-d")
     t nil "\3757zXZ\0"]
    ;; dzip is gzip with random access.  Its compression program can't
    ;; read/write stdin/out, so .dz files can only be viewed without
    ;; saving, having their contents decompressed with gzip.
    ["\\.dz\\'"
     nil              nil            nil
     "uncompressing"      "gzip"         ("-c" "-q" "-d")
     nil t "\037\213"]
    ["\\.zst\\'"
     "zstd compressing"   "zstd"         ("-c" "-q")
     "zstd uncompressing" "zstd"         ("-c" "-q" "-d")
     t t "\050\265\057\375"]
    ["\\.tzst\\'"
     "zstd compressing"   "zstd"         ("-c" "-q")
     "zstd uncompressing" "zstd"         ("-c" "-q" "-d")
     t nil "\050\265\057\375"])

  "List of vectors that describe available compression techniques.
Each element, which describes a compression technique, is a vector of
the form [REGEXP COMPRESS-MSG COMPRESS-PROGRAM COMPRESS-ARGS
UNCOMPRESS-MSG UNCOMPRESS-PROGRAM UNCOMPRESS-ARGS
APPEND-FLAG STRIP-EXTENSION-FLAG FILE-MAGIC-CHARS UNCOMPRESS-FUNCTION], where:

   regexp                is a regexp that matches filenames that are
                         compressed with this format

   compress-msg          is the message to issue to the user when doing this
                         type of compression (nil means no message)

   compress-program      is a program that performs this compression
                         (nil means visit file in read-only mode)

   compress-args         is a list of args to pass to the compress program

   uncompress-msg        is the message to issue to the user when doing this
                         type of uncompression (nil means no message)

   uncompress-program    is a program that performs this uncompression

   uncompress-args       is a list of args to pass to the uncompress program

   append-flag           is non-nil if this compression technique can be
                         appended

   strip-extension-flag  non-nil means strip the regexp from file names
                         before attempting to set the mode.

   file-magic-chars      is a string of characters that you would find
			 at the beginning of a file compressed in this way.

   uncompress-function   is a function that performs uncompression, if
                         uncompress-program is not found.

If you set this outside Custom while Auto Compression mode is
already enabled \(as it is by default), you have to call
`jka-compr-update' after setting it to properly update other
variables.  Setting this through Custom does that automatically."
  :type '(repeat (vector regexp
			 (choice :tag "Compress Message"
				 (string :format "%v")
				 (const :tag "No Message" nil))
			 (choice :tag "Compress Program"
				 (string)
				 (const :tag "None" nil))
			 (repeat :tag "Compress Arguments" string)
			 (choice :tag "Uncompress Message"
				 (string :format "%v")
				 (const :tag "No Message" nil))
			 (choice :tag "Uncompress Program"
				 (string)
				 (const :tag "None" nil))
			 (repeat :tag "Uncompress Arguments" string)
			 (boolean :tag "Append")
			 (boolean :tag "Strip Extension")
			 (string :tag "Magic Bytes")
			 (choice :tag "Uncompress Function"
				 (symbol)
				 (const :tag "None" nil))))
  :set 'jka-compr-set
  :version "28.1"			; add uncompress-function
  :group 'jka-compr)

(defcustom jka-compr-mode-alist-additions
  '(("\\.tgz\\'" . tar-mode)
    ("\\.tbz2?\\'" . tar-mode)
    ("\\.txz\\'" . tar-mode)
    ("\\.tzst\\'" . tar-mode))
  "List of pairs added to `auto-mode-alist' when installing jka-compr.
Uninstalling jka-compr removes all pairs from `auto-mode-alist' that
installing added.

If you set this outside Custom while Auto Compression mode is
already enabled \(as it is by default), you have to call
`jka-compr-update' after setting it to properly update other
variables.  Setting this through Custom does that automatically."
  :type '(repeat (cons string symbol))
  :version "24.4"			; add txz
  :set 'jka-compr-set
  :group 'jka-compr)

(defcustom jka-compr-load-suffixes '(".gz")
  "List of compression related suffixes to try when loading files.
Enabling Auto Compression mode appends this list to `load-file-rep-suffixes',
which see.  Disabling Auto Compression mode removes all suffixes
from `load-file-rep-suffixes' that enabling added.

If you set this outside Custom while Auto Compression mode is
already enabled \(as it is by default), you have to call
`jka-compr-update' after setting it to properly update other
variables.  Setting this through Custom does that automatically."
  :type '(repeat string)
  :set 'jka-compr-set
  :group 'jka-compr)

(define-minor-mode auto-compression-mode
  "Toggle Auto Compression mode.

Auto Compression mode is a global minor mode.  When enabled,
compressed files are automatically uncompressed for reading, and
compressed when writing."
  :global t :init-value t :group 'jka-compr :version "22.1"
  (let* ((installed (jka-compr-installed-p))
	 (flag auto-compression-mode))
    (cond
     ((and flag installed) t)		; already installed
     ((and (not flag) (not installed)) nil) ; already not installed
     (flag (jka-compr-install))
     (t (jka-compr-uninstall)))))

(defmacro with-auto-compression-mode (&rest body)
  "Evaluate BODY with automatic file compression and uncompression enabled."
  (declare (indent 0))
  (let ((already-installed (make-symbol "already-installed")))
    `(let ((,already-installed auto-compression-mode))
       (unwind-protect
	   (progn
	     (unless ,already-installed
	       (auto-compression-mode 1))
	     ,@body)
	 (unless ,already-installed
	   (auto-compression-mode -1))))))

;; This is what we need to know about jka-compr-handler
;; in order to decide when to call it.

(put 'jka-compr-handler 'safe-magic t)
(put 'jka-compr-handler 'operations '(byte-compiler-base-file-name
				      write-region insert-file-contents
				      file-local-copy load))

;; Turn on the mode.
(when auto-compression-mode (auto-compression-mode 1))

(provide 'jka-cmpr-hook)

;;; jka-cmpr-hook.el ends here
