;;; agent-review.el --- Atomic reviews of a branch's changes -*- lexical-binding: t; -*-

;;; Commentary:

;; An agent splits the committed changes of a branch into atomic review items,
;; one intent each.  Emacs pins the diff, checks that the items cover every
;; changed line exactly once, and shows them in a review buffer with a
;; sidebar of its items.  The user selects lines there and writes an
;; annotation, which goes straight to the session that made the review with
;; the selected code; the agent's answers appear under the annotations.
;;
;; The agent-ui methods are
;;   review_snapshot  pin base and head, list the hunks to plan with
;;   review_build     assemble the agent's plan, check coverage, show the review
;;   review_comments  read the user's annotations
;;   review_reply     answer an annotation in the review buffer
;; Git runs in the caller's project root through its file handler, so remote
;; (tramp-rpc) projects need nothing installed on their host.  Snapshots,
;; reviews and annotations are Lisp data under `agent-review-directory'.
;;
;; Keys in a review: a annotates the selected lines (or the line at point, or
;; edits the annotation at point) in a buffer where C-c C-c sends it, d
;; deletes an annotation, r marks the item reviewed, o shows the sidebar, C
;; lists the annotations, TAB folds an item or a file, n / p move between
;; items, ] / [ between annotations, RET visits the line, + / - show more or
;; less context, f toggles the full diff, g redraws, q quits.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'diff-mode)
(require 'agent-session)
(require 'agent-ui)
(require 'agent-canvas)

(declare-function my/var "init-base")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-server-capable "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot--async-request "eglot")
(declare-function eglot--TextDocumentPositionParams "eglot")
(declare-function eglot--hover-info "eglot")

(defgroup agent-review nil
  "Atomic reviews of a branch's changes."
  :group 'agent-ui
  :prefix "agent-review-")

(defcustom agent-review-directory
  (if (fboundp 'my/var) (my/var "reviews/") (locate-user-emacs-file "var/reviews/"))
  "Directory holding review snapshots, reviews and annotations."
  :type 'directory)

(defcustom agent-review-inline-fragments 100000
  "Largest zero-context diff, in characters, review_snapshot returns inline.
Agents read larger diffs with git themselves."
  :type 'integer)

(defcustom agent-review-unhighlighted-modes
  '(image-mode archive-mode tar-mode hexl-mode doc-view-mode)
  "Major modes never used to highlight diff lines."
  :type '(repeat symbol))

(defconst agent-review-types
  '((0 . "格式调整") (1 . "重构") (2 . "新功能") (3 . "局部修复") (5 . "测试修改"))
  "Item types: the number an agent gives and the label shown.")

(defconst agent-review-statuses
  '(("open" . "待回应") ("responded" . "已回应") ("resolved" . "已解决"))
  "Annotation statuses and their labels.")

;;; Faces

(defface agent-review-title '((t :inherit agent-canvas-title))
  "Review title.")
(defface agent-review-heading '((t :inherit agent-canvas-h2))
  "Section heading.")
(defface agent-review-item '((t :inherit agent-canvas-h2 :extend t))
  "Item heading.")
(defface agent-review-meta '((t :inherit shadow))
  "Secondary information.")
(defface agent-review-file '((t :inherit diff-file-header :extend t))
  "File name above its hunks.")
(defface agent-review-hunk '((t :inherit diff-hunk-header :extend t))
  "Hunk header.")
(defface agent-review-added '((t :inherit diff-added :extend t))
  "Added line.")
(defface agent-review-removed '((t :inherit diff-removed :extend t))
  "Removed line.")
(defface agent-review-line-number '((t :inherit line-number))
  "Line numbers of diff lines.")
(defface agent-review-comment '((t :inherit font-lock-warning-face))
  "A user annotation.")
(defface agent-review-response '((t :inherit font-lock-doc-face))
  "The agent's answer to an annotation.")

(defface agent-review-type-format
  '((((background dark)) :background "#3a3a3a" :foreground "#c8c8c8" :extend t)
    (t :background "#e6e6e6" :foreground "#505050" :extend t))
  "Type tag of a formatting item.")
(defface agent-review-type-refactor
  '((((background dark)) :background "#1e3050" :foreground "#a9c6f5" :extend t)
    (t :background "#dce8fb" :foreground "#1f4f99" :extend t))
  "Type tag of a refactoring item.")
(defface agent-review-type-feature
  '((((background dark)) :background "#1f3f2a" :foreground "#9fe0b2" :extend t)
    (t :background "#d6f0dc" :foreground "#1d6b33" :extend t))
  "Type tag of a feature item.")
(defface agent-review-type-fix
  '((((background dark)) :background "#4a3218" :foreground "#f3c58f" :extend t)
    (t :background "#fde3c6" :foreground "#8a4b08" :extend t))
  "Type tag of a local fix item.")
(defface agent-review-type-test
  '((((background dark)) :background "#33244a" :foreground "#d2b6f2" :extend t)
    (t :background "#ece0f8" :foreground "#5b2f8a" :extend t))
  "Type tag of a test item.")

(defconst agent-review-type-faces
  '((0 . agent-review-type-format) (1 . agent-review-type-refactor)
    (2 . agent-review-type-feature) (3 . agent-review-type-fix) (5 . agent-review-type-test))
  "Face of the type tag of each item type.")

(defun agent-review--type-tag (type &optional base)
  "The type tag of item TYPE, its background telling the type apart.
BASE is a face to keep under it, such as the heading's."
  (propertize (format " %s " (alist-get type agent-review-types))
              'face (delq nil (list (alist-get type agent-review-type-faces) base))))

(defun agent-review--item-label (item &optional base)
  "\"N. TITLE\" and the type tag of ITEM, the label shown for it.
BASE is the face of the label."
  (concat (propertize (format "%d. %s  " (plist-get item :order) (plist-get item :title))
                      'face base)
          (agent-review--type-tag (plist-get item :type) base)))

;;; Git

(defconst agent-review--git-config
  ;; With diff.suppressBlankEmpty, git prints empty context lines without
  ;; their leading space, which the hunk counts would not match.
  '("-c" "core.quotepath=false" "-c" "diff.suppressBlankEmpty=false")
  "Configuration every git command of a review runs with.
It overrides user settings that change the diff format parsed here.")

(defun agent-review--git (root &rest args)
  "Run git with ARGS in ROOT and return its standard output.
Signal an error with git's message when it fails."
  (let ((default-directory root)
        (stderr (make-temp-file "agent-review-git")))
    (unwind-protect
        (with-temp-buffer
          (let* ((coding-system-for-read 'utf-8-unix)
                 (status (apply #'process-file "git" nil (list t stderr) nil
                                (append agent-review--git-config args))))
            (unless (eql status 0)
              (error "git %s failed: %s" (car args)
                     (string-trim (with-temp-buffer
                                    (insert-file-contents stderr)
                                    (buffer-string)))))
            (buffer-string)))
      (delete-file stderr))))

(defun agent-review--resolve (root ref)
  "The commit ID that REF names in ROOT."
  (string-trim (agent-review--git root "rev-parse" "--verify" "--end-of-options"
                                  (concat ref "^{commit}"))))

(defconst agent-review--diff-flags
  '("--no-ext-diff" "--no-textconv" "--no-color" "--find-renames"
    "--src-prefix=a/" "--dst-prefix=b/")
  "Flags of every diff a review is built from.")

(defun agent-review--diff (root base head context)
  "The diff from BASE to HEAD in ROOT, with CONTEXT lines around hunks."
  (apply #'agent-review--git root "diff"
         (append agent-review--diff-flags
                 (list (format "--unified=%d" context) base head "--"))))

(defun agent-review--diff-command (base head)
  "Shell command that prints the hunks of BASE..HEAD as a snapshot numbers them."
  (string-join (append '("git") agent-review--git-config '("diff")
                       agent-review--diff-flags
                       (list "--unified=0" base head "--"))
               " "))

(defconst agent-review--source-limit (* 2 1024 1024)
  "Largest file, in bytes, whose text a review keeps for context.")

(defun agent-review--source-text (bytes)
  "BYTES of a file decoded as UTF-8, or nil for binary and non-UTF-8 files.
Text with U+FFFD is left out too: a file handler that decodes lossily
puts it in place of invalid bytes, and context must not show wrong text."
  (when (and (<= (length bytes) agent-review--source-limit)
             (not (string-search "\0" bytes)))
    (let ((text (decode-coding-string bytes 'utf-8-unix t)))
      ;; Invalid UTF-8 decodes to raw-byte characters.
      (unless (or (string-match-p (format "[%c-%c]" #x3fff80 #x3fffff) text)
                  (string-search (string #xfffd) text))
        text))))

(defun agent-review--cat-file (root input &rest args)
  "Output of git cat-file ARGS in ROOT, reading object names from INPUT."
  (let ((default-directory root)
        (coding-system-for-read 'utf-8-emacs-unix))
    (with-temp-buffer
      (unless (eql 0 (apply #'process-file "git" input (list t nil) nil "cat-file" args))
        (error "git cat-file failed"))
      ;; Some file handlers (tramp-rpc) decode the output whatever coding is
      ;; asked for, so turn it back into bytes before using the byte sizes
      ;; git reports.
      (if enable-multibyte-characters
          (encode-coding-string (buffer-string) 'utf-8-emacs-unix)
        (buffer-string)))))

(defun agent-review--small-files (root head files)
  "Those of FILES at commit HEAD in ROOT that exist and fit the source limit.
Asking git for the sizes first keeps large files from being read at all."
  (let ((input (make-temp-file "agent-review-batch")))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (mapconcat (lambda (file) (format "%s:%s\n" head file)) files "")
                        nil input nil 'silent)
          (let ((lines (split-string (agent-review--cat-file root input "--batch-check") "\n")))
            (cl-loop for file in files
                     for line in lines
                     when (and (string-match "\\`[0-9a-f]+ blob \\([0-9]+\\)\\'" line)
                               (<= (string-to-number (match-string 1 line))
                                   agent-review--source-limit))
                     collect file)))
      (delete-file input))))

(defun agent-review--cat-files (root head files)
  "The bytes of FILES at commit HEAD in ROOT read by one git cat-file.
Return a list of (FILE . BYTES), BYTES nil for a missing file, or nil
when the output cannot be split exactly, which happens when a file
handler decodes it lossily."
  (let ((default-directory root)
        (input (make-temp-file "agent-review-batch")))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (mapconcat (lambda (file) (format "%s:%s\n" head file)) files "")
                        nil input nil 'silent)
          (let ((out (agent-review--cat-file root input "--batch"))
                (pos 0) result)
            (catch 'lossy
              (dolist (file files)
                (cond
                 ((eq (string-match "[0-9a-f]+ blob \\([0-9]+\\)\n" out pos) pos)
                  (let* ((start (match-end 0))
                         (end (+ start (string-to-number (match-string 1 out)))))
                    (unless (and (< end (length out)) (eq (aref out end) ?\n))
                      (throw 'lossy nil))
                    (push (cons file (substring out start end)) result)
                    (setq pos (1+ end))))
                 ((eq (string-match "[^\n]* missing\n" out pos) pos)
                  (push (cons file nil) result)
                  (setq pos (match-end 0)))
                 (t (throw 'lossy nil))))
              ;; Every byte must belong to an object, or the sizes lied.
              (unless (= pos (length out)) (throw 'lossy nil))
              (nreverse result))))
      (delete-file input))))

(defun agent-review--sources (root head files)
  "The text of FILES at commit HEAD in ROOT, as an alist (FILE . TEXT).
Binary files, files that are not UTF-8 and files larger than
`agent-review--source-limit' are left out."
  (when-let* ((files (and files (agent-review--small-files root head files))))
    (seq-keep (lambda (entry)
                (when-let* ((bytes (cdr entry))
                            (text (agent-review--source-text bytes)))
                  (cons (car entry) text)))
              (or (agent-review--cat-files root head files)
                  ;; One git show per file, slower but immune to decoding.
                  (mapcar (lambda (file)
                            (cons file
                                  (ignore-errors
                                    (encode-coding-string
                                     (agent-review--git root "show" (format "%s:%s" head file))
                                     'utf-8-unix))))
                          files)))))

(defun agent-review--old-files (blocks)
  "Base-side paths of the file BLOCKS with hunks that exist at the base."
  (seq-keep (lambda (block)
              (and (plist-get block :hunks)
                   (not (string-search "\n--- /dev/null" (plist-get block :header)))
                   (plist-get block :old-file)))
            blocks))

;;; Diff parsing

(defun agent-review--split-before (regexp text)
  "Split TEXT before every line that starts with REGEXP."
  (let ((starts (list 0)) (pos 0))
    (while (string-match (concat "^" regexp) text (1+ pos))
      (setq pos (match-beginning 0))
      (push pos starts))
    (cl-loop for (start end) on (nreverse starts)
             collect (substring text start end))))

(defun agent-review--header-value (header regexp)
  "The rest of the line of HEADER that starts with REGEXP and a space, or nil.
Quoted paths, which git uses for control characters, are not supported."
  (when (string-match (concat "^" regexp " \\(.+\\)$") header)
    (let ((value (string-remove-suffix "\t" (match-string 1 header))))
      (when (string-prefix-p "\"" value)
        (error "Quoted or control-character paths are not supported: %s" value))
      value)))

(defun agent-review--prefixed-path (header marker)
  "The path on the MARKER line (--- or +++) of HEADER without its a/ or b/.
nil when the line is missing or names /dev/null."
  (when-let* ((path (agent-review--header-value header marker))
              ((not (equal path "/dev/null"))))
    (unless (member (substring path 0 (min 2 (length path))) '("a/" "b/"))
      (error "Unexpected path in the diff header: %s" path))
    (substring path 2)))

(defun agent-review--file-paths (header)
  "The (NEW . OLD) paths of the file whose diff starts with HEADER.
OLD differs from NEW for renames and copies; for an added or deleted
file both are the path that exists."
  (let ((new (agent-review--prefixed-path header "\\+\\+\\+"))
        (old (agent-review--prefixed-path header "---")))
    (if (or new old)
        (cons (or new old) (or old new))
      ;; No ---/+++ lines: a rename or mode change without edits, or a
      ;; binary file.  Renames and copies name both paths unambiguously.
      (if-let* ((to (agent-review--header-value header "\\(?:rename\\|copy\\) to")))
          (cons to (or (agent-review--header-value header "\\(?:rename\\|copy\\) from") to))
        ;; Otherwise "diff --git a/P b/P" names one path twice; split it in
        ;; the middle, since P itself may contain " b/".
        (let* ((line (substring header 0 (string-search "\n" header)))
               (rest (and (string-prefix-p "diff --git a/" line) (substring line 13)))
               (half (and rest (/ (- (length rest) 3) 2))))
          (if (and rest (>= half 0) (= (length rest) (+ (* 2 half) 3))
                   (equal (substring rest half (+ half 3)) " b/")
                   (equal (substring rest 0 half) (substring rest (+ half 3))))
              (let ((path (substring rest 0 half))) (cons path path))
            (error "Unsupported file header: %s" line)))))))

(defun agent-review--split-files (text)
  "Split the Git diff TEXT into a list of (:file :old-file :header :hunks).
FILE is the path at head, OLD-FILE the path at the base."
  (unless (string-empty-p text)
    (unless (string-prefix-p "diff --git " text)
      (error "Expected a Git unified diff"))
    (mapcar (lambda (block)
              (let* ((sections (agent-review--split-before "@@ " block))
                     (paths (agent-review--file-paths (car sections))))
                (list :file (car paths) :old-file (cdr paths)
                      :header (car sections)
                      :hunks (cdr sections))))
            (agent-review--split-before "diff --git " text))))

(defun agent-review--hunk-range (hunk)
  "The (OLD OLD-COUNT NEW NEW-COUNT) of HUNK's header."
  (let ((header (substring hunk 0 (string-search "\n" hunk))))
    (if (string-match "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \
\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@" header)
        (mapcar (lambda (n)
                  (if-let* ((s (match-string n header))) (string-to-number s) 1))
                '(1 2 3 4))
      (error "Malformed hunk: %s" header))))

(defun agent-review--hunk-lines (file hunk)
  "The lines of HUNK of FILE: a list of (:file :kind :content :old :new :newline).
KIND is ?+, ?- or ?\\s; OLD and NEW are line numbers, nil on the side a
line is not on.  Signal an error if the hunk's line counts are wrong."
  (let* ((lines (split-string hunk "\n"))
         (header (car lines))
         (counts (agent-review--hunk-range hunk))
         (old (nth 0 counts)) (new (nth 2 counts))
         (seen-old 0) (seen-new 0) last records)
    (dolist (line (cdr lines))
      (cond
       ((string-empty-p line))          ; after the final newline
       ((string-prefix-p "\\ No newline at end of file" line)
        (when last (plist-put last :newline nil)))
       (t
        (let ((kind (aref line 0)))
          (unless (memq kind '(?+ ?- ?\s)) (error "Malformed hunk line: %s" line))
          (setq last (list :file file :kind kind :content (substring line 1)
                           :old (unless (eq kind ?+) old)
                           :new (unless (eq kind ?-) new)
                           :newline t))
          (push last records)
          (unless (eq kind ?+) (cl-incf old) (cl-incf seen-old))
          (unless (eq kind ?-) (cl-incf new) (cl-incf seen-new))))))
    (unless (and (= seen-old (nth 1 counts)) (= seen-new (nth 3 counts)))
      (error "Hunk length mismatch: %s" header))
    (nreverse records)))

(defun agent-review--lines (text)
  "The lines of all hunks of the diff TEXT, see `agent-review--hunk-lines'."
  (mapcan (lambda (block)
            (mapcan (lambda (hunk) (agent-review--hunk-lines (plist-get block :file) hunk))
                    (plist-get block :hunks)))
          (agent-review--split-files text)))

(defun agent-review--changes (text)
  "Count the changed lines of the diff TEXT.
Keys are (FILE KIND LINE CONTENT NEWLINE), LINE on the side of KIND."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (line (agent-review--lines text) counts)
      (let ((kind (plist-get line :kind)))
        (unless (eq kind ?\s)
          (cl-incf (gethash (list (plist-get line :file) kind
                                  (plist-get line (if (eq kind ?-) :old :new))
                                  (plist-get line :content) (plist-get line :newline))
                            counts 0)))))))

;;; Plans

(defun agent-review--select (block part)
  "The hunks of the file BLOCK that the plan PART selects."
  (let ((file (plist-get block :file))
        (header (plist-get block :header))
        (hunks (plist-get block :hunks))
        (keys (seq-filter (lambda (key) (plist-member part key))
                          '(:whole :hunks :added_lines))))
    (unless (= (length keys) 1)
      (error "A part of %s must select exactly one of whole, hunks, added_lines" file))
    (pcase (car keys)
      (:whole
       (unless (eq (plist-get part :whole) t) (error "whole must be true (%s)" file))
       hunks)
      (:hunks
       (let ((indexes (append (plist-get part :hunks) nil)))
         (unless (and indexes
                      (seq-every-p (lambda (i) (and (natnump i) (< i (length hunks)))) indexes))
           (error "Invalid hunk indexes for %s (it has %d hunks): %S"
                  file (length hunks) indexes))
         (mapcar (lambda (i) (nth i hunks)) (sort indexes #'<))))
      (:added_lines
       (let* ((range (append (plist-get part :added_lines) nil))
              (start (car range)) (end (cadr range)))
         (unless (and (string-search "--- /dev/null\n" header) (= (length hunks) 1))
           (error "added_lines needs a newly added text file: %s" file))
         (let ((lines (agent-review--hunk-lines file (car hunks))))
           (unless (and (= (length range) 2) (integerp start) (integerp end)
                        (<= 1 start end (length lines)))
             (error "Invalid added_lines range for %s (it has %d lines): %S"
                    file (length lines) range))
           (let ((selected (seq-subseq lines (1- start) end)))
             (list (concat (format "@@ -0,0 +%d,%d @@\n" start (length selected))
                           (mapconcat (lambda (line)
                                        (concat "+" (plist-get line :content) "\n"
                                                (unless (plist-get line :newline)
                                                  "\\ No newline at end of file\n")))
                                      selected ""))))))))))

(defun agent-review--assemble (snapshot items)
  "Turn the planned ITEMS of SNAPSHOT into review items with exact diffs."
  (let ((blocks (plist-get snapshot :files))
        (order 0))
    (mapcar
     (lambda (item)
       (let ((title (plist-get item :title))
             (type (plist-get item :type))
             pieces)
         (unless (and (stringp title) (not (string-blank-p title))
                      (stringp (plist-get item :intent))
                      (not (string-blank-p (plist-get item :intent)))
                      (assq type agent-review-types))
           (error "Each item needs title, intent and type (0, 1, 2, 3 or 5): %S" title))
         (when (seq-empty-p (plist-get item :parts))
           (error "Item %s has no parts" title))
         (seq-doseq (part (plist-get item :parts))
           (let* ((file (plist-get part :file))
                  (block (or (seq-find (lambda (b) (equal (plist-get b :file) file)) blocks)
                             (error "No file %s in the snapshot" file)))
                  (selected (agent-review--select block part))
                  (piece (assoc file pieces)))
             (cond ((null piece) (push (list file block selected) pieces))
                   ((plist-get block :hunks)
                    (setcar (cddr piece) (append (nth 2 piece) selected)))
                   (t (error "Metadata-only file %s selected twice in item %s" file title)))))
         (setq pieces (nreverse pieces))
         (list :id (format "atomic-%d" (cl-incf order))
               :order order
               :title (string-trim title)
               :intent (string-trim (plist-get item :intent))
               :type type
               :files (mapcar #'car pieces)
               ;; Hunks in file order, so context can be shown between them.
               :diff (mapconcat (lambda (piece)
                                  (apply #'concat (plist-get (nth 1 piece) :header)
                                         (sort (nth 2 piece)
                                               :key (lambda (hunk)
                                                      (nth 2 (agent-review--hunk-range hunk))))))
                                pieces ""))))
     items)))

(defun agent-review--validate (full items)
  "Check that ITEMS cover every changed line of the diff FULL exactly once.
Return the statistics shown in the review; signal an error naming the gaps."
  (let ((originals (make-hash-table :test #'equal))
        (covered (make-hash-table :test #'equal))
        (metadata (make-hash-table :test #'equal))
        (files (agent-review--split-files full))
        (seen nil))
    (dolist (block files)
      (puthash (plist-get block :file) block originals))
    (dolist (item items)
      (let ((blocks (agent-review--split-files (plist-get item :diff))))
        (unless blocks (error "Item %s has no file diff" (plist-get item :title)))
        (dolist (block blocks)
          (let* ((file (plist-get block :file))
                 (original (gethash file originals)))
            (unless (and original (equal (plist-get block :header) (plist-get original :header)))
              (error "Unknown or changed file header: %s" file))
            (cl-pushnew file seen :test #'equal)
            (unless (plist-get original :hunks)
              (when (plist-get block :hunks)
                (error "Invented hunk for a binary or metadata-only file: %s" file))
              (cl-incf (gethash file metadata 0))))))
      (maphash (lambda (key n) (cl-incf (gethash key covered 0) n))
               (agent-review--changes (plist-get item :diff))))
    (let ((expected (agent-review--changes full))
          (missing nil) (extra nil) (additions 0) (deletions 0))
      (maphash (lambda (key n)
                 (when (> n (gethash key covered 0)) (push key missing))
                 (if (eq (nth 1 key) ?+) (cl-incf additions n) (cl-incf deletions n)))
               expected)
      (maphash (lambda (key n) (when (> n (gethash key expected 0)) (push key extra)))
               covered)
      (let ((uncovered (seq-remove (lambda (b) (member (plist-get b :file) seen)) files))
            (bad-metadata (seq-filter (lambda (b)
                                        (and (null (plist-get b :hunks))
                                             (/= (gethash (plist-get b :file) metadata 0) 1)))
                                      files))
            (show (lambda (keys)
                    (mapconcat (lambda (key)
                                 (format "%s:%c%d" (nth 0 key) (nth 1 key) (nth 2 key)))
                               (seq-take (sort keys) 8) ", "))))
        (when (or missing extra uncovered bad-metadata)
          (error "Coverage failed: %d changed lines missing (%s), %d extra or duplicated (%s), \
files not covered: %s, metadata-only files not selected exactly once: %s"
                 (length missing) (funcall show missing)
                 (length extra) (funcall show extra)
                 (mapconcat (lambda (b) (plist-get b :file)) uncovered ", ")
                 (mapconcat (lambda (b) (plist-get b :file)) bad-metadata ", "))))
      (list :files (length files) :items (length items)
            :additions additions :deletions deletions))))

;;; Storage

(defun agent-review--path (&rest names)
  "File NAMES joined under `agent-review-directory'."
  (expand-file-name (string-join names "/") agent-review-directory))

(defun agent-review--hash (object)
  "A short stable hash of the Lisp OBJECT."
  (let ((print-length nil) (print-level nil))
    (substring (secure-hash 'sha256 (encode-coding-string (prin1-to-string object)
                                                          'utf-8-emacs-unix))
               0 16)))

(defun agent-review--write (file data)
  "Write the Lisp DATA to FILE, replacing it atomically."
  (make-directory (file-name-directory file) t)
  ;; A temporary file of its own beside FILE, so the rename is atomic and
  ;; two writers never share one.
  (let ((temp (make-temp-file (concat file ".")))
        (print-length nil) (print-level nil) (print-circle nil)
        (coding-system-for-write 'utf-8-emacs-unix))
    (unwind-protect
        (progn
          (with-temp-buffer
            (prin1 data (current-buffer))
            (write-region nil nil temp nil 'silent))
          (rename-file temp file t))
      (when (file-exists-p temp) (delete-file temp)))))

(defun agent-review--read (file)
  "The Lisp data in FILE, or nil if FILE does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-emacs-unix))
        (insert-file-contents file))
      (read (current-buffer)))))

(defun agent-review--load (id)
  "The review with ID."
  (or (agent-review--read (agent-review--path id "review.eld"))
      (error "No review %s" id)))

(defun agent-review--index ()
  "Summaries of all reviews, newest first: (:id :title :agent :root :created)."
  (agent-review--read (agent-review--path "index.eld")))

(defun agent-review--comments (id)
  "The annotations of the review with ID."
  (plist-get (agent-review--read (agent-review--path id "comments.eld")) :comments))

(defun agent-review--retired (id)
  "Last revisions of the deleted annotations of the review with ID: (ID . REV)."
  (plist-get (agent-review--read (agent-review--path id "comments.eld")) :retired))

(defun agent-review--save-comments (id comments &optional retired)
  "Store COMMENTS as the annotations of the review with ID.
RETIRED replaces the revisions kept for deleted annotations; nil keeps them."
  (agent-review--write (agent-review--path id "comments.eld")
                       (list :review id :comments comments
                             :retired (or retired (agent-review--retired id)))))

(defun agent-review--delete-comment (id comment)
  "Delete COMMENT from the review with ID, remembering its revision.
An annotation written again on the same lines gets the same ID; its
revision continues from here, so an answer to the deleted one is refused."
  (agent-review--save-comments
   id (remove comment (agent-review--comments id))
   (cons (cons (plist-get comment :id) (plist-get comment :revision))
         (assoc-delete-all (plist-get comment :id) (agent-review--retired id)))))

(defun agent-review--now ()
  "The current time as an ISO 8601 string."
  (format-time-string "%FT%T%z"))

;;; Snapshots and reviews

(defun agent-review-snapshot (root base head)
  "Pin the committed changes of HEAD against BASE in ROOT.
The diff runs from the merge base of the two.  Return the snapshot."
  (let* ((target (agent-review--resolve root base))
         (head-sha (agent-review--resolve root head))
         (base-sha (string-trim (agent-review--git root "merge-base" target head-sha)))
         (full (agent-review--diff root base-sha head-sha 3)))
    (when (string-empty-p full)
      (error "No committed changes between the merge base and %s" head))
    (agent-review--changes full)        ; fail early on a diff we cannot parse
    (let* ((zero (agent-review--diff root base-sha head-sha 0))
           ;; The same diff can come from other commits (after a rebase) or
           ;; another repository, so the pinned commits are part of its ID.
           (snapshot (list :id (agent-review--hash (list root base-sha head-sha full)) :root root
                           :target-ref base :target-sha target :base-sha base-sha
                           :head-ref head :head-sha head-sha
                           :full full :fragments zero
                           :files (agent-review--split-files zero))))
      (agent-review--write (agent-review--path "snapshots"
                                               (concat (plist-get snapshot :id) ".eld"))
                           snapshot)
      snapshot)))

(defun agent-review--load-snapshot (id)
  "The snapshot with ID, reconfirmed against its pinned commits."
  (let ((snapshot (or (agent-review--read (agent-review--path "snapshots" (concat id ".eld")))
                      (error "No snapshot %s; call review_snapshot first" id))))
    (unless (equal (agent-review--diff (plist-get snapshot :root) (plist-get snapshot :base-sha)
                                       (plist-get snapshot :head-sha) 3)
                   (plist-get snapshot :full))
      (error "Snapshot %s no longer matches its pinned commits; take a new one" id))
    snapshot))

(defun agent-review-build (snapshot summary items &optional title agent)
  "Build the review of SNAPSHOT from SUMMARY and the planned ITEMS.
TITLE defaults to the compared refs; AGENT is the session buffer name to
answer annotations.  Building the same plan again returns the existing
review, so its annotations are kept."
  (unless (and (stringp summary) (not (string-blank-p summary)))
    (error "summary is required: what the whole compared change achieves"))
  (when (seq-empty-p items) (error "No items"))
  (let* ((assembled (agent-review--assemble snapshot items))
         (full (plist-get snapshot :full))
         (stats (agent-review--validate full assembled))
         (id (agent-review--hash (list (plist-get snapshot :id) summary assembled)))
         (file (agent-review--path id "review.eld")))
    (or (when-let* ((review (agent-review--read file)))
          ;; Repair the index if writing it failed after the review.
          (unless (seq-find (lambda (e) (equal (plist-get e :id) id)) (agent-review--index))
            (agent-review--index-add review))
          review)
        (let ((review
               (list :id id
                     :title (or title (format "%s → %s" (plist-get snapshot :head-ref)
                                              (plist-get snapshot :target-ref)))
                     :root (plist-get snapshot :root) :agent agent :created (agent-review--now)
                     :snapshot (plist-get snapshot :id)
                     :target-ref (plist-get snapshot :target-ref)
                     :target-sha (plist-get snapshot :target-sha)
                     :base-sha (plist-get snapshot :base-sha)
                     :head-ref (plist-get snapshot :head-ref)
                     :head-sha (plist-get snapshot :head-sha)
                     :summary (string-trim summary)
                     :items assembled
                     :full-files (mapcar (lambda (block)
                                           (list :file (plist-get block :file)
                                                 :diff (apply #'concat (plist-get block :header)
                                                              (plist-get block :hunks))))
                                         (agent-review--split-files full))
                     ;; Head-side text of the changed files, for context lines.
                     :sources (agent-review--sources
                               (plist-get snapshot :root) (plist-get snapshot :head-sha)
                               (seq-keep (lambda (block)
                                           (and (plist-get block :hunks)
                                                (not (string-search "\n+++ /dev/null"
                                                                    (plist-get block :header)))
                                                (plist-get block :file)))
                                         (plist-get snapshot :files)))
                     ;; Base-side text, to highlight removed lines.
                     :old-sources (agent-review--sources
                                   (plist-get snapshot :root) (plist-get snapshot :base-sha)
                                   (agent-review--old-files (plist-get snapshot :files)))
                     :stats stats)))
          (agent-review--write file review)
          (agent-review--index-add review)
          review))))

(defun agent-review--index-add (review)
  "Put REVIEW first in the index of reviews."
  (agent-review--write (agent-review--path "index.eld")
                       (cons (list :id (plist-get review :id) :title (plist-get review :title)
                                   :agent (plist-get review :agent)
                                   :root (plist-get review :root)
                                   :created (plist-get review :created))
                             (agent-review--index))))

(defun agent-review--item (review id)
  "The item with ID of REVIEW; \"full\" is the whole diff."
  (if (equal id "full")
      (list :id "full" :title "完整 diff"
            :diff (mapconcat (lambda (file) (plist-get file :diff))
                             (plist-get review :full-files) ""))
    (seq-find (lambda (item) (equal (plist-get item :id) id)) (plist-get review :items))))

;;; Annotations
;;
;; An annotation covers the lines the user selected in one file of one item,
;; and is shown below the last of them.  Writing one sends it straight to
;; the session that made the review, with the selected code.

(defun agent-review--line-key (target)
  "Key of the line TARGET, for finding the annotations shown below it."
  (list (plist-get target :item) (plist-get target :file)
        (plist-get target :side) (plist-get target :line)))

(defun agent-review--range-text (lines)
  "The line range LINES cover on each side, e.g. \"新 130-134\"."
  (string-join
   (delq nil
         (mapcar (lambda (side)
                   (when-let* ((numbers (seq-keep (lambda (line)
                                                    (and (eq (plist-get line :side) side)
                                                         (plist-get line :line)))
                                                  lines)))
                     (let ((low (apply #'min numbers)) (high (apply #'max numbers)))
                       (format "%s %s" (if (eq side 'new) "新" "旧")
                               (if (= low high) low (format "%d-%d" low high))))))
                 '(new old)))
   " · "))

(defun agent-review--comment-id (lines)
  "The ID of the annotation on LINES."
  (agent-review--hash (cons (plist-get (car lines) :item)
                            (cons (plist-get (car lines) :file)
                                  (mapcar (lambda (line)
                                            (list (plist-get line :side) (plist-get line :line)))
                                          lines)))))

(defun agent-review-annotate-lines (review lines text)
  "Store TEXT as the user's annotation on LINES of REVIEW; return it.
LINES are line targets of one file of one item, in order."
  (let* ((id (agent-review--comment-id lines))
         (item (plist-get (car lines) :item))
         (comments (agent-review--comments (plist-get review :id)))
         (previous (seq-find (lambda (c) (equal (plist-get c :id) id)) comments))
         ;; Continue from a deleted annotation on the same lines, so an
         ;; answer written for it does not land on this one.
         (revision (max (or (plist-get previous :revision) 0)
                        (alist-get id (agent-review--retired (plist-get review :id))
                                   0 nil #'equal)))
         (comment (list :id id :revision (1+ revision)
                        :item item
                        :item-title (plist-get (agent-review--item review item) :title)
                        :file (plist-get (car lines) :file)
                        :lines (mapcar (lambda (line)
                                         (list :side (plist-get line :side)
                                               :line (plist-get line :line)
                                               :kind (plist-get line :kind)
                                               :code (plist-get line :code)))
                                       lines)
                        :anchor (agent-review--line-key (car (last lines)))
                        :range (agent-review--range-text lines)
                        :code (mapconcat (lambda (line)
                                           (concat (string (plist-get line :kind))
                                                   (plist-get line :code)))
                                         lines "\n")
                        :comment text :status "open"
                        :response (plist-get previous :response)
                        :created (or (plist-get previous :created) (agent-review--now))
                        :updated (agent-review--now))))
    (agent-review--save-comments (plist-get review :id)
                                 (append (remove previous comments) (list comment)))
    comment))

(defun agent-review-reply (review-id id revision text &optional status)
  "Answer annotation ID of REVIEW-ID with TEXT.
REVISION is the revision the answer was written for; STATUS is
\"responded\" (the default) or \"resolved\"."
  (let* ((comments (agent-review--comments review-id))
         (comment (or (seq-find (lambda (c) (equal (plist-get c :id) id)) comments)
                      (error "No annotation %s in review %s" id review-id)))
         (status (or status "responded")))
    (unless (member status '("responded" "resolved"))
      (error "status must be responded or resolved"))
    (unless (equal revision (plist-get comment :revision))
      (error "The user edited annotation %s since (now revision %d); read it again with \
review_comments" id (plist-get comment :revision)))
    (let ((answered (append (list :response text :status status :responded (agent-review--now))
                            (cl-loop for (key value) on comment by #'cddr
                                     unless (memq key '(:response :status :responded))
                                     append (list key value)))))
      (agent-review--save-comments review-id
                                   (mapcar (lambda (c) (if (eq c comment) answered c)) comments))
      answered)))

(defun agent-review--message (review comment)
  "The message telling the agent about the annotation COMMENT of REVIEW.
Like the selection context IDE integrations send, it carries the selected
code and where it is, so the agent can answer without looking it up."
  (let ((item (agent-review--item review (plist-get comment :item))))
    (format "[原子审查%s] %s · %s
%s %s（base %s → head %s）
```diff
%s
```
%s

（review=%s，标注 id=%s，revision=%d。请直接调用 review_reply 回答，回答只写在审查里，不要在对话中再写一遍。）"
            (if (> (plist-get comment :revision) 1) "·修改标注" "·标注")
            (plist-get review :title)
            (if (equal (plist-get item :id) "full")
                "完整 diff"
              (format "第 %d 项「%s」" (plist-get item :order) (plist-get item :title)))
            (plist-get comment :file) (plist-get comment :range)
            (substring (plist-get review :base-sha) 0 10)
            (substring (plist-get review :head-sha) 0 10)
            (plist-get comment :code) (plist-get comment :comment)
            (plist-get review :id) (plist-get comment :id) (plist-get comment :revision))))

;;; Review state: items marked reviewed and folds, kept with the review

(defun agent-review--state (id)
  "The stored view state of the review with ID: (:reviewed :folded :folded-files)."
  (agent-review--read (agent-review--path id "state.eld")))

(defvar-local agent-review--review nil "The review shown in this buffer.")
(defvar-local agent-review--full nil "Non-nil to show the full diff instead of the items.")
(defvar-local agent-review--folded nil "IDs of the folded items.")
(defvar-local agent-review--folded-files nil "Folded files: a list of (ITEM . FILE).")
(defvar-local agent-review--reviewed nil "IDs of the items the user marked reviewed.")
(defvar-local agent-review--counts nil "(ANNOTATIONS . PENDING) of the review shown.")
(defvar-local agent-review--highlighted nil "Cache of highlighted hunks: text -> lines.")
(defvar-local agent-review--file-faces nil
  "Cache of whole files highlighted: (SIDE . PATH) -> vector of lines or nil.")
(defvar-local agent-review--context nil "Context lines shown around each hunk.")
(defvar-local agent-review--expanded nil
  "Lines shown in the gaps between hunks beyond the context.
A table from (ITEM FILE GAP) to (DOWN . UP): the lines shown below the
hunk above gap GAP and above the hunk below it.  Gap N is the one before
hunk N of the file, counting from 0; the last one is after its last hunk.")
(defvar-local agent-review--files nil
  "Per-file data of the review shown, see `agent-review--file-data'.")
(defvar-local agent-review--nav nil "The sidebar buffer of this review buffer.")
(defvar-local agent-review--checkout 'unknown
  "Worktree at the head of the review shown, or nil; `unknown' before looking.")
(defvar-local agent-review--source-buffers nil
  "Cache of the buffers visiting the head's files: file -> buffer or nil.")
(defvar-local agent-review--current nil "The item at point at the last command.")

(defun agent-review--save-state ()
  "Store the view state of this review buffer."
  (agent-review--write (agent-review--path (plist-get agent-review--review :id) "state.eld")
                       (list :reviewed agent-review--reviewed
                             :folded agent-review--folded
                             :folded-files agent-review--folded-files)))

(defun agent-review--load-state ()
  "Restore the view state of this review buffer.
A review opened for the first time shows only its first item unfolded."
  (let ((state (agent-review--state (plist-get agent-review--review :id))))
    (setq agent-review--reviewed (plist-get state :reviewed)
          agent-review--folded-files (plist-get state :folded-files)
          agent-review--folded
          (if state
              (plist-get state :folded)
            (mapcar (lambda (item) (plist-get item :id))
                    (cdr (plist-get agent-review--review :items)))))))

;; The workflow for agents is a skill, which replaces the atomic-review
;; skill that makes web page reviews.
(agent-session-add-skill "emacs-atomic-review" (locate-user-emacs-file "skills/emacs-atomic-review/")
                         "atomic-review")

;;; Review buffer

(defcustom agent-review-context 3
  "Lines of the file shown before and after each hunk of an item."
  :type 'natnum)

(defcustom agent-review-expand-lines 20
  "Lines one step of expanding a gap between hunks shows."
  :type 'natnum)

(defcustom agent-review-nav-width 40
  "Width of the review sidebar."
  :type 'natnum)

(defface agent-review-other '((t :inherit shadow :extend t))
  "Context line changed by another item.")
(defface agent-review-selected '((t :inherit region :extend t))
  "Lines an annotation is being written for.")
(defface agent-review-done '((t :inherit success))
  "Mark of an item the user reviewed.")
(defface agent-review-button '((t :inherit (agent-review-meta bold)))
  "Clickable part of the header line.")
(defface agent-review-current '((t :inherit highlight :extend t))
  "The sidebar entry of the item at point.")
(defface agent-review-brand '((t :weight bold :height 1.1))
  "Name at the top of the sidebar.
It does not inherit a heading face, which themes such as Leuven give a
background.")

(defun agent-review--file-data (review)
  "Index the head-side lines of each changed file of REVIEW.
Each entry is (:source VECTOR :added HASH :old HASH :ends LIST): the
file's lines, the new-side lines the whole diff adds, the old-side
numbers of its context lines, and the (NEW-END . OLD-END) of each hunk of
the full diff, last first."
  (let ((files (make-hash-table :test #'equal)))
    (pcase-dolist (`(,file . ,text) (plist-get review :sources))
      (let ((lines (split-string text "\n")))
        (when (equal (car (last lines)) "") (setq lines (butlast lines)))
        (puthash file (list :source (vconcat lines) :added (make-hash-table)
                            :old (make-hash-table) :ends nil)
                 files)))
    (dolist (block (plist-get review :full-files))
      (when-let* ((data (gethash (plist-get block :file) files)))
        (dolist (hunk (cdr (agent-review--split-before "@@ " (plist-get block :diff))))
          (pcase-let ((`(,old ,old-count ,new ,new-count) (agent-review--hunk-range hunk)))
            (plist-put data :ends (cons (cons (+ new new-count) (+ old old-count))
                                        (plist-get data :ends))))
          (dolist (line (agent-review--hunk-lines (plist-get block :file) hunk))
            (pcase (plist-get line :kind)
              (?+ (puthash (plist-get line :new) t (plist-get data :added)))
              (?\s (puthash (plist-get line :new) (plist-get line :old) (plist-get data :old))))))))
    files))

(defun agent-review--old-line (data new)
  "The old-side number of head-side line NEW of a file with DATA, or nil.
Lines the diff adds have none."
  (cond ((gethash new (plist-get data :added)) nil)
        ((gethash new (plist-get data :old)))
        ;; Outside the hunks of the full diff, a line keeps the offset of
        ;; the last hunk before it.
        (t (let ((end (seq-find (lambda (end) (<= (car end) new)) (plist-get data :ends))))
             (if end (+ new (- (cdr end) (car end))) new)))))

(defun agent-review--around (hunk source before after from limit)
  "Lines of SOURCE to show around HUNK, as (BEFORE-LINES . AFTER-LINES).
SOURCE is the vector of the file's head-side lines; BEFORE and AFTER are
how many lines above and below.  Only new-side lines from FROM and
before LIMIT are used, so context never repeats lines shown elsewhere in
the item."
  (pcase-let* ((`(,old ,old-count ,new ,new-count) (agent-review--hunk-range hunk))
               ;; The lines just before and after the hunk on each side.
               (old-prev (if (> old-count 0) (1- old) old))
               (new-prev (if (> new-count 0) (1- new) new))
               (old-next (1+ (if (> old-count 0) (+ old old-count -1) old)))
               (new-next (1+ (if (> new-count 0) (+ new new-count -1) new)))
               (line (lambda (n offset)
                       (list :kind ?\s :content (aref source (1- n)) :old (+ n offset)
                             :new n :newline t :context t))))
    (if (null source)
        (cons nil nil)
      (cons (cl-loop for n from (max 1 from (- new-prev before -1))
                     to (min new-prev (length source))
                     collect (funcall line n (- old-prev new-prev)))
            (cl-loop for n from (max from new-next)
                     to (min (length source) (+ new-next after -1) (1- limit))
                     collect (funcall line n (- old-next new-next)))))))

(defun agent-review--file-mode (file)
  "Major mode to highlight lines of FILE, or nil."
  (let ((mode (assoc-default file auto-mode-alist #'string-match)))
    (when (consp mode) (setq mode (car mode)))
    (when (and (symbolp mode) (fboundp 'major-mode-remap))
      (setq mode (major-mode-remap mode)))
    (and (symbolp mode) (fboundp mode)
         (not (memq mode agent-review-unhighlighted-modes))
         mode)))

(defun agent-review--highlight (file lines)
  "The contents of LINES of FILE with syntax faces, one string per line."
  (let* ((text (mapconcat (lambda (line) (plist-get line :content)) lines "\n"))
         (cache (or agent-review--highlighted
                    (setq agent-review--highlighted (make-hash-table :test #'equal))))
         (key (cons file text)))
    (or (gethash key cache)
        (puthash key
                 (let ((highlighted (split-string (agent-canvas--fontify
                                                   text (agent-review--file-mode file))
                                                  "\n")))
                   (if (= (length highlighted) (length lines))
                       highlighted
                     (mapcar (lambda (line) (plist-get line :content)) lines)))
                 cache))))

(defun agent-review--old-sources ()
  "Base-side text of the changed files of this buffer's review.
An alist (OLD-FILE . TEXT).  A review built before it was stored reads
it from git now, once, and keeps it with the review."
  (let ((review agent-review--review))
    (if (plist-member review :old-sources)
        (plist-get review :old-sources)
      (condition-case err
          (let* ((sources (agent-review--sources
                           (plist-get review :root) (plist-get review :base-sha)
                           (agent-review--old-files
                            (mapcan (lambda (file)
                                      (agent-review--split-files (plist-get file :diff)))
                                    (plist-get review :full-files)))))
                 (stored (plist-put (copy-sequence review) :old-sources sources)))
            (agent-review--write (agent-review--path (plist-get review :id) "review.eld") stored)
            (dolist (buffer (agent-review--buffers (plist-get review :id)))
              (with-current-buffer buffer (setq agent-review--review stored)))
            sources)
        ;; Without them removed lines are highlighted as fragments; try
        ;; again only in a new buffer.
        (error (message "读取 base 侧源码失败：%s" (error-message-string err))
               (setq agent-review--review (plist-put (copy-sequence review) :old-sources nil))
               nil)))))

(defun agent-review--file-lines (side path)
  "Lines of the file PATH on SIDE, `new' or `old', highlighted as a whole.
A vector of strings, or nil when the review does not keep that text."
  (let ((cache (or agent-review--file-faces
                   (setq agent-review--file-faces (make-hash-table :test #'equal))))
        (key (cons side path)))
    (pcase (gethash key cache 'missing)
      ('missing
       (puthash key
                (when-let* ((text (alist-get path (if (eq side 'new)
                                                      (plist-get agent-review--review :sources)
                                                    (agent-review--old-sources))
                                             nil nil #'equal)))
                  (let ((lines (split-string (agent-canvas--fontify
                                              text (agent-review--file-mode path))
                                             "\n")))
                    (when (equal (car (last lines)) "") (setq lines (butlast lines)))
                    (vconcat lines)))
                cache))
      (lines lines))))

(defun agent-review--line-codes (block lines)
  "The contents of LINES of the file BLOCK with syntax faces, one string each.
Each line is taken from its side of the file highlighted as a whole:
a hunk alone is often not valid code, and parsers that fail on it
highlight it wrongly or mark it as an error.  Lines whose file text the
review does not keep are highlighted together as a fragment instead."
  (let ((codes
         (mapcar (lambda (line)
                   (let* ((old (eq (plist-get line :kind) ?-))
                          (n (plist-get line (if old :old :new)))
                          (source (agent-review--file-lines
                                   (if old 'old 'new)
                                   (plist-get block (if old :old-file :file))))
                          (code (and source n (<= 1 n (length source))
                                     (aref source (1- n)))))
                     ;; Use it only if it is the very text of the line.
                     (and code (equal (substring-no-properties code) (plist-get line :content))
                          code)))
                 lines)))
    (if (seq-every-p #'identity codes)
        codes
      (cl-mapcar (lambda (code fragment) (or code fragment))
                 codes (agent-review--highlight (plist-get block :file) lines)))))

;; Review buffers don't wrap, so long code lines stay one line each.  Prose
;; (summary, intents, annotations, answers) is filled when drawn instead.

(defun agent-review--fill-width ()
  "Columns prose is filled to: the review window's width, at most 100."
  (min 100 (1- (if-let* ((window (get-buffer-window (current-buffer) t)))
                   (window-max-chars-per-line window)
                 81))))

(defun agent-review--fill (text &optional indent)
  "TEXT with each long line filled to `agent-review--fill-width'.
Line breaks are kept, and a list item's continuation lines are indented
under its text.  INDENT columns are taken by a prefix the caller puts
before every line."
  (let ((width (- (agent-review--fill-width) (or indent 0))))
    (mapconcat
     (lambda (line)
       (if (<= (string-width line) width)
           line
         (with-temp-buffer
           (insert line)
           (let ((fill-column width)
                 (fill-prefix
                  (progn (string-match "\\`[ \t]*\\(?:[-*+]\\|[0-9]+[.)]\\)?[ \t]*" line)
                         (make-string (string-width (match-string 0 line)) ?\s))))
             (fill-region (point-min) (point-max)))
           (buffer-string))))
     (split-string text "\n")
     "\n")))

(defun agent-review--insert-comment (comment)
  "Insert the annotation COMMENT and its answer below its last line."
  (let ((start (point))
        (bar (propertize "  ┃ " 'face 'agent-review-comment)))
    (insert bar
            (propertize (format "标注 · %s · %s" (or (plist-get comment :range) "")
                                (alist-get (plist-get comment :status)
                                           agent-review-statuses nil nil #'equal))
                        'face '(bold agent-review-comment))
            "\n")
    (dolist (line (split-string (agent-review--fill (plist-get comment :comment) 4) "\n"))
      (insert bar line "\n"))
    (when-let* ((response (plist-get comment :response)))
      (insert bar (propertize "agent 回应" 'face '(bold agent-review-response)) "\n")
      (dolist (line (split-string (agent-review--fill response 4) "\n"))
        (insert bar (propertize line 'face 'agent-review-response) "\n")))
    (when agent-review--shown (puthash (plist-get comment :id) t agent-review--shown))
    (put-text-property start (point) 'agent-review-comment (plist-get comment :id))))

(defun agent-review--gap-button (label direction)
  "Button LABEL that shows hidden lines of the gap it is on in DIRECTION."
  (propertize label 'face 'agent-review-button 'mouse-face 'highlight
              'help-echo "展开隐藏的行"
              'keymap (let ((map (make-sparse-keymap)))
                        (keymap-set map "<mouse-1>" (lambda (event)
                                                      (interactive "e")
                                                      (mouse-set-point event)
                                                      (agent-review--expand direction)))
                        (keymap-set map "RET" (lambda ()
                                                (interactive)
                                                (agent-review--expand direction)))
                        map)))

(defun agent-review--insert-gap (text gap)
  "Insert the line TEXT standing for GAP, with buttons to show its lines.
GAP is (KEY HIDDEN DIRECTIONS): KEY as in `agent-review--expanded', the
number of lines it hides and the directions, `up' and `down', it opens in."
  (pcase-let ((`(,key ,hidden ,directions) gap)
              (start (point)))
    (insert (propertize text 'face 'agent-review-hunk))
    (when (> hidden 0)
      (insert (propertize (format "  ⋯ 隐藏 %d 行 " hidden) 'face 'agent-review-hunk))
      (pcase-dolist (`(,label . ,direction)
                     (if (<= hidden agent-review-expand-lines)
                         (list (cons "展开" 'all))
                       (append (when (memq 'down directions)
                                 (list (cons (format "↓ %d" agent-review-expand-lines) 'down)))
                               (when (memq 'up directions)
                                 (list (cons (format "↑ %d" agent-review-expand-lines) 'up)))
                               (list (cons "全部" 'all)))))
        (insert (propertize " " 'face 'agent-review-hunk)
                (agent-review--gap-button (format "[%s]" label) direction))))
    (insert (propertize "\n" 'face 'agent-review-hunk))
    (add-text-properties start (point)
                         (list 'agent-review-gap key
                               'agent-review-gap-info (and (> hidden 0) (cons hidden directions))))))

(defvar agent-review--plain nil
  "While drawing an item, non-nil to leave its code without syntax faces.")

(defun agent-review--insert-hunk (item block hunk comments width around gap)
  "Insert HUNK of the file BLOCK in ITEM, with COMMENTS under their last lines.
COMMENTS maps a line key to the annotations ending there.  WIDTH is the
width of the line number columns; AROUND is the context to show, see
`agent-review--around'.  The hunk's header stands for GAP, the one above
it, see `agent-review--insert-gap'."
  (let* ((start (point))
         (file (plist-get block :file))
         (lines (append (car around) (agent-review--hunk-lines file hunk) (cdr around)))
         (codes (if agent-review--plain
                    (mapcar (lambda (line) (plist-get line :content)) lines)
                  (agent-review--line-codes block lines)))
         (data (gethash file agent-review--files))
         (added (plist-get data :added))
         (number (format "%%%ds %%%ds " width width)))
    ;; Context comes from the head-side file; other items' changes around
    ;; the hunk shift the old-side numbers, so take them from the full diff.
    (when data
      (dolist (line lines)
        (when (plist-get line :context)
          (plist-put line :old (agent-review--old-line data (plist-get line :new))))))
    (agent-review--insert-gap (car (split-string hunk "\n")) gap)
    (cl-loop
     for line in lines
     for code in codes
     do (let* ((kind (plist-get line :kind))
               (side (if (eq kind ?-) 'old 'new))
               (target (list :item (plist-get item :id) :file file :side side
                             :line (plist-get line (if (eq side 'old) :old :new))
                             :kind kind :code (plist-get line :content)
                             ;; Where an old-side line lives at the base,
                             ;; which differs for a renamed file.
                             :old-file (plist-get block :old-file)))
               (face (cond ((and (plist-get line :context) added
                                 (gethash (plist-get line :new) added))
                            'agent-review-other)
                           ((eq kind ?+) 'agent-review-added)
                           ((eq kind ?-) 'agent-review-removed)))
               (start (point)))
          (insert (propertize (format number (or (plist-get line :old) "")
                                      (or (plist-get line :new) ""))
                              'face 'agent-review-line-number))
          (let ((code-start (point)))
            (insert (string kind) code
                    (if (plist-get line :newline) ""
                      (propertize " ⏎ 文件末尾无换行" 'face 'agent-review-meta))
                    "\n")
            (when face (add-face-text-property code-start (point) face t))
            ;; Where the code starts in the line, past the numbers and the mark.
            (put-text-property start (point) 'agent-review-code-column
                               (- (1+ code-start) start)))
          (put-text-property start (point) 'agent-review-target target)
          (dolist (comment (gethash (agent-review--line-key target) comments))
            (agent-review--insert-comment comment))))
    (put-text-property start (point) 'agent-review-hunk (car gap))))

(defun agent-review--fold-overlay (start property id folded)
  "Make the region from START to point foldable as ID under PROPERTY.
FOLDED says whether it starts folded."
  (let ((overlay (make-overlay start (point))))
    (overlay-put overlay property id)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'invisible folded)
    (overlay-put overlay 'isearch-open-invisible #'agent-review--isearch-open)
    (when (and agent-review--plain (eq property 'agent-review-body))
      (overlay-put overlay 'agent-review-plain t))))

(defun agent-review--isearch-open (_overlay)
  "Unfold the item and file at point, where a search ended in a fold."
  (agent-review--reveal))

(defvar agent-review--shown nil
  "While drawing a review, the IDs of the annotations inserted so far.")

(defvar agent-review--all-comments nil
  "While drawing a review, all of its annotations.")

(defun agent-review--extended-header (header)
  "Lines of the file HEADER worth showing: modes, renames, similarity.
The diff --git, index and ---/+++ lines are left out."
  (seq-remove (lambda (line)
                (or (string-empty-p line)
                    (string-match-p "\\`\\(?:diff --git \\|index \\|--- \\|\\+\\+\\+ \\)" line)))
              (split-string header "\n")))

(defun agent-review--insert-item (item comments width)
  "Insert ITEM: its heading, intent and diff, with COMMENTS under their lines.
WIDTH is the width of the line number columns."
  (let ((id (plist-get item :id))
        (start (point)))
    (insert (if (equal id "full")
                (propertize "完整 diff\n" 'face 'agent-review-item 'agent-review-heading id)
              (concat (if (member id agent-review--reviewed)
                          (propertize "✓ " 'face '(agent-review-done agent-review-item))
                        (propertize "○ " 'face '(agent-review-meta agent-review-item)))
                      (agent-review--item-label item 'agent-review-item)
                      (propertize "\n" 'face 'agent-review-item))))
    ;; The whole heading bar takes the background of the item's type.
    (when-let* ((face (alist-get (plist-get item :type) agent-review-type-faces)))
      (add-face-text-property start (point) face t))
    (put-text-property start (point) 'agent-review-heading id)
    ;; Highlighting whole files is slow for large reviews, so a folded item
    ;; is drawn without syntax faces, to be searched, and highlighted when
    ;; it is first unfolded.
    (let ((agent-review--plain (agent-review--deferred-p id)))
      (agent-review--insert-body item comments width))
    (put-text-property start (point) 'agent-review-in id)))

(defun agent-review--deferred-p (id)
  "Whether item ID is folded and can wait to be highlighted until unfolded.
Items with annotations are drawn, so moving between annotations finds them."
  (and (member id agent-review--folded)
       (not (seq-find (lambda (c) (equal (plist-get c :item) id))
                      agent-review--all-comments))))

(defun agent-review--gap-shown (item file gap)
  "Lines of gap GAP of FILE in ITEM shown beyond the context, as (DOWN . UP)."
  (or (and agent-review--expanded
           (gethash (list item file gap) agent-review--expanded))
      '(0 . 0)))

(defun agent-review--insert-body (item comments width)
  "Insert the intent and diff of ITEM, foldable, with COMMENTS under their lines.
WIDTH is the width of the line number columns."
  (let ((id (plist-get item :id))
        (body (point)))
    (when-let* ((intent (plist-get item :intent)))
      (insert (agent-review--fill intent) "\n"))
    (dolist (block (agent-review--split-files (plist-get item :diff)))
      (let* ((file (plist-get block :file))
             (key (cons id file))
             (file-start (point))
             (source (plist-get (gethash file agent-review--files) :source))
             ;; The full diff has its own context.
             (context (if (equal id "full") 0 agent-review--context))
             (from 1))
        (insert "\n" (propertize (concat file "\n") 'face 'agent-review-file
                                 'agent-review-file-heading key))
        (let ((file-body (point)))
          (if (not (plist-get block :hunks))
              ;; Binary or metadata-only: show what git says about the file.
              (insert (propertize (string-join (cdr (split-string (plist-get block :header) "\n"))
                                               "\n")
                                  'face 'agent-review-meta))
            ;; A rename or mode change that comes with edits.
            (when-let* ((lines (agent-review--extended-header (plist-get block :header))))
              (insert (propertize (concat (string-join lines "\n") "\n")
                                  'face 'agent-review-meta)))
            (cl-loop
             for (hunk next) on (plist-get block :hunks)
             for index from 0
             do (pcase-let* ((`(,_ ,_ ,new ,count) (agent-review--hunk-range hunk))
                             (around (agent-review--around
                                      hunk source
                                      (+ context (cdr (agent-review--gap-shown id file index)))
                                      (+ context (car (agent-review--gap-shown id file (1+ index))))
                                      from
                                      (if next
                                          (pcase-let ((`(,_ ,_ ,new ,count)
                                                       (agent-review--hunk-range next)))
                                            (if (> count 0) new (1+ new)))
                                        most-positive-fixnum)))
                             ;; The lines from FROM to the hunk the context
                             ;; above it leaves out.
                             (hidden (if source
                                         (max 0 (- (min (if (> count 0) (1- new) new) (length source))
                                                   from -1 (length (car around))))
                                       0)))
                  (agent-review--insert-hunk item block hunk comments width around
                                             (list (list id file index) hidden
                                                   (if (zerop index) '(up) '(down up))))
                  (setq from (1+ (if (cdr around)
                                     (plist-get (car (last (cdr around))) :new)
                                   (if (> count 0) (+ new count -1) new))))))
            (when (and source (< from (1+ (length source))))
              (agent-review--insert-gap
               "" (list (list id file (length (plist-get block :hunks)))
                          (- (length source) from -1) '(down)))))
          (agent-review--fold-overlay file-body 'agent-review-file-body key
                                      (and (member key agent-review--folded-files) t)))
        (put-text-property file-start (point) 'agent-review-file-in key)))
    ;; Annotations on context lines the current context no longer shows
    ;; would otherwise be stored but nowhere to be seen.
    (when-let* ((hidden (seq-filter (lambda (c)
                                      (and (equal (plist-get c :item) id)
                                           (not (gethash (plist-get c :id) agent-review--shown))))
                                    agent-review--all-comments)))
      (insert "\n" (propertize "这些标注所在的行不在当前上下文里，按 + 显示更多上下文：\n"
                               'face 'agent-review-meta))
      (dolist (comment hidden)
        (insert (propertize (format "  %s\n" (plist-get comment :file)) 'face 'agent-review-meta))
        (agent-review--insert-comment comment)))
    (insert "\n")
    (agent-review--fold-overlay body 'agent-review-body id
                                (and (member id agent-review--folded) t))))

(defun agent-review--comments-by-line (comments)
  "COMMENTS in a table from the key of the line they end on, in order."
  (let ((by-line (make-hash-table :test #'equal)))
    (dolist (comment (reverse comments) by-line)
      (push comment (gethash (plist-get comment :anchor) by-line)))))

(defun agent-review--plain-p (id)
  "Whether item ID is drawn without syntax faces."
  (let ((overlay (seq-find (lambda (o) (equal (overlay-get o 'agent-review-body) id))
                           (overlays-in (point-min) (point-max)))))
    (or (null overlay) (overlay-get overlay 'agent-review-plain))))

(defun agent-review--redraw-item (id)
  "Redraw item ID in place, keeping each window on what it showed.
For changes within one item; the whole buffer takes much longer to draw.
Redraw it all if the item is not shown."
  (if-let* ((start (agent-review--find 'agent-review-in id)))
      (progn
        (agent-review--keeping-place
         (lambda ()
           (let* ((review agent-review--review)
                  (comments (agent-review--comments (plist-get review :id)))
                  (agent-review--shown (make-hash-table :test #'equal))
                  (agent-review--all-comments comments))
             (agent-review--count-comments comments)
             (delete-region start (next-single-property-change start 'agent-review-in nil
                                                               (point-max)))
             (goto-char start)
             (agent-review--insert-item (agent-review--item review id)
                                        (agent-review--comments-by-line comments)
                                        (agent-review--number-width review agent-review--files)))))
        (agent-review--note-reattach)
        (agent-review--nav-refresh))
    (agent-review--redraw)))

(defun agent-review--count-comments (comments)
  "Note how many of the review's COMMENTS there are, and how many are open."
  (setq agent-review--counts
        (cons (length comments)
              (seq-count (lambda (c) (equal (plist-get c :status) "open")) comments))))

(defun agent-review--number-width (review files)
  "Width of the line number columns of REVIEW, whose file data is FILES."
  (let ((largest 1))
    (maphash (lambda (_ data) (setq largest (max largest (length (plist-get data :source)))))
             files)
    (dolist (file (plist-get review :full-files))
      (dolist (hunk (cdr (agent-review--split-before "@@ " (plist-get file :diff))))
        (pcase-let ((`(,old ,old-count ,new ,new-count) (agent-review--hunk-range hunk)))
          (setq largest (max largest (+ old old-count) (+ new new-count))))))
    (max 3 (length (number-to-string largest)))))

(defun agent-review--render ()
  "Draw the review of this buffer."
  (let* ((review agent-review--review)
         (stats (plist-get review :stats))
         (comments (agent-review--comments (plist-get review :id)))
         (by-line (agent-review--comments-by-line comments))
         (items (if agent-review--full
                    (list (agent-review--item review "full"))
                  (plist-get review :items)))
         (files (or agent-review--files
                    (setq agent-review--files (agent-review--file-data review))))
         (width (agent-review--number-width review files)))
    (unless agent-review--context (setq agent-review--context agent-review-context))
    (agent-review--count-comments comments)
    (insert (propertize (plist-get review :title) 'face 'agent-review-title) "\n"
            (propertize (format "%s %s → %s %s · %d 个文件 · +%d −%d · %d 项\n"
                                (plist-get review :target-ref)
                                (substring (plist-get review :base-sha) 0 10)
                                (plist-get review :head-ref)
                                (substring (plist-get review :head-sha) 0 10)
                                (plist-get stats :files) (plist-get stats :additions)
                                (plist-get stats :deletions) (plist-get stats :items))
                        'face 'agent-review-meta)
            (propertize (agent-review--fill "选中代码行按 a 写标注，直接发给 agent · r 已审阅 · \
o 目录 · C 标注列表 · TAB 折叠 · { } 向上/向下展开代码 · f 切换视图 · RET 跳到代码")
                        'face 'agent-review-meta)
            "\n\n" (propertize "本次变更概览\n" 'face 'agent-review-heading)
            (agent-review--fill (plist-get review :summary)) "\n\n")
    (let ((agent-review--shown (make-hash-table :test #'equal))
          (agent-review--all-comments comments))
      (dolist (item items)
        (agent-review--insert-item item by-line width)))))

(defun agent-review--item-at (pos)
  "The item ID at POS, or nil."
  (get-text-property pos 'agent-review-in))

(defun agent-review--header-button (label command help)
  "Header line button LABEL running COMMAND when clicked, with HELP."
  (propertize label 'face 'agent-review-button 'mouse-face 'highlight
              'help-echo help
              'local-map (let ((map (make-sparse-keymap)))
                           (keymap-set map "<header-line> <mouse-1>"
                                       (lambda (event)
                                         (interactive "e")
                                         (with-selected-window (posn-window (event-start event))
                                           (call-interactively command))))
                           map)))

(defun agent-review--header-line ()
  "Contents of the header line of a review buffer."
  (let* ((items (plist-get agent-review--review :items))
         (ids (mapcar (lambda (item) (plist-get item :id)) items))
         (current (agent-review--item-at (point)))
         (item (and current (not agent-review--full)
                    (agent-review--item agent-review--review current))))
    (concat " "
            (agent-review--header-button " 目录 " #'agent-review-toggle-nav "显示或隐藏审查目录")
            " "
            (agent-review--header-button (if agent-review--full " 原子审查 " " 完整 diff ")
                                         #'agent-review-toggle-full "切换视图")
            " "
            (agent-review--header-button (format " 标注 %d · 待回应 %d "
                                                 (or (car agent-review--counts) 0)
                                                 (or (cdr agent-review--counts) 0))
                                         #'agent-review-list-annotations "列出全部标注")
            (propertize (format "  已审阅 %d/%d"
                                (length (seq-intersection agent-review--reviewed ids))
                                (length items))
                        'face 'agent-review-meta)
            (when item
              (propertize (format "  ·  %d. %s" (plist-get item :order) (plist-get item :title))
                          'face 'agent-review-meta)))))

(defconst agent-review--anchor-properties
  '(agent-review-comment agent-review-target agent-review-gap agent-review-file-heading
    agent-review-heading)
  "Text properties that identify what a position shows, most specific first.")

(defun agent-review--anchor (pos)
  "What the text at POS shows, to find the same place after a redraw.
Return (PROPERTY VALUE OFFSET): the annotation, code line, file or item
at POS and how far into it POS is, or (nil LINE COLUMN) elsewhere."
  (or (seq-some (lambda (property)
                  (when-let* ((value (get-text-property pos property)))
                    (let ((start (previous-single-property-change
                                  (min (1+ pos) (point-max)) property nil (point-min))))
                      (list property
                            (if (eq property 'agent-review-target)
                                (agent-review--line-key value)
                              value)
                            (- pos start)))))
                agent-review--anchor-properties)
      (save-excursion
        (goto-char pos)
        (list nil (line-number-at-pos) (current-column)))))

(defun agent-review--anchor-pos (anchor)
  "Where ANCHOR from `agent-review--anchor' is now, or nil if it is gone."
  (pcase-let ((`(,property ,value ,offset) anchor))
    (if (null property)
        (save-excursion
          (goto-char (point-min))
          (forward-line (1- value))
          (move-to-column offset)
          (point))
      (when-let* ((match (save-excursion
                           (goto-char (point-min))
                           (text-property-search-forward
                            property value
                            (if (eq property 'agent-review-target)
                                (lambda (key target)
                                  (and target (equal key (agent-review--line-key target))))
                              t)))))
        (min (+ (prop-match-beginning match) offset)
             (max (prop-match-beginning match) (1- (prop-match-end match))))))))

(defun agent-review--keeping-place (redraw)
  "Call REDRAW to redraw this buffer, keeping each window on what it showed.
Point goes back to where it was, or to the start of the buffer."
  (let ((here (agent-review--anchor (point)))
        (windows (mapcar (lambda (window)
                           (list window (agent-review--anchor (window-point window))
                                 (agent-review--anchor (window-start window))))
                         (get-buffer-window-list nil nil t)))
        (inhibit-read-only t))
    (funcall redraw)
    (goto-char (or (agent-review--anchor-pos here) (point-min)))
    (pcase-dolist (`(,window ,point ,start) windows)
      (when-let* ((pos (agent-review--anchor-pos start)))
        (set-window-start window (save-excursion (goto-char pos) (line-beginning-position)) t))
      (set-window-point window (or (agent-review--anchor-pos point) (point))))))

(defun agent-review--redraw ()
  "Redraw this review buffer, keeping each window on what it showed.
An answer inserted above point must not move point onto other code."
  (agent-review--keeping-place (lambda () (erase-buffer) (agent-review--render)))
  (agent-review--note-reattach)
  (agent-review--nav-refresh))

(defun agent-review--note-reattach ()
  "Highlight again the lines a note being written covers, after a redraw."
  (when-let* ((draft (get-buffer "*review-note*"))
              (note (buffer-local-value 'agent-review--note draft))
              ((eq (plist-get note :buffer) (current-buffer)))
              (overlay (plist-get note :overlay))
              (lines (plist-get note :lines))
              (first (agent-review--anchor-pos
                      (list 'agent-review-target (agent-review--line-key (car lines)) 0)))
              (last (agent-review--anchor-pos
                     (list 'agent-review-target (agent-review--line-key (car (last lines))) 0))))
    (move-overlay overlay
                  (save-excursion (goto-char first) (line-beginning-position))
                  (save-excursion (goto-char last) (line-beginning-position 2))
                  (current-buffer))))

(defun agent-review--buffers (id)
  "Live buffers showing the review with ID."
  (seq-filter (lambda (buffer)
                (equal (plist-get (buffer-local-value 'agent-review--review buffer) :id) id))
              (buffer-list)))

(defun agent-review--refresh (id &optional item)
  "Redraw every buffer showing the review with ID, or only its ITEM."
  (dolist (buffer (agent-review--buffers id))
    (with-current-buffer buffer
      (if item (agent-review--redraw-item item) (agent-review--redraw)))))

(defun agent-review-show (review)
  "Show REVIEW and its sidebar, without selecting them; return the buffer."
  (let ((buffer (or (car (agent-review--buffers (plist-get review :id)))
                    (generate-new-buffer (format "*review: %s*" (plist-get review :title))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-review-mode) (agent-review-mode))
      (setq agent-review--review review)
      (agent-review--load-state)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (agent-review--render))
      (goto-char (point-min)))
    (agent-ui--show-buffer buffer)
    (with-current-buffer buffer
      (agent-review--display-nav (agent-review--nav-buffer)))
    buffer))

;;; Folding and moving

(defun agent-review--find (property value)
  "Start of the text whose PROPERTY is VALUE, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward property value t)))
      (prop-match-beginning match))))

(defun agent-review--set-folded (id fold)
  "Fold item ID, or the file ID of the form (ITEM . FILE), when FOLD.
Unfold it otherwise; an item drawn without syntax faces is highlighted then."
  (let ((file (consp id)))
    (if file
        (setq agent-review--folded-files
              (if fold (cl-adjoin id agent-review--folded-files :test #'equal)
                (remove id agent-review--folded-files)))
      (setq agent-review--folded
            (if fold (cl-adjoin id agent-review--folded :test #'equal)
              (remove id agent-review--folded))))
    (if (and (not (or file fold)) (agent-review--plain-p id))
        (agent-review--redraw-item id)
      (when-let* ((overlay (seq-find (lambda (o)
                                       (equal (overlay-get o (if file 'agent-review-file-body
                                                               'agent-review-body))
                                              id))
                                     (overlays-in (point-min) (point-max)))))
        (overlay-put overlay 'invisible fold)))
    (agent-review--save-state)))

(defun agent-review--reveal ()
  "Unfold the item and file at point."
  (when-let* ((id (agent-review--item-at (point))))
    (when (member id agent-review--folded) (agent-review--set-folded id nil)))
  (when-let* ((file (get-text-property (point) 'agent-review-file-in)))
    (when (member file agent-review--folded-files) (agent-review--set-folded file nil))))

(defun agent-review-goto (id)
  "Unfold and move to item ID, or to the file ID of the form (ITEM . FILE)."
  ;; A file shows only once its item is unfolded and so drawn.
  (when (and (consp id) (agent-review--find 'agent-review-heading (car id)))
    (agent-review--set-folded (car id) nil))
  (let ((pos (or (agent-review--find (if (consp id) 'agent-review-file-heading
                                       'agent-review-heading)
                                     id)
                 (user-error "当前视图里没有它"))))
    (agent-review--set-folded id nil)
    (goto-char pos)
    (when-let* ((window (get-buffer-window)))
      (with-selected-window window (recenter 0)))))

(defun agent-review-toggle ()
  "Fold or unfold the file at point when on its name, else the item at point."
  (interactive)
  (if-let* ((file (get-text-property (point) 'agent-review-file-heading)))
      (agent-review--set-folded file (not (member file agent-review--folded-files)))
    (let* ((id (or (agent-review--item-at (point)) (user-error "这里不在审查项里")))
           (fold (not (member id agent-review--folded))))
      (agent-review--set-folded id fold)
      (when fold (goto-char (agent-review--find 'agent-review-heading id))))))

(defun agent-review--move (property forward)
  "Move to the next start of text with PROPERTY, or the previous unless FORWARD."
  (let ((match (if forward
                   (save-excursion
                     (when (get-text-property (point) property)
                       (goto-char (or (next-single-property-change (point) property) (point-max))))
                     (text-property-search-forward property nil (lambda (_ v) v) t))
                 (save-excursion
                   (when (get-text-property (point) property)
                     (goto-char (or (previous-single-property-change (1+ (point)) property)
                                    (point-min))))
                   (text-property-search-backward property nil (lambda (_ v) v) t)))))
    (if match (goto-char (prop-match-beginning match)) (message "没有了"))))

(defun agent-review-next-item ()
  "Move to the next item."
  (interactive)
  (agent-review--move 'agent-review-heading t))

(defun agent-review-previous-item ()
  "Move to the previous item."
  (interactive)
  (agent-review--move 'agent-review-heading nil))

(defun agent-review-next-annotation ()
  "Move to the next annotation, unfolding it."
  (interactive)
  (agent-review--move 'agent-review-comment t)
  (agent-review--reveal))

(defun agent-review-previous-annotation ()
  "Move to the previous annotation, unfolding it."
  (interactive)
  (agent-review--move 'agent-review-comment nil)
  (agent-review--reveal))

(defun agent-review--imenu-index ()
  "Index of the items, or of the files in the full diff, for imenu."
  (let ((property (if agent-review--full 'agent-review-file-heading 'agent-review-heading))
        index)
    (save-excursion
      (goto-char (point-min))
      (while-let ((match (text-property-search-forward property nil (lambda (_ v) v) t)))
        (push (cons (string-trim (buffer-substring-no-properties (prop-match-beginning match)
                                                                 (prop-match-end match)))
                    (prop-match-beginning match))
              index)))
    (nreverse index)))

;;; Reviewed items

(defun agent-review--mark-reviewed (id)
  "Toggle whether item ID is marked reviewed; return the new state.
A reviewed item is folded; marking it not reviewed again unfolds it."
  ;; Only atomic items: not the full diff, nor its files in the sidebar.
  (unless (and (stringp id) (not (equal id "full"))
               (agent-review--item agent-review--review id))
    (user-error "只有审查项能标记已审阅"))
  (let ((done (not (member id agent-review--reviewed))))
    (setq agent-review--reviewed (if done (cons id agent-review--reviewed)
                                   (remove id agent-review--reviewed)))
    (setq agent-review--folded (if done (cl-adjoin id agent-review--folded :test #'equal)
                                 (remove id agent-review--folded)))
    (agent-review--save-state)
    (agent-review--redraw-item id)
    done))

(defun agent-review--next-unreviewed (id)
  "The first item after ID not marked reviewed, wrapping around, or nil."
  (let* ((ids (mapcar (lambda (item) (plist-get item :id)) (plist-get agent-review--review :items)))
         (after (cdr (member id ids))))
    (seq-find (lambda (other) (not (member other agent-review--reviewed)))
              (append after (seq-take ids (- (length ids) (length after)))))))

(defun agent-review--reviewed-message (next)
  "Tell the user an item was marked reviewed and NEXT is the next one to read."
  (message (if next
               (format "已审阅；下一个未审阅：%s"
                       (plist-get (agent-review--item agent-review--review next) :title))
             "已审阅；全部审完了")))

(defun agent-review-toggle-reviewed ()
  "Mark the item at point reviewed and move to the next item not reviewed.
On an item already marked, mark it not reviewed again and stay."
  (interactive)
  (let ((id (or (agent-review--item-at (point)) (user-error "这里不在审查项里"))))
    (if (not (agent-review--mark-reviewed id))
        (message "已取消已审阅")
      (let ((next (agent-review--next-unreviewed id)))
        ;; With nothing left, stay on the heading of the item just folded.
        (goto-char (agent-review--find 'agent-review-heading (or next id)))
        (when-let* ((window (get-buffer-window))
                    ((not (pos-visible-in-window-p (point) window))))
          (with-selected-window window (recenter 3)))
        (agent-review--reviewed-message next)))))

;;; Sidebar

(defvar-local agent-review-nav--review-buffer nil "The review buffer this sidebar lists.")
(defvar-local agent-review-nav--filter nil "Only entries matching this text are listed.")
(defvar-local agent-review-nav--overlay nil "Highlight of the entry of the current item.")

(defun agent-review--nav-entries ()
  "Sidebar entries of this review buffer: a list of (ID TITLE DETAIL TEXT TYPE).
TEXT is what the filter matches; TYPE is the item type, nil for a file."
  (if agent-review--full
      (mapcar (lambda (file)
                (let ((name (plist-get file :file)))
                  (list (cons "full" name) name nil name nil)))
              (plist-get agent-review--review :full-files))
    (mapcar (lambda (item)
              (let ((files (string-join (plist-get item :files) " · ")))
                (list (plist-get item :id)
                      (agent-review--item-label item)
                      files
                      (concat (plist-get item :title) " " (plist-get item :intent) " " files)
                      (plist-get item :type))))
            (plist-get agent-review--review :items))))

(defvar-keymap agent-review-nav-entry-map
  :doc "Mouse keys on sidebar entries."
  "<mouse-1>" #'agent-review-nav-click)

(defun agent-review--nav-render ()
  "Draw this sidebar from its review buffer."
  (let* ((source agent-review-nav--review-buffer)
         (filter agent-review-nav--filter)
         (review (buffer-local-value 'agent-review--review source))
         (reviewed (buffer-local-value 'agent-review--reviewed source))
         (current (buffer-local-value 'agent-review--current source))
         (entries (with-current-buffer source (agent-review--nav-entries)))
         (items (plist-get review :items))
         (counts (make-hash-table :test #'equal))
         ;; Keep point on its entry: erasing the buffer would leave it at
         ;; the end, and the user may be moving through the sidebar.
         (keep (get-text-property (point) 'agent-review-nav))
         (line (line-number-at-pos))
         (inhibit-read-only t))
    (dolist (comment (agent-review--comments (plist-get review :id)))
      (cl-incf (gethash (plist-get comment :item) counts 0))
      (cl-incf (gethash (cons (plist-get comment :item) (plist-get comment :file)) counts 0)))
    (erase-buffer)
    (insert (propertize "Atomic Review" 'face 'agent-review-brand)
            (propertize (format "  %d 项 · 已审阅 %d\n" (length items)
                                (seq-count (lambda (item) (member (plist-get item :id) reviewed))
                                           items))
                        'face 'agent-review-meta))
    (when filter
      (insert (propertize (format "过滤：%s（/ 修改，空串清除）\n" filter)
                          'face 'agent-review-meta)))
    (insert "\n")
    (pcase-dolist (`(,id ,title ,detail ,text ,type) entries)
      (when (or (null filter) (string-search (downcase filter) (downcase text)))
        (let ((start (point))
              (n (gethash id counts 0)))
          (insert (if (member id reviewed) (propertize "✓ " 'face 'agent-review-done) "  ")
                  (propertize title 'mouse-face 'highlight
                              'keymap agent-review-nav-entry-map
                              'help-echo "跳到这一项")
                  (if (> n 0) (propertize (format "  ✎%d" n) 'face 'agent-review-comment) "")
                  "\n")
          (when detail
            (insert (propertize (concat "    " detail "\n") 'face 'agent-review-meta)))
          ;; The whole entry takes the background of the item's type.
          (when-let* ((face (alist-get type agent-review-type-faces)))
            (add-face-text-property start (point) face t))
          (put-text-property start (point) 'agent-review-nav id))))
    (insert "\n" (propertize "RET 跳转 · r 已审阅 · / 过滤 · g 刷新 · q 关闭\n"
                             'face 'agent-review-meta))
    (goto-char (or (and keep (agent-review--find 'agent-review-nav keep))
                   (progn (goto-char (point-min)) (forward-line (1- line)) (point))))
    (dolist (window (get-buffer-window-list nil nil t))
      (set-window-point window (point)))
    (agent-review--nav-highlight current)))

(defun agent-review--nav-highlight (id)
  "Highlight the sidebar entry of ID and keep it in view."
  (let ((pos (and id (save-excursion
                       (goto-char (point-min))
                       (when-let* ((match (text-property-search-forward 'agent-review-nav id t)))
                         (cons (prop-match-beginning match) (prop-match-end match)))))))
    (if (null pos)
        (when agent-review-nav--overlay (delete-overlay agent-review-nav--overlay))
      (unless (overlayp agent-review-nav--overlay)
        (setq agent-review-nav--overlay (make-overlay 1 1))
        (overlay-put agent-review-nav--overlay 'face 'agent-review-current))
      (move-overlay agent-review-nav--overlay (car pos) (cdr pos) (current-buffer))
      ;; Leave the sidebar's point alone while the user works in it.
      (when-let* ((window (get-buffer-window))
                  ((not (eq window (selected-window))))
                  ((not (pos-visible-in-window-p (car pos) window))))
        (set-window-point window (car pos))))))

(defun agent-review--nav-buffer ()
  "The sidebar buffer of this review buffer, drawn afresh."
  (unless (buffer-live-p agent-review--nav)
    (let ((source (current-buffer)))
      (setq agent-review--nav
            (generate-new-buffer (format "*review-nav: %s*" (plist-get agent-review--review :title))))
      (with-current-buffer agent-review--nav
        (agent-review-nav-mode)
        (setq agent-review-nav--review-buffer source))))
  (with-current-buffer agent-review--nav (agent-review--nav-render))
  agent-review--nav)

(defun agent-review--nav-refresh ()
  "Redraw the sidebar of this review buffer, if it has one."
  (when (buffer-live-p agent-review--nav)
    (with-current-buffer agent-review--nav (agent-review--nav-render))))

(defun agent-review--display-nav (buffer)
  "Show the sidebar BUFFER in a side window on the left."
  (display-buffer-in-side-window
   buffer `((side . left) (slot . 1) (window-width . ,agent-review-nav-width)
            (dedicated . t) (window-parameters (no-delete-other-windows . t)))))

(defun agent-review-toggle-nav ()
  "Show or hide the sidebar of this review."
  (interactive)
  (let ((buffer (agent-review--nav-buffer)))
    (if-let* ((window (get-buffer-window buffer)))
        (delete-window window)
      (agent-review--display-nav buffer))))

(defun agent-review--kill-nav ()
  "Kill the sidebar of this review buffer with it."
  (when (buffer-live-p agent-review--nav) (kill-buffer agent-review--nav)))

(defvar-local agent-review--track-timer nil
  "Pending update of the sidebar highlight.")

(defun agent-review--track ()
  "Highlight the sidebar entry of the item at point once Emacs is idle.
Updating it on every command made moving through folded items, where each
line is another item, redraw the sidebar on every key."
  (unless (timerp agent-review--track-timer)
    (let ((buffer (current-buffer)))
      (setq agent-review--track-timer
            (run-with-idle-timer
             0.15 nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq agent-review--track-timer nil)
                   (agent-review--track-now)))))))))

(defun agent-review--track-now ()
  "Highlight the sidebar entry of the item at point when it changes."
  (let ((id (if agent-review--full
                (get-text-property (point) 'agent-review-file-in)
              (agent-review--item-at (point)))))
    (unless (equal id agent-review--current)
      (setq agent-review--current id)
      (when (buffer-live-p agent-review--nav)
        (with-current-buffer agent-review--nav (agent-review--nav-highlight id))))))

(defun agent-review--nav-source ()
  "The live review buffer of this sidebar."
  (let ((buffer agent-review-nav--review-buffer))
    (unless (buffer-live-p buffer) (user-error "审查 buffer 已关闭"))
    buffer))

(defun agent-review-nav-visit ()
  "Show the entry at point in the review buffer."
  (interactive)
  (let ((id (or (get-text-property (point) 'agent-review-nav) (user-error "这里没有条目")))
        (buffer (agent-review--nav-source)))
    (select-window (or (get-buffer-window buffer) (agent-ui--show-buffer buffer)))
    (agent-review-goto id)))

(defun agent-review-nav-click (event)
  "Show the entry clicked with EVENT in the review buffer."
  (interactive "e")
  (mouse-set-point event)
  (agent-review-nav-visit))

(defun agent-review-nav-toggle-reviewed ()
  "Mark the item at point reviewed and move to the next one not reviewed.
On an item already marked, mark it not reviewed again and stay."
  (interactive)
  (let* ((id (or (get-text-property (point) 'agent-review-nav) (user-error "这里没有条目")))
         (next (with-current-buffer (agent-review--nav-source)
                 (if (agent-review--mark-reviewed id)
                     (let ((next (agent-review--next-unreviewed id)))
                       (agent-review--reviewed-message next)
                       (or next 'done))
                   (message "已取消已审阅")
                   nil))))
    (when-let* (((stringp next))
                (pos (agent-review--find 'agent-review-nav next)))
      (goto-char pos))))

(defun agent-review-nav-filter (text)
  "List only the entries whose title, intent or files contain TEXT.
An empty TEXT lists all of them."
  (interactive (list (read-string "过滤（标题 / 意图 / 文件）：" agent-review-nav--filter)))
  (setq agent-review-nav--filter (unless (string-blank-p text) (string-trim text)))
  (agent-review--nav-render))

(defvar-keymap agent-review-nav-mode-map
  :doc "Keys for the review sidebar."
  "RET" #'agent-review-nav-visit
  "r" #'agent-review-nav-toggle-reviewed
  "/" #'agent-review-nav-filter
  "n" #'next-line
  "p" #'previous-line)

(define-derived-mode agent-review-nav-mode special-mode "Review-Nav"
  "Sidebar listing the items of a review."
  (setq-local truncate-lines t
              revert-buffer-function (lambda (&rest _) (agent-review--nav-render))))

;;; Annotation list

(defvar-local agent-review-notes--review-buffer nil "The review buffer of this list.")

(defun agent-review-notes--entries ()
  "Rows of this annotation list."
  (with-current-buffer (agent-review--notes-source)
    (let ((review agent-review--review))
      (mapcar (lambda (comment)
                (let ((item (agent-review--item review (plist-get comment :item))))
                  (list (plist-get comment :id)
                        (vector (alist-get (plist-get comment :status) agent-review-statuses
                                           nil nil #'equal)
                                (format "%s %s" (file-name-nondirectory (plist-get comment :file))
                                        (or (plist-get comment :range) ""))
                                (if (equal (plist-get item :id) "full") "完整 diff"
                                  (format "%d. %s" (plist-get item :order) (plist-get item :title)))
                                (car (split-string (plist-get comment :comment) "\n"))))))
              (agent-review--comments (plist-get review :id))))))

(defun agent-review--notes-source ()
  "The live review buffer of this annotation list."
  (let ((buffer agent-review-notes--review-buffer))
    (unless (buffer-live-p buffer) (user-error "审查 buffer 已关闭"))
    buffer))

(defun agent-review-list-annotations ()
  "List all annotations of this review."
  (interactive)
  (let ((source (current-buffer))
        (buffer (get-buffer-create (format "*review-notes: %s*"
                                           (plist-get agent-review--review :title)))))
    (with-current-buffer buffer
      (agent-review-notes-mode)
      (setq agent-review-notes--review-buffer source)
      (revert-buffer))
    (pop-to-buffer buffer '((display-buffer-below-selected) (window-height . 12)))))

(defun agent-review-goto-annotation (id)
  "Unfold and move to the annotation with ID."
  (let ((comment (seq-find (lambda (c) (equal (plist-get c :id) id))
                           (agent-review--comments (plist-get agent-review--review :id)))))
    (when comment
      (agent-review--set-folded (plist-get comment :item) nil)
      (agent-review--set-folded (cons (plist-get comment :item) (plist-get comment :file)) nil))
    (goto-char (or (agent-review--find 'agent-review-comment id)
                   (user-error "当前视图里没有这条标注，按 f 切换视图试试")))
    (when-let* ((window (get-buffer-window))) (with-selected-window window (recenter)))))

(defun agent-review-notes-visit ()
  "Show the annotation at point in the review buffer."
  (interactive)
  (let ((id (or (tabulated-list-get-id) (user-error "这里没有标注")))
        (buffer (agent-review--notes-source)))
    (select-window (or (get-buffer-window buffer) (agent-ui--show-buffer buffer)))
    (agent-review-goto-annotation id)))

(defvar-keymap agent-review-notes-mode-map
  :doc "Keys for the annotation list."
  "RET" #'agent-review-notes-visit)

(define-derived-mode agent-review-notes-mode tabulated-list-mode "Review-Notes"
  "List of the annotations of a review."
  (setq tabulated-list-format [("状态" 6 t) ("位置" 30 t) ("审查项" 30 t) ("标注" 0 nil)]
        tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook
            (lambda () (setq tabulated-list-entries (agent-review-notes--entries)))
            nil t)
  (tabulated-list-init-header))

;;; Writing annotations

(defvar-local agent-review--note nil
  "In a note buffer: (:buffer REVIEW-BUFFER :lines LINES :overlay OVERLAY).")

(defun agent-review--lines-between (start end)
  "Line targets of the review lines from START to END, in order."
  (save-excursion
    (let ((last (progn (goto-char (if (> end start) (1- end) end)) (line-beginning-position)))
          lines)
      (goto-char start)
      (beginning-of-line)
      (while (and (<= (point) last) (not (eobp)))
        (when-let* ((target (get-text-property (point) 'agent-review-target)))
          (unless (member target lines) (push target lines)))
        (forward-line 1))
      (nreverse lines))))

(defun agent-review--comment-at (pos)
  "The annotation shown at POS, or nil."
  (when-let* ((id (get-text-property pos 'agent-review-comment)))
    (seq-find (lambda (c) (equal (plist-get c :id) id))
              (agent-review--comments (plist-get agent-review--review :id)))))

(defun agent-review--comment-lines (comment)
  "The line targets the annotation COMMENT covers."
  (mapcar (lambda (line)
            (list :item (plist-get comment :item) :file (plist-get comment :file)
                  :side (plist-get line :side) :line (plist-get line :line)
                  :kind (plist-get line :kind) :code (plist-get line :code)))
          (plist-get comment :lines)))

(defun agent-review-annotate (start end)
  "Write an annotation on the lines from START to END and send it to the agent.
Without an active region, annotate the line at point; on an annotation,
edit it.  The annotation is written in a buffer below; it goes to the
session that made the review, with the selected code, when sent."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (point) (point))))
  (let* ((existing (and (= start end) (agent-review--comment-at start)))
         (lines (if existing (agent-review--comment-lines existing)
                  (agent-review--lines-between start end)))
         (first (car lines)))
    (unless lines (user-error "选中的地方没有代码行"))
    (unless (seq-every-p (lambda (line)
                           (and (equal (plist-get line :item) (plist-get first :item))
                                (equal (plist-get line :file) (plist-get first :file))))
                         lines)
      (user-error "一条标注只能选同一审查项里同一个文件的行"))
    ;; There is one note buffer; don't throw away a note not sent yet.
    (when-let* ((draft (get-buffer "*review-note*"))
                ((buffer-local-value 'agent-review--note draft))
                ((not (string-blank-p (with-current-buffer draft (buffer-string))))))
      (unless (yes-or-no-p "还有一条标注没发送，放弃它？")
        (pop-to-buffer draft)
        (user-error "先发送（C-c C-c）或取消（C-c C-k）那条标注")))
    (let* ((id (agent-review--comment-id lines))
           (previous (or existing
                         (seq-find (lambda (c) (equal (plist-get c :id) id))
                                   (agent-review--comments (plist-get agent-review--review :id)))))
           (overlay (make-overlay (save-excursion (goto-char start) (line-beginning-position))
                                  (save-excursion (goto-char (if (> end start) (1- end) end))
                                                  (line-beginning-position 2))))
           (source (current-buffer))
           (buffer (get-buffer-create "*review-note*")))
      (overlay-put overlay 'face 'agent-review-selected)
      (deactivate-mark)
      (with-current-buffer buffer
        (agent-review--note-cleanup)
        (agent-review-note-mode)
        (erase-buffer)
        (when previous (insert (plist-get previous :comment)))
        (setq agent-review--note (list :buffer source :lines lines :overlay overlay)
              header-line-format
              (format " %s %s%s · C-c C-c 发给 agent · C-c C-k 取消"
                      (plist-get first :file) (agent-review--range-text lines)
                      (if previous "（修改）" "")))
        (add-hook 'kill-buffer-hook #'agent-review--note-cleanup nil t))
      (select-window (display-buffer buffer '((display-buffer-below-selected)
                                              (window-height . 8))))
      (goto-char (point-max)))))

(defun agent-review--note-cleanup ()
  "Remove the highlight of the lines this note buffer annotates."
  (when-let* ((overlay (plist-get agent-review--note :overlay)))
    (delete-overlay overlay)))

(defun agent-review--note-close ()
  "Close this note buffer and its window."
  (agent-review--note-cleanup)
  (setq agent-review--note nil)
  (quit-window t))

(defun agent-review-note-send ()
  "Save the annotation and send it to the agent session of the review."
  (interactive)
  (let* ((note agent-review--note)
         (text (string-trim (buffer-string)))
         (source (plist-get note :buffer)))
    (when (string-empty-p text) (user-error "标注是空的"))
    (unless (buffer-live-p source) (user-error "审查 buffer 已关闭"))
    (let* ((session (agent-review--session-buffer (buffer-local-value 'agent-review--review source)))
           (agent (buffer-local-value 'agent-session--current session)))
      (when (eq (agent-session-status agent) 'exited) (user-error "agent 进程已退出"))
      (let* ((review (buffer-local-value 'agent-review--review source))
             (comment (agent-review-annotate-lines review (plist-get note :lines) text)))
        ;; Deliver first: if that fails, the draft is still here to send again.
        (agent-session-submit agent (agent-review--message review comment))
        (agent-review--note-close)
        (agent-review--refresh (plist-get review :id) (plist-get comment :item))
        (message "标注已发给 %s" (buffer-name session))))))

(defun agent-review-note-cancel ()
  "Close this note buffer without sending it."
  (interactive)
  (agent-review--note-close))

(defvar-keymap agent-review-note-mode-map
  :doc "Keys for writing an annotation."
  "C-c C-c" #'agent-review-note-send
  "C-c C-k" #'agent-review-note-cancel)

(define-derived-mode agent-review-note-mode text-mode "Review-Note"
  "Write an annotation: C-c C-c sends it to the agent, C-c C-k cancels.")

;;; Commands

(defun agent-review--target ()
  "The review line at point."
  (or (get-text-property (point) 'agent-review-target)
      (user-error "这里不是代码行")))

(defun agent-review-delete-annotation ()
  "Delete the annotation at point."
  (interactive)
  (let ((comment (or (agent-review--comment-at (point)) (user-error "光标不在标注上")))
        (id (plist-get agent-review--review :id)))
    (when (yes-or-no-p "删除这条标注？")
      (agent-review--delete-comment id comment)
      (agent-review--refresh id (plist-get comment :item)))))

(defun agent-review--set-agent (review agent)
  "Make the session buffer named AGENT the one answering REVIEW; return REVIEW."
  (let ((id (plist-get review :id)))
    (setq review (plist-put (copy-sequence review) :agent agent))
    (agent-review--write (agent-review--path id "review.eld") review)
    (agent-review--write (agent-review--path "index.eld")
                         (mapcar (lambda (entry)
                                   (if (equal (plist-get entry :id) id)
                                       (plist-put (copy-sequence entry) :agent agent)
                                     entry))
                                 (agent-review--index)))
    (dolist (buffer (agent-review--buffers id))
      (with-current-buffer buffer (setq agent-review--review review)))
    review))

(defun agent-review--session-buffer (review)
  "The session buffer that answers REVIEW's annotations.
That is the session that made it; once that one is gone (session buffer
names change when Emacs restarts), the user picks a live session, those of
the review's project first, and the choice is stored with the review."
  (let ((buffer (and (plist-get review :agent) (get-buffer (plist-get review :agent)))))
    (if (and buffer (agent-session-buffer-p buffer))
        buffer
      (let* ((live (seq-filter #'agent-session-buffer-p (buffer-list)))
             (same (seq-filter (lambda (b)
                                 (equal (agent-session-root (buffer-local-value
                                                             'agent-session--current b))
                                        (plist-get review :root)))
                               live))
             (names (mapcar #'buffer-name (append same (seq-difference live same)))))
        (unless names (user-error "没有可用的 agent 会话"))
        (let ((name (completing-read "生成这份审查的会话已关闭，交给哪个会话回应：" names nil t)))
          (agent-review--set-agent review name)
          (get-buffer name))))))

(defun agent-review-visit ()
  "Show the code of the line at point in another window.
A line the branch has is shown in a worktree at the review's head, a
removed line in the base version.  Elsewhere, the nearest code line is
shown; on the line of a gap between hunks, all its lines are instead."
  (interactive)
  (if (get-text-property (point) 'agent-review-gap-info)
      (agent-review--expand 'all)
    (agent-review--visit-line)))

(defun agent-review--nearest-target (pos)
  "The code line at POS, or the one nearest to it in the same file or item.
An annotation belongs to the line above it; a heading or a gap's line to
the code below it."
  (or (get-text-property pos 'agent-review-target)
      (let* ((scope (if (get-text-property pos 'agent-review-file-in)
                        'agent-review-file-in
                      'agent-review-in))
             (value (get-text-property pos scope))
             (find (lambda (forward)
                     (save-excursion
                       (goto-char pos)
                       (when-let* ((match (if forward
                                              (text-property-search-forward
                                               'agent-review-target nil (lambda (_ v) v))
                                            (text-property-search-backward
                                             'agent-review-target nil (lambda (_ v) v))))
                                   ((equal (get-text-property (prop-match-beginning match) scope)
                                           value)))
                         (prop-match-value match))))))
        (when value
          (if (get-text-property pos 'agent-review-comment)
              (or (funcall find nil) (funcall find t))
            (or (funcall find t) (funcall find nil)))))))

(defun agent-review--head-checkout ()
  "Directory of a worktree of the review's repository at its head, or nil.
Looked up once per buffer; reverting the buffer looks again."
  (when (eq agent-review--checkout 'unknown)
    (setq agent-review--checkout
          (let* ((root (plist-get agent-review--review :root))
                 (head (concat "HEAD " (plist-get agent-review--review :head-sha))))
            (cl-loop for block in (split-string (condition-case nil
                                                    (agent-review--git root "worktree" "list"
                                                                       "--porcelain")
                                                  (error ""))
                                                "\n\n" t)
                     for lines = (split-string block "\n" t)
                     when (and (string-prefix-p "worktree " (car lines)) (member head lines))
                     return (file-name-as-directory
                             (agent-session-expand-file-name
                              (substring (car lines) (length "worktree ")) root))))))
  agent-review--checkout)

(defun agent-review--version-buffer (label rev file text)
  "Read-only buffer of FILE as of REV, named after LABEL.
TEXT is its contents, or nil to read them from git."
  (let ((root (plist-get agent-review--review :root))
        (buffer (get-buffer-create (format "*review-%s: %s*" label file))))
    (setq text (or text (agent-review--git root "show" (format "%s:%s" rev file))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      (when-let* ((mode (agent-review--file-mode file)))
        (let ((treesit-auto-install-grammar nil)) (ignore-errors (funcall mode))))
      (setq buffer-read-only t
            default-directory root))
    buffer))

(defun agent-review--show-code (buffer line)
  "Select BUFFER in another window, on line LINE, and flash that line."
  (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-use-some-window
                                                       display-buffer-pop-up-window)
                          (inhibit-same-window . t)))
  (goto-char (point-min))
  (forward-line (1- line))
  (recenter)
  (pulse-momentary-highlight-one-line (point)))

(defun agent-review--visit-head (file line)
  "Show line LINE of FILE as the review's head has it.
That is the file itself in a worktree at the head, or in the project when
its copy is the same; else a read-only copy of the head's version."
  (let* ((review agent-review--review)
         (head (plist-get review :head-sha))
         (checkout (agent-review--head-checkout))
         (same (seq-find (lambda (dir)
                           (and dir (file-exists-p (expand-file-name file dir))
                                (ignore-errors
                                  (agent-review--git dir "diff" "--quiet" head "--" file)
                                  t)))
                         ;; The project's own path before git's name for it.
                         (delete-dups (list (plist-get review :root) checkout)))))
    (cond (same
           (agent-review--show-code (find-file-noselect (expand-file-name file same)) line))
          ((and checkout (file-exists-p (expand-file-name file checkout)))
           (agent-review--show-code (find-file-noselect (expand-file-name file checkout)) line)
           (message "这个文件改过了，和审查的版本不同，行号可能对不上"))
          (t
           (agent-review--show-code
            (agent-review--version-buffer "head" head file
                                          (alist-get file (plist-get review :sources)
                                                     nil nil #'equal))
            line)
           (message "没有工作区检出了 %s，打开的是这个版本的只读副本"
                    (substring head 0 10))))))

(defun agent-review--visit-line ()
  "Show the code of the line at point, see `agent-review-visit'."
  (let ((target (or (agent-review--nearest-target (point)) (user-error "这里没有对应的代码")))
        (review agent-review--review))
    (if (eq (plist-get target :side) 'new)
        (agent-review--visit-head (plist-get target :file) (plist-get target :line))
      (let ((file (or (plist-get target :old-file) (plist-get target :file))))
        (agent-review--show-code
         (agent-review--version-buffer "base" (plist-get review :base-sha) file
                                       (alist-get file (agent-review--old-sources)
                                                  nil nil #'equal))
         (plist-get target :line))))))

;;; Language server

;; Hover on a code line asks the language server of the file the line is in,
;; through the buffer visiting it.  Only for lines the head has, and only
;; while that buffer still has the line's text: the server knows the buffer,
;; not the reviewed commit.

(defun agent-review--source-buffer (file)
  "Buffer visiting FILE in the head's worktree or the project, or nil.
Opened once per review buffer, without being shown; nil when neither
has the file."
  (let* ((cache (or agent-review--source-buffers
                    (setq agent-review--source-buffers (make-hash-table :test #'equal))))
         (buffer (gethash file cache 'missing)))
    (unless (or (null buffer) (buffer-live-p buffer))
      (setq buffer
            (puthash file
                     (when-let* ((path (seq-find
                                        #'file-exists-p
                                        (mapcar (lambda (dir) (expand-file-name file dir))
                                                (delq nil (delete-dups
                                                           (list (agent-review--head-checkout)
                                                                 (plist-get agent-review--review
                                                                            :root))))))))
                       (find-file-noselect path))
                     cache)))
    buffer))

(defun agent-review--source-position (pos)
  "Buffer and position in the head's file of the code at POS, or nil.
Nil for a removed line, off a line's code, or when the buffer visiting
the file no longer has the line's text."
  (when-let* ((target (get-text-property pos 'agent-review-target))
              ((eq (plist-get target :side) 'new))
              (column (get-text-property pos 'agent-review-code-column))
              (code (plist-get target :code))
              (offset (- pos (save-excursion (goto-char pos) (pos-bol)) column))
              ((<= 0 offset))
              (buffer (agent-review--source-buffer (plist-get target :file))))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (save-excursion
          (goto-char (point-min))
          (when (and (zerop (forward-line (1- (plist-get target :line))))
                     (equal (buffer-substring-no-properties (point) (pos-eol)) code))
            ;; Past the code is the note that the file has no final newline.
            (cons buffer (+ (point) (min offset (length code))))))))))

(defun agent-review--eldoc-hover (callback &rest _)
  "Show what the language server says of the code at point, through CALLBACK.
A member of `eldoc-documentation-functions' in review buffers; works
where eglot manages the buffer visiting the file."
  (when-let* ((source (agent-review--source-position (point))))
    (with-current-buffer (car source)
      (when (and (fboundp 'eglot-managed-p) (eglot-managed-p)
                 (eglot-server-capable :hoverProvider))
        (eglot--async-request
         (eglot-current-server) :textDocument/hover
         (save-excursion (goto-char (cdr source)) (eglot--TextDocumentPositionParams))
         :success-fn (lambda (hover)
                       (let ((contents (plist-get hover :contents)))
                         (funcall callback (and contents (not (seq-empty-p contents))
                                                (eglot--hover-info contents)))))
         :error-fn #'ignore
         :hint :textDocument/hover)
        t))))

(defun agent-review-toggle-full ()
  "Switch between the items and the full diff."
  (interactive)
  (setq agent-review--full (not agent-review--full)
        agent-review--current nil)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (agent-review--render))
  (goto-char (point-min))
  (agent-review--nav-refresh))

(defun agent-review-more-context (&optional n)
  "Show N more lines of context around each hunk; N defaults to 5.
A negative N shows fewer."
  (interactive "P")
  (setq agent-review--context
        (max 0 (+ (or agent-review--context agent-review-context)
                  (if n (prefix-numeric-value n) 5))))
  (agent-review--redraw)
  (message "上下文 %d 行" agent-review--context))

(defun agent-review-less-context ()
  "Show 5 fewer lines of context around each hunk."
  (interactive)
  (agent-review-more-context -5))

(defun agent-review--gap-at (pos direction)
  "The gap to open from POS in DIRECTION, as (KEY HIDDEN . DIRECTIONS), or nil.
On the line of a gap, that gap; in a hunk, the gap above or below it."
  (if-let* ((key (get-text-property pos 'agent-review-gap)))
      (when-let* ((info (get-text-property pos 'agent-review-gap-info)))
        (cons key info))
    (when-let* ((hunk (get-text-property pos 'agent-review-hunk))
                (key (list (nth 0 hunk) (nth 1 hunk)
                           (if (eq direction 'up) (nth 2 hunk) (1+ (nth 2 hunk)))))
                (line (agent-review--find 'agent-review-gap key))
                (info (get-text-property line 'agent-review-gap-info)))
      (cons key info))))

(defun agent-review--expand (direction &optional count)
  "Show COUNT more hidden lines of the gap at point in DIRECTION.
DIRECTION is `down' to extend the hunk above the gap, `up' the hunk below
it, or `all' to show the whole gap.  COUNT defaults to
`agent-review-expand-lines'; `all' shows the whole gap too."
  (pcase-let* ((`(,key ,hidden . ,directions)
                (or (agent-review--gap-at (point) direction) (user-error "这里没有隐藏的行")))
               (count (if (or (eq direction 'all) (eq count 'all))
                          hidden
                        (min hidden (or count agent-review-expand-lines))))
               (direction (cond ((eq direction 'all)
                                 (if (memq 'down directions) 'down 'up))
                                ((memq direction directions) direction)
                                (t (car directions))))
               (table (or agent-review--expanded
                          (setq agent-review--expanded (make-hash-table :test #'equal))))
               (`(,down . ,up) (apply #'agent-review--gap-shown key)))
    (puthash key (if (eq direction 'down) (cons (+ down count) up) (cons down (+ up count)))
             table)
    ;; Lines shown below the hunk above the gap go below point when it is
    ;; there, and the gap's line may be gone after.
    (when (eq direction 'down)
      (goto-char (agent-review--find 'agent-review-gap key))
      (forward-line -1))
    (agent-review--redraw-item (car key))))

(defun agent-review-expand-up (&optional n)
  "Show N more lines above the hunk at point, or of the gap at point.
N defaults to `agent-review-expand-lines'; with \\[universal-argument] alone, all of them."
  (interactive "P")
  (agent-review--expand 'up (if (consp n) 'all (and n (prefix-numeric-value n)))))

(defun agent-review-expand-down (&optional n)
  "Show N more lines below the hunk at point, or of the gap at point.
N defaults to `agent-review-expand-lines'; with \\[universal-argument] alone, all of them."
  (interactive "P")
  (agent-review--expand 'down (if (consp n) 'all (and n (prefix-numeric-value n)))))

(defun agent-review-open (id)
  "Show the stored review with ID."
  (interactive
   (let* ((index (or (agent-review--index) (user-error "还没有审查")))
          (choices (mapcar (lambda (entry)
                             (cons (format "%s  %s  %s" (plist-get entry :title)
                                           (plist-get entry :created) (plist-get entry :id))
                                   (plist-get entry :id)))
                           index)))
     (list (cdr (assoc (completing-read "打开审查：" choices nil t) choices)))))
  (pop-to-buffer (agent-review-show (agent-review--load id))))

(defvar-keymap agent-review-mode-map
  :doc "Keys for review buffers."
  "TAB" #'agent-review-toggle
  "n" #'agent-review-next-item
  "p" #'agent-review-previous-item
  "]" #'agent-review-next-annotation
  "[" #'agent-review-previous-annotation
  "a" #'agent-review-annotate
  "d" #'agent-review-delete-annotation
  "r" #'agent-review-toggle-reviewed
  "o" #'agent-review-toggle-nav
  "C" #'agent-review-list-annotations
  "RET" #'agent-review-visit
  "f" #'agent-review-toggle-full
  "+" #'agent-review-more-context
  "-" #'agent-review-less-context
  "{" #'agent-review-expand-up
  "}" #'agent-review-expand-down)

(define-derived-mode agent-review-mode special-mode "Review"
  "Review the atomic items of a branch's changes and annotate their lines."
  ;; Every redraw would record the whole buffer, which nobody edits.
  (buffer-disable-undo)
  ;; Code lines don't wrap; prose is filled when drawn (`agent-review--fill').
  (setq-local truncate-lines t
              header-line-format '(:eval (agent-review--header-line))
              imenu-create-index-function #'agent-review--imenu-index
              revert-buffer-function (lambda (&rest _)
                                       (setq agent-review--checkout 'unknown
                                             agent-review--source-buffers nil)
                                       (agent-review--redraw)))
  (add-hook 'eldoc-documentation-functions #'agent-review--eldoc-hover nil t)
  (eldoc-mode 1)
  (add-hook 'post-command-hook #'agent-review--track nil t)
  (add-hook 'imenu-after-jump-hook #'agent-review--reveal nil t)
  (add-hook 'kill-buffer-hook #'agent-review--kill-nav nil t))

;;; Methods

(defun agent-review--json-bool (value)
  "VALUE as a JSON boolean."
  (if value t :false))

(defun agent-review--json-comment (comment)
  "The annotation COMMENT as JSON for an agent."
  (list :id (plist-get comment :id) :revision (plist-get comment :revision)
        :status (plist-get comment :status)
        :item (plist-get comment :item) :item_title (plist-get comment :item-title)
        :file (plist-get comment :file)
        :lines (or (plist-get comment :range) "")
        :code (plist-get comment :code)
        :comment (plist-get comment :comment)
        :response (agent-ui--json-value (plist-get comment :response))))

(agent-ui-defmethod "review_snapshot"
    ((base string "Branch, tag or commit to compare against, e.g. main or origin/main" required)
     (head string "Branch or commit under review. Default: HEAD"))
  "Start an atomic review (原子审查) of a branch: pin the committed changes of head against its merge base with base, and list their hunks. The emacs-atomic-review skill describes the whole workflow: how to split the changes, write the plan and answer annotations; follow it. Only committed changes are compared, never uncommitted files.

The plan you then give review_build: a summary of the whole compared change, and items {\"title\", \"intent\", \"type\", \"parts\"}. type: 0 formatting, 1 refactoring, 2 feature, 3 local fix, 5 tests. Each part names a file of this snapshot and selects exactly one of: \"hunks\": [0, 2] (zero-based hunk indexes within that file, as listed here); \"whole\": true (all its hunks, or a binary/metadata-only file); \"added_lines\": [10, 45] (inclusive line range of a newly added text file only). Every changed line must be covered exactly once. Write titles, intents and the summary in Chinese. Small diffs come with the hunks' text (fragments); otherwise run diff_command."
  (let* ((root (or (agent-ui--caller-root) (error "No project root for this caller")))
         (snapshot (agent-review-snapshot root base (or head "HEAD")))
         (fragments (plist-get snapshot :fragments)))
    (list :snapshot (plist-get snapshot :id)
          :target_ref base :target_sha (plist-get snapshot :target-sha)
          :merge_base (plist-get snapshot :base-sha)
          :head_ref (or head "HEAD") :head_sha (plist-get snapshot :head-sha)
          :files (vconcat
                  (mapcar (lambda (block)
                            (list :file (plist-get block :file)
                                  :new_file (agent-review--json-bool
                                             (string-search "--- /dev/null\n"
                                                            (plist-get block :header)))
                                  :metadata_only (agent-review--json-bool
                                                  (null (plist-get block :hunks)))
                                  :hunks (vconcat
                                          (seq-map-indexed
                                           (lambda (hunk index)
                                             (let ((lines (split-string hunk "\n")))
                                               (list :index index :header (car lines)
                                                     :lines (- (length lines) 2))))
                                           (plist-get block :hunks)))))
                          (plist-get snapshot :files)))
          :diff_command (agent-review--diff-command (plist-get snapshot :base-sha)
                                                    (plist-get snapshot :head-sha))
          :fragments (if (<= (length fragments) agent-review-inline-fragments) fragments :null))))

(agent-ui-defmethod "review_build"
    ((snapshot string "Snapshot id returned by review_snapshot" required)
     (summary string "Overview of the whole compared change, in Chinese" required)
     (items array "The atomic items, see review_snapshot for the format" required)
     (title string "Review title. Default: <head> → <base>"))
  "Assemble your plan for a snapshot (item format: see review_snapshot), check that every changed line is covered exactly once, and show the review in Emacs. Building the same plan again reopens the existing review with its annotations; a changed plan makes a new review and leaves the old one. Afterwards give the user the base/head and a short result, and tell them to select lines in the review buffer and press a to write an annotation. Each annotation arrives in this session as a user message carrying the selected code, its file and line range, and the review and annotation ids. Answer it only by calling review_reply: the answer shows under the annotation in the review, so do not also write it in the conversation (at most a one-line note that you replied). Do not wait or poll for annotations."
  (let* ((snap (agent-review--load-snapshot snapshot))
         (review (agent-review-build snap summary items title
                                     (plist-get agent-ui-caller :agent_buffer)))
         (buffer (agent-review-show review)))
    (append (list :review (plist-get review :id) :buffer (buffer-name buffer)
                  :base (plist-get review :base-sha) :head (plist-get review :head-sha))
            (plist-get review :stats))))

(agent-ui-defmethod "review_comments"
    ((review string "Review id. Default: every review made by this session")
     (all boolean "Include annotations already answered"))
  "Read the user's annotations of atomic reviews: item, file, the line range they cover (新: lines at head, 旧: lines at the merge base), the selected code as diff lines, revision and the user's text. Each annotation was also sent to the session as a message when written; use this to re-read them. Treat them as the user's review comments: check each against the pinned commits and answer it with review_reply only, not in the conversation. Answering is not permission to change the code; change it only when the user asks."
  (let* ((agent (plist-get agent-ui-caller :agent_buffer))
         (root (agent-ui--caller-root))
         (ids (cond (review (list review))
                    ((let ((mine (seq-filter (lambda (e) (equal (plist-get e :agent) agent))
                                             (agent-review--index))))
                       (mapcar (lambda (e) (plist-get e :id)) mine)))
                    (t (when-let* ((latest (seq-find (lambda (e) (equal (plist-get e :root) root))
                                                     (agent-review--index))))
                         (list (plist-get latest :id)))))))
    (vconcat
     (mapcar (lambda (id)
               (let ((data (agent-review--load id)))
                 (list :review id :title (plist-get data :title)
                       :base (plist-get data :base-sha) :head (plist-get data :head-sha)
                       :comments (vconcat
                                  (mapcar #'agent-review--json-comment
                                          (seq-filter (lambda (c)
                                                        (or all (equal (plist-get c :status) "open")))
                                                      (agent-review--comments id)))))))
             ids))))

(agent-ui-defmethod "review_reply"
    ((review string "Review id" required)
     (id string "Annotation id" required)
     (revision integer "The annotation revision you read" required)
     (text string "Your answer, in Chinese" required)
     (status string "responded (default) or resolved"))
  "Answer an annotation in its review; the review buffer shows it at once under the annotation. This is where the answer goes: do not repeat it in the conversation. A revision conflict means the user edited the annotation after you read it: read it again with review_comments and answer the new text. Use status resolved only when the issue is actually fixed or the user asks."
  (let ((answered (agent-review-reply review id revision text status)))
    (agent-review--refresh review (plist-get answered :item))
    (list :id id :status (plist-get answered :status))))

(provide 'agent-review)

;; Method descriptions are written for agents and are not wrapped at 80
;; columns.
;; Local Variables:
;; byte-compile-docstring-max-column: 2000
;; End:

;;; agent-review.el ends here
