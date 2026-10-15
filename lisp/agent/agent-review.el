;;; agent-review.el --- Atomic reviews of a branch's changes -*- lexical-binding: t; -*-

;;; Commentary:

;; An agent splits the committed changes of a branch into atomic review items,
;; one intent each.  Emacs pins the diff, checks that the items cover every
;; changed line exactly once, and shows them in a review buffer.  The user
;; annotates lines there and, when ready, asks the session that made the
;; review to answer; its answers appear under the annotations.
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
;; Keys in a review: TAB folds an item, n / p move between items, ] / [
;; between annotations, a annotates the line at point (or edits its
;; annotation), d deletes it, s asks the agent to answer, RET visits the line,
;; + / - show more or less context, f toggles the full diff, g redraws, q
;; quits.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'diff-mode)
(require 'agent-session)
(require 'agent-ui)
(require 'agent-canvas)

(declare-function my/var "init-base")

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

;;; Git

(defun agent-review--git (root &rest args)
  "Run git with ARGS in ROOT and return its standard output.
Signal an error with git's message when it fails."
  (let ((default-directory root)
        (stderr (make-temp-file "agent-review-git")))
    (unwind-protect
        (with-temp-buffer
          (let* ((coding-system-for-read 'utf-8-unix)
                 (status (apply #'process-file "git" nil (list t stderr) nil
                                "-c" "core.quotepath=false" args)))
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
  (string-join (append '("git" "-c" "core.quotepath=false" "diff")
                       agent-review--diff-flags
                       (list "--unified=0" base head "--"))
               " "))

(defconst agent-review--source-limit (* 2 1024 1024)
  "Largest file, in bytes, whose text a review keeps for context.")

(defun agent-review--source-text (bytes)
  "BYTES of a file decoded as UTF-8, or nil for binary and non-UTF-8 files."
  (when (and (<= (length bytes) agent-review--source-limit)
             (not (string-search "\0" bytes)))
    (let ((text (decode-coding-string bytes 'utf-8-unix t)))
      ;; Invalid UTF-8 decodes to raw-byte characters.
      (unless (string-match-p (format "[%c-%c]" #x3fff80 #x3fffff) text)
        text))))

(defun agent-review--cat-files (root head files)
  "The bytes of FILES at commit HEAD in ROOT read by one git cat-file.
Return a list of (FILE . BYTES), BYTES nil for a missing file, or nil
when the output cannot be split, which happens when a file handler
decodes it lossily."
  (let ((default-directory root)
        (input (make-temp-file "agent-review-batch")))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix)
              (coding-system-for-read 'utf-8-emacs-unix))
          (write-region (mapconcat (lambda (file) (format "%s:%s\n" head file)) files "")
                        nil input nil 'silent)
          (with-temp-buffer
            (unless (eql 0 (process-file "git" input (list t nil) nil "cat-file" "--batch"))
              (error "git cat-file failed"))
            ;; Some file handlers (tramp-rpc) decode the output whatever
            ;; coding is asked for, so turn it back into bytes before using
            ;; the byte sizes git reports.
            (let ((out (if enable-multibyte-characters
                           (encode-coding-string (buffer-string) 'utf-8-emacs-unix)
                         (buffer-string)))
                  (pos 0) result)
              (catch 'lossy
                (dolist (file files (nreverse result))
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
                   (t (throw 'lossy nil))))))))
      (delete-file input))))

(defun agent-review--sources (root head files)
  "The text of FILES at commit HEAD in ROOT, as an alist (FILE . TEXT).
Binary files, files that are not UTF-8 and files larger than
`agent-review--source-limit' are left out."
  (when files
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

;;; Diff parsing

(defun agent-review--split-before (regexp text)
  "Split TEXT before every line that starts with REGEXP."
  (let ((starts (list 0)) (pos 0))
    (while (string-match (concat "^" regexp) text (1+ pos))
      (setq pos (match-beginning 0))
      (push pos starts))
    (cl-loop for (start end) on (nreverse starts)
             collect (substring text start end))))

(defun agent-review--file-path (header)
  "The path of the file whose diff starts with HEADER."
  (let ((pos 0) path)
    (while (string-match "^\\(?:\\+\\+\\+\\|---\\) \\(.+\\)$" header pos)
      (let ((name (string-remove-suffix "\t" (match-string 1 header))))
        (unless (equal name "/dev/null") (setq path name)))
      (setq pos (match-end 0)))
    (cond
     ((null path)
      (if (string-match "\\`diff --git a/\\(.+\\) b/\\(.+\\)\n" header)
          (match-string 2 header)
        (error "Unsupported file header: %s" (car (split-string header "\n")))))
     ((or (string-prefix-p "\"" path)
          (not (member (substring path 0 (min 2 (length path))) '("a/" "b/"))))
      (error "Quoted or control-character paths are not supported: %s" path))
     (t (substring path 2)))))

(defun agent-review--split-files (text)
  "Split the Git diff TEXT into a list of (:file :header :hunks) per file."
  (unless (string-empty-p text)
    (unless (string-prefix-p "diff --git " text)
      (error "Expected a Git unified diff"))
    (mapcar (lambda (block)
              (let ((sections (agent-review--split-before "@@ " block)))
                (list :file (agent-review--file-path (car sections))
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
  (let ((temp (concat file ".tmp"))
        (print-length nil) (print-level nil) (print-circle nil)
        (coding-system-for-write 'utf-8-emacs-unix))
    (with-temp-buffer
      (prin1 data (current-buffer))
      (write-region nil nil temp nil 'silent))
    (rename-file temp file t)))

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

(defun agent-review--save-comments (id comments)
  "Store COMMENTS as the annotations of the review with ID."
  (agent-review--write (agent-review--path id "comments.eld")
                       (list :review id :comments comments)))

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
           (snapshot (list :id (agent-review--hash full) :root root
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
    (or (agent-review--read file)
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
                     :stats stats)))
          (agent-review--write file review)
          (agent-review--write (agent-review--path "index.eld")
                               (cons (list :id id :title (plist-get review :title) :agent agent
                                           :root (plist-get review :root)
                                           :created (plist-get review :created))
                                     (agent-review--index)))
          review))))

(defun agent-review--item (review id)
  "The item with ID of REVIEW; \"full\" is the whole diff."
  (if (equal id "full")
      (list :id "full" :title "完整 diff"
            :diff (mapconcat (lambda (file) (plist-get file :diff))
                             (plist-get review :full-files) ""))
    (seq-find (lambda (item) (equal (plist-get item :id) id)) (plist-get review :items))))

;;; Annotations

(defun agent-review--comment-id (target)
  "The ID of the annotation on TARGET, a line of an item."
  (agent-review--hash (list (plist-get target :item) (plist-get target :file)
                            (plist-get target :side) (plist-get target :line))))

(defun agent-review--context (review target)
  "Up to three lines around TARGET in its item's diff, as diff text."
  (let* ((side (if (eq (plist-get target :side) 'old) :old :new))
         (file (plist-get target :file))
         (match (lambda (line target) (equal (plist-get line side) (plist-get target :line))))
         ;; Only the lines of the hunk holding TARGET: others may be far away.
         (lines (seq-some
                 (lambda (block)
                   (when (equal (plist-get block :file) file)
                     (seq-some (lambda (hunk)
                                 (let ((lines (agent-review--hunk-lines file hunk)))
                                   (and (seq-position lines target match) lines)))
                               (plist-get block :hunks))))
                 (agent-review--split-files
                  (plist-get (agent-review--item review (plist-get target :item)) :diff))))
         (index (and lines (seq-position lines target match))))
    (if index
        (mapconcat (lambda (line) (concat (string (plist-get line :kind)) (plist-get line :content)))
                   (seq-subseq lines (max 0 (- index 3)) (min (length lines) (+ index 4)))
                   "\n")
      ;; A context line: take the lines around it in the head-side file.
      (when-let* (((eq (plist-get target :side) 'new))
                  (text (alist-get (plist-get target :file) (plist-get review :sources)
                                   nil nil #'equal))
                  (source (vconcat (split-string text "\n")))
                  (n (plist-get target :line)))
        (mapconcat (lambda (i) (concat " " (aref source (1- i))))
                   (number-sequence (max 1 (- n 3)) (min (length source) (+ n 3)))
                   "\n")))))

(defun agent-review-annotate-line (review target text)
  "Store TEXT as the user's annotation on TARGET of REVIEW; return it."
  (let* ((id (agent-review--comment-id target))
         (comments (agent-review--comments (plist-get review :id)))
         (previous (seq-find (lambda (c) (equal (plist-get c :id) id)) comments))
         (comment (list :id id :revision (1+ (or (plist-get previous :revision) 0))
                        :item (plist-get target :item)
                        :item-title (plist-get (agent-review--item review (plist-get target :item))
                                               :title)
                        :file (plist-get target :file)
                        :side (plist-get target :side) :line (plist-get target :line)
                        :code (plist-get target :code)
                        :context (agent-review--context review target)
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

;;; Review buffer

(defvar-local agent-review--review nil "The review shown in this buffer.")
(defvar-local agent-review--full nil "Non-nil to show the full diff instead of the items.")
(defvar-local agent-review--folded nil "IDs of the folded items.")
(defvar-local agent-review--highlighted nil "Cache of highlighted hunks: text -> lines.")
(defvar-local agent-review--context nil "Context lines shown around each hunk.")
(defvar-local agent-review--files nil
  "Per-file data of the review shown: FILE -> (:source VECTOR :added HASH).")

(defcustom agent-review-context 3
  "Lines of the file shown before and after each hunk of an item."
  :type 'natnum)

(defface agent-review-other '((t :inherit shadow :extend t))
  "Context line changed by another item.")

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

(defun agent-review--around (hunk source context from limit)
  "Lines of SOURCE to show around the zero-context HUNK, as (BEFORE . AFTER).
SOURCE is the vector of the file's head-side lines; CONTEXT is how many
lines on each side.  Only new-side lines from FROM and before LIMIT are
used, so context never repeats lines shown elsewhere in the item."
  (pcase-let* ((`(,old ,old-count ,new ,new-count) (agent-review--hunk-range hunk))
               ;; The lines just before and after the hunk on each side.
               (old-prev (if (> old-count 0) (1- old) old))
               (new-prev (if (> new-count 0) (1- new) new))
               (old-next (1+ (if (> old-count 0) (+ old old-count -1) old)))
               (new-next (1+ (if (> new-count 0) (+ new new-count -1) new)))
               (line (lambda (n offset)
                       (list :kind ?\s :content (aref source (1- n)) :old (+ n offset)
                             :new n :newline t :context t))))
    (if (or (null source) (zerop context))
        (cons nil nil)
      (cons (cl-loop for n from (max 1 from (- new-prev context -1))
                     to (min new-prev (length source))
                     collect (funcall line n (- old-prev new-prev)))
            (cl-loop for n from (max from new-next)
                     to (min (length source) (+ new-next context -1) (1- limit))
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

(defun agent-review--insert-comment (comment)
  "Insert the annotation COMMENT and its answer below its line."
  (let ((start (point))
        (bar (propertize "  ┃ " 'face 'agent-review-comment)))
    (insert bar
            (propertize (format "标注 · %s" (alist-get (plist-get comment :status)
                                                       agent-review-statuses nil nil #'equal))
                        'face '(bold agent-review-comment))
            "\n")
    (dolist (line (split-string (plist-get comment :comment) "\n"))
      (insert bar line "\n"))
    (when-let* ((response (plist-get comment :response)))
      (insert bar (propertize "agent 回应" 'face '(bold agent-review-response)) "\n")
      (dolist (line (split-string response "\n"))
        (insert bar (propertize line 'face 'agent-review-response) "\n")))
    (put-text-property start (point) 'agent-review-comment (plist-get comment :id))))

(defun agent-review--insert-hunk (item file hunk comments width around)
  "Insert HUNK of FILE in ITEM, with COMMENTS under their lines.
WIDTH is the width of the line number columns; AROUND is the context to
show, see `agent-review--around'."
  (let* ((lines (append (car around) (agent-review--hunk-lines file hunk) (cdr around)))
         (codes (agent-review--highlight file lines))
         (data (gethash file agent-review--files))
         (added (plist-get data :added))
         (number (format "%%%ds %%%ds " width width)))
    ;; Context comes from the head-side file; other items' changes around
    ;; the hunk shift the old-side numbers, so take them from the full diff.
    (when data
      (dolist (line lines)
        (when (plist-get line :context)
          (plist-put line :old (agent-review--old-line data (plist-get line :new))))))
    (insert (propertize (concat (car (split-string hunk "\n")) "\n") 'face 'agent-review-hunk))
    (cl-loop
     for line in lines
     for code in codes
     do (let* ((kind (plist-get line :kind))
               (side (if (eq kind ?-) 'old 'new))
               (target (list :item (plist-get item :id) :file file :side side
                             :line (plist-get line (if (eq side 'old) :old :new))
                             :code (plist-get line :content)))
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
            (when face (add-face-text-property code-start (point) face t)))
          (when-let* ((comment (gethash (agent-review--comment-id target) comments)))
            (agent-review--insert-comment comment))
          (put-text-property start (point) 'agent-review-target target)))))

(defun agent-review--insert-item (item comments width)
  "Insert ITEM: its heading, intent and diff, with COMMENTS under their lines.
WIDTH is the width of the line number columns."
  (let ((id (plist-get item :id)))
    (insert (propertize (if (equal id "full")
                            "完整 diff\n"
                          (format "%d. [%s] %s\n" (plist-get item :order)
                                  (alist-get (plist-get item :type) agent-review-types)
                                  (plist-get item :title)))
                        'face 'agent-review-item
                        'agent-review-heading id))
    (let ((body (point)))
      (when-let* ((intent (plist-get item :intent)))
        (insert intent "\n"))
      (dolist (block (agent-review--split-files (plist-get item :diff)))
        (let* ((file (plist-get block :file))
               (source (plist-get (gethash file agent-review--files) :source))
               ;; The full diff has its own context.
               (context (if (equal id "full") 0 agent-review--context))
               (from 1))
          (insert "\n" (propertize (concat file "\n") 'face 'agent-review-file))
          (if (plist-get block :hunks)
              (cl-loop
               for (hunk next) on (plist-get block :hunks)
               do (let ((around (agent-review--around
                                 hunk source context from
                                 (if next
                                     (pcase-let ((`(,_ ,_ ,new ,count)
                                                  (agent-review--hunk-range next)))
                                       (if (> count 0) new (1+ new)))
                                   most-positive-fixnum))))
                    (agent-review--insert-hunk item file hunk comments width around)
                    (setq from (1+ (if (cdr around)
                                       (plist-get (car (last (cdr around))) :new)
                                     (pcase-let ((`(,_ ,_ ,new ,count)
                                                  (agent-review--hunk-range hunk)))
                                       (if (> count 0) (+ new count -1) new)))))))
            ;; Binary or metadata-only: show what git says about the file.
            (insert (propertize (string-join (cdr (split-string (plist-get block :header) "\n"))
                                             "\n")
                                'face 'agent-review-meta)))))
      (insert "\n")
      (let ((overlay (make-overlay body (point))))
        (overlay-put overlay 'agent-review-body id)
        (overlay-put overlay 'evaporate t)
        (overlay-put overlay 'invisible (and (member id agent-review--folded) t))))))

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
         (by-id (make-hash-table :test #'equal))
         (items (if agent-review--full
                    (list (agent-review--item review "full"))
                  (plist-get review :items)))
         (files (or agent-review--files
                    (setq agent-review--files (agent-review--file-data review))))
         (width (agent-review--number-width review files)))
    (unless agent-review--context (setq agent-review--context agent-review-context))
    (dolist (comment comments) (puthash (plist-get comment :id) comment by-id))
    (insert (propertize (plist-get review :title) 'face 'agent-review-title) "\n"
            (propertize (format "%s %s → %s %s · %d 个文件 · +%d −%d · %d 项\n"
                                (plist-get review :target-ref)
                                (substring (plist-get review :base-sha) 0 10)
                                (plist-get review :head-ref)
                                (substring (plist-get review :head-sha) 0 10)
                                (plist-get stats :files) (plist-get stats :additions)
                                (plist-get stats :deletions) (plist-get stats :items))
                        'face 'agent-review-meta)
            (propertize (format "标注 %d 条，待回应 %d 条 · a 标注  s 请 agent 回应  \
TAB 折叠  f %s  RET 打开文件\n"
                                (length comments)
                                (seq-count (lambda (c) (equal (plist-get c :status) "open"))
                                           comments)
                                (if agent-review--full "按审查项查看" "完整 diff"))
                        'face 'agent-review-meta)
            "\n" (propertize "本次变更概览\n" 'face 'agent-review-heading)
            (plist-get review :summary) "\n\n")
    (dolist (item items)
      (agent-review--insert-item item by-id width))))

(defun agent-review--redraw ()
  "Redraw this review buffer, keeping point on the same line."
  (let ((line (line-number-at-pos))
        (column (current-column))
        (windows (mapcar (lambda (w) (cons w (window-start w)))
                         (get-buffer-window-list nil nil t)))
        (inhibit-read-only t))
    (erase-buffer)
    (agent-review--render)
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    (pcase-dolist (`(,window . ,start) windows)
      (set-window-start window (min start (point-max)) t)
      (set-window-point window (point)))))

(defun agent-review--buffers (id)
  "Live buffers showing the review with ID."
  (seq-filter (lambda (buffer)
                (equal (plist-get (buffer-local-value 'agent-review--review buffer) :id) id))
              (buffer-list)))

(defun agent-review--refresh (id)
  "Redraw every buffer showing the review with ID."
  (dolist (buffer (agent-review--buffers id))
    (with-current-buffer buffer (agent-review--redraw))))

(defun agent-review-show (review)
  "Show REVIEW in its buffer, without selecting it; return the buffer."
  (let ((buffer (or (car (agent-review--buffers (plist-get review :id)))
                    (generate-new-buffer (format "*review: %s*" (plist-get review :title))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-review-mode) (agent-review-mode))
      (setq agent-review--review review)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (agent-review--render))
      (goto-char (point-min)))
    (agent-ui--show-buffer buffer)
    buffer))

;;; Commands

(defun agent-review--target ()
  "The review line at point."
  (or (get-text-property (point) 'agent-review-target)
      (user-error "这里不是代码行")))

(defun agent-review--comment-at ()
  "The annotation on the line at point, or nil."
  (when-let* ((target (get-text-property (point) 'agent-review-target)))
    (let ((id (agent-review--comment-id target)))
      (seq-find (lambda (c) (equal (plist-get c :id) id))
                (agent-review--comments (plist-get agent-review--review :id))))))

(defun agent-review-annotate ()
  "Annotate the code line at point, or edit its annotation."
  (interactive)
  (let* ((target (agent-review--target))
         (old (agent-review--comment-at))
         (text (string-trim (read-string (if old "修改标注：" "标注：")
                                         (plist-get old :comment)))))
    (when (string-empty-p text) (user-error "标注是空的"))
    (agent-review-annotate-line agent-review--review target text)
    (agent-review--refresh (plist-get agent-review--review :id))
    (message "已保存标注；按 s 请 agent 回应")))

(defun agent-review-delete-annotation ()
  "Delete the annotation on the line at point."
  (interactive)
  (let ((comment (or (agent-review--comment-at) (user-error "这一行没有标注")))
        (id (plist-get agent-review--review :id)))
    (when (yes-or-no-p "删除这条标注？")
      (agent-review--save-comments id (remove comment (agent-review--comments id)))
      (agent-review--refresh id))))

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

(defun agent-review-ask ()
  "Ask the session that made this review to answer the pending annotations."
  (interactive)
  (let* ((review agent-review--review)
         (pending (seq-count (lambda (c) (equal (plist-get c :status) "open"))
                             (agent-review--comments (plist-get review :id)))))
    (when (zerop pending) (user-error "没有待回应的标注"))
    (let ((buffer (agent-review--session-buffer review)))
      (agent-session-submit (buffer-local-value 'agent-session--current buffer)
                            (format "请回应原子审查「%s」中 %d 条待回应的标注（review_comments review=%s）。"
                                    (plist-get review :title) pending (plist-get review :id)))
      (agent-session-display buffer))))

(defun agent-review-visit ()
  "Visit the line at point: the project file, or the base version of a removed line."
  (interactive)
  (let* ((target (agent-review--target))
         (review agent-review--review)
         (root (plist-get review :root))
         (file (plist-get target :file)))
    (if (eq (plist-get target :side) 'new)
        (let ((path (agent-session-expand-file-name file root)))
          (unless (file-exists-p path) (user-error "工作区里没有 %s" file))
          (pop-to-buffer (find-file-noselect path)))
      (let ((buffer (get-buffer-create (format "*review-base: %s*" file)))
            (text (agent-review--git root "show" (format "%s:%s" (plist-get review :base-sha) file))))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert text))
          (when-let* ((mode (agent-review--file-mode file)))
            (let ((treesit-auto-install-grammar nil)) (ignore-errors (funcall mode))))
          (setq buffer-read-only t))
        (pop-to-buffer buffer)))
    (goto-char (point-min))
    (forward-line (1- (plist-get target :line)))))

(defun agent-review-toggle ()
  "Fold or unfold the item at point."
  (interactive)
  (let* ((id (or (get-text-property (point) 'agent-review-heading)
                 (seq-some (lambda (o) (overlay-get o 'agent-review-body)) (overlays-at (point)))
                 (user-error "这里不在审查项里")))
         (overlay (seq-find (lambda (o) (equal (overlay-get o 'agent-review-body) id))
                            (overlays-in (point-min) (point-max))))
         (fold (not (overlay-get overlay 'invisible))))
    (overlay-put overlay 'invisible fold)
    (setq agent-review--folded (if fold (cons id agent-review--folded)
                                 (remove id agent-review--folded)))
    (when fold
      (goto-char (overlay-start overlay))
      (forward-line -1))))

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
  "Move to the next annotation."
  (interactive)
  (agent-review--move 'agent-review-comment t))

(defun agent-review-previous-annotation ()
  "Move to the previous annotation."
  (interactive)
  (agent-review--move 'agent-review-comment nil))

(defun agent-review-toggle-full ()
  "Switch between the items and the full diff."
  (interactive)
  (setq agent-review--full (not agent-review--full))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (agent-review--render))
  (goto-char (point-min)))

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
  "s" #'agent-review-ask
  "RET" #'agent-review-visit
  "f" #'agent-review-toggle-full
  "+" #'agent-review-more-context
  "-" #'agent-review-less-context)

(define-derived-mode agent-review-mode special-mode "Review"
  "Review the atomic items of a branch's changes and annotate their lines."
  (setq-local truncate-lines nil
              word-wrap t
              revert-buffer-function (lambda (&rest _) (agent-review--redraw))))

;;; Methods

(defun agent-review--json-bool (value)
  "VALUE as a JSON boolean."
  (if value t :false))

(defun agent-review--json-comment (comment)
  "The annotation COMMENT as JSON for an agent."
  (list :id (plist-get comment :id) :revision (plist-get comment :revision)
        :status (plist-get comment :status)
        :item (plist-get comment :item) :item_title (plist-get comment :item-title)
        :file (plist-get comment :file) :side (symbol-name (plist-get comment :side))
        :line (plist-get comment :line) :code (plist-get comment :code)
        :context (agent-ui--json-value (plist-get comment :context))
        :comment (plist-get comment :comment)
        :response (agent-ui--json-value (plist-get comment :response))))

(agent-ui-defmethod "review_snapshot"
    ((base string "Branch, tag or commit to compare against, e.g. main or origin/main" required)
     (head string "Branch or commit under review. Default: HEAD"))
  "Start an atomic review (原子审查) of a branch: pin the committed changes of head against its merge base with base, and list their hunks. Use it when the user asks for an atomic review of a branch or MR; the review is shown in Emacs, where the user annotates lines. Only committed changes are compared, never uncommitted files. For \"against main\", check whether local main or origin/main is meant; fetch first when origin is needed.

Then:
1. Read the hunks (fragments, or the output of diff_command when the diff is too large to return) and the sources at head_sha (git show <head_sha>:path when the worktree may differ). Understand the code yourself; no other model is involved.
2. Split the changes by independent intent into items. Order: foundations and core logic first, then call sites, then tests. Related tests may form an item of their own; upstream test corpora are grouped by case or package. Never group by an arbitrary number of lines, and never pack unrelated abilities into one big item.
3. Call review_build with the snapshot id, a summary and the items:
   - summary: the overview at the top of the review, for the whole compared change (not one commit or item): the problem it solves, behavior before and after, user-visible effects, main risks if any. A few sentences.
   - each item: {\"title\", \"intent\", \"type\", \"parts\"}. intent explains, from the source, why the change is made and the inputs, outputs and edge cases of the functions it touches. type: 0 formatting, 1 refactoring, 2 feature, 3 local fix, 5 tests.
   - each part names a file of this snapshot and selects exactly one of: \"hunks\": [0, 2] (zero-based hunk indexes within that file, as listed here); \"whole\": true (all its hunks, or a binary/metadata-only file); \"added_lines\": [10, 45] (inclusive line range of a newly added text file only: split it along declarations, functions or test cases, assigning headers, imports and blank lines too).
   Example: {\"title\": \"保留调用实参中的命名类型\", \"intent\": \"…\", \"type\": 3, \"parts\": [{\"file\": \"compiler/typeck/src/call.rs\", \"hunks\": [0, 3]}]}
Every changed line must be covered exactly once. When review_build reports a coverage error, fix the plan; never drop changes that are hard to place. Write titles, intents and the summary in Chinese. The split is a static reading of the diff: never describe it as tested."
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
  "Assemble your plan for a snapshot (item format: see review_snapshot), check that every changed line is covered exactly once, and show the review in Emacs. Building the same plan again reopens the existing review with its annotations; a changed plan makes a new review and leaves the old one. Afterwards give the user the base/head and a short result, and tell them to annotate lines in the review buffer (a on a line) and press s when they want you to answer. Do not wait or poll for annotations."
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
  "Read the user's annotations of atomic reviews: item, file, side (old: removed line at the merge base, new: line at head), line, the code and its diff context, revision and the user's text. Treat them as the user's review comments: check each against the pinned commits, answer in this session, and write the same answer to the review with review_reply. Answering is not permission to change the code; change it only when the user asks."
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
  "Answer an annotation in its review; the review buffer shows it at once. A revision conflict means the user edited the annotation after you read it: read it again with review_comments and answer the new text. Use status resolved only when the issue is actually fixed or the user asks."
  (let ((answered (agent-review-reply review id revision text status)))
    (agent-review--refresh review)
    (list :id id :status (plist-get answered :status))))

(provide 'agent-review)

;; Method descriptions are written for agents and are not wrapped at 80
;; columns.
;; Local Variables:
;; byte-compile-docstring-max-column: 2000
;; End:

;;; agent-review.el ends here
