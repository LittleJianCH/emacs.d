;;; init-kb-test.el --- Knowledge base tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise the knowledge base on temporary directories and databases:
;; creation, capture, relations, labelled backlinks, the table, catching up
;; with external changes, and the batch validator and exporter (real
;; subprocesses).  The module is loaded with `my/kb-directory' pointing at a
;; temporary directory, so the real ~/kb and var/org-roam.db are never
;; touched.  Skipped unless org-roam is installed; nothing is installed.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'package)

(defvar my/kb-directory)
(defvar my/kb-publish-directory)
(defvar my/kb-publish-cache-directory)
(defvar my/kb-sync--queue)
(defvar my/kb-sync--queued)
(defvar my/kb-sync--indexed)
(defvar my/kb-sync--timer)
(defvar my/kb-sync--rebuild)
(defvar my/kb--publish)
(defvar my/kb-sync-rebuild-threshold)
(defvar my/kb-sync-updated-hook)
(defvar my/kb-level-change-confirms)
(defvar org-roam-directory)
(defvar org-roam-db-location)
(defvar org-id-track-globally)
(defvar org-id-locations-file)

(defconst init-kb-test--state (make-temp-file "kb-ert-" t)
  "Temporary directory for the module's startup knowledge base.")

(defconst init-kb-test--available (package-installed-p 'org-roam)
  "Non-nil if org-roam is installed, so the module can load.")

(when init-kb-test--available
  (setq my/kb-directory (expand-file-name "startup-kb/" init-kb-test--state)
        org-id-track-globally nil
        org-id-locations-file (expand-file-name "org-id-locations"
                                                init-kb-test--state))
  (require 'init-kb)
  ;; use-package set the real database; nothing has opened it yet.
  (setq org-roam-db-location (expand-file-name "startup.db" init-kb-test--state))
  (my/kb-sync-stop))

(add-hook 'kill-emacs-hook
          (lambda () (delete-directory init-kb-test--state t)))

(defun init-kb-test--write (root file &rest lines)
  "Write LINES to FILE under ROOT and return its absolute name."
  (let ((file (expand-file-name file root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (string-join lines "\n") "\n"))
    file))

(defun init-kb-test--concept (root slug id title &rest body)
  "Write the concept SLUG with ID and TITLE under ROOT, followed by BODY lines.
LEVEL is exposed and CONFIRMED nil."
  (apply #'init-kb-test--write root (format "concepts/%s.org" slug)
         ":PROPERTIES:" (format ":ID:       %s" id) ":LEVEL:    exposed"
         ":CONFIRMED: nil" ":UPDATED:  [2026-01-01]" ":END:"
         (format "#+title: %s" title) "#+filetags: :tt:" "" "* Notes" "- note"
         body))

(defun init-kb-test--file-string (file)
  "Return the contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun init-kb-test--delete (file)
  "Delete FILE the way another program would.
`delete-file' itself tells org-roam, through autosync's advice."
  (should (zerop (call-process "rm" nil nil nil "-f" file))))

(defun init-kb-test--drain ()
  "Index every queued file now, without timers."
  (while my/kb-sync--queue
    (when (timerp my/kb-sync--timer)
      (cancel-timer my/kb-sync--timer)
      (setq my/kb-sync--timer nil))
    (my/kb-sync--drain))
  (when (timerp my/kb-sync--timer)
    (cancel-timer my/kb-sync--timer)
    (setq my/kb-sync--timer nil)))

(defun init-kb-test--index (&rest files)
  "Index FILES in the database at once."
  (dolist (file files)
    (org-roam-db-update-file file)))

(defun init-kb-test--wait (predicate &optional seconds)
  "Wait up to SECONDS (default 120) for PREDICATE to return non-nil."
  (let ((deadline (time-add nil (or seconds 120))))
    (while (and (not (funcall predicate)) (time-less-p nil deadline))
      (accept-process-output nil 0.1))
    (funcall predicate)))

(defmacro init-kb-test--with-kb (&rest body)
  "Run BODY with an empty knowledge base and database, bound to `root'."
  (declare (indent 0) (debug t))
  `(progn
     (unless init-kb-test--available (ert-skip "org-roam is not installed"))
     (let* ((root (file-name-as-directory
                   (file-truename (make-temp-file "kb-test-" t))))
            (state (make-temp-file "kb-test-state-" t))
            (my/kb-directory root)
            (org-roam-directory root)
            (org-roam-db-location (expand-file-name "org-roam.db" state))
            (my/kb-publish-directory (expand-file-name "site/" state))
            (my/kb-publish-cache-directory (expand-file-name "cache/" state))
            (my/kb-sync--queue nil)
            (my/kb-sync--queued (make-hash-table :test #'equal))
            (my/kb-sync--indexed nil)
            (my/kb-sync-updated-hook nil))
       (ignore root)
       (make-directory (expand-file-name "concepts" root))
       (make-directory (expand-file-name "sessions" root))
       (unwind-protect (progn ,@body)
         (when (timerp (bound-and-true-p my/kb-sync--timer))
           (cancel-timer my/kb-sync--timer)
           (setq my/kb-sync--timer nil))
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (string-prefix-p root (file-truename (buffer-file-name buffer))))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (when-let* ((table (get-buffer "*知识库*"))) (kill-buffer table))
         (org-roam-db--close-all)
         (delete-directory root t)
         (delete-directory state t)))))

(defun init-kb-test--batch (function &rest args)
  "Run FUNCTION of kb-batch.el in a subprocess with ARGS.
Return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((status (apply #'call-process (car (my/kb--batch-command function))
                         nil t nil
                         (append (cdr (my/kb--batch-command function)) args))))
      (cons status (buffer-string)))))

;;; Creation

(ert-deftest init-kb-bootstrap-creates-two-related-concepts ()
  "A missing knowledge base gets two valid concepts relating to each other;
an existing one is left alone."
  (init-kb-test--with-kb
    (let ((my/kb-directory (expand-file-name "new/" root)))
      (my/kb-bootstrap)
      (let ((files (directory-files (expand-file-name "concepts" my/kb-directory)
                                    t "\\.org\\'")))
        (should (= (length files) 2))
        (should (file-directory-p (expand-file-name "sessions" my/kb-directory)))
        (let ((texts (mapcar #'init-kb-test--file-string files)))
          (should (cl-some (lambda (text) (string-match-p "^- requires :: \\[\\[id:" text))
                           texts))
          (should (cl-some (lambda (text)
                             (string-match-p "^- prerequisite_of :: \\[\\[id:" text))
                           texts))
          (dolist (text texts)
            (should (string-prefix-p ":PROPERTIES:\n:ID:" text))))
        ;; The examples follow the format the validator checks.
        (let ((result (init-kb-test--batch "my/kb-batch-check" my/kb-directory)))
          (should (equal (car result) 0))
          (should (string-match-p "0 个错误，0 个警告" (cdr result)))))
      ;; Let git init finish before the directory goes.
      (init-kb-test--wait (lambda () (file-directory-p
                                      (expand-file-name ".git" my/kb-directory)))
                          10)
      (let ((marker (init-kb-test--write my/kb-directory "concepts/mine.org" "x")))
        (my/kb-bootstrap)
        (should (equal (init-kb-test--file-string marker) "x\n"))
        (should (= (length (directory-files (expand-file-name "concepts" my/kb-directory)
                                            nil "\\.org\\'"))
                   3))))))

(ert-deftest init-kb-capture-fills-the-property-drawer ()
  "A captured concept has one top drawer, ID first, with the defaults."
  (init-kb-test--with-kb
    (org-roam-capture- :keys "c"
                       :node (org-roam-node-create :title "Cubical Type Theory")
                       :props '(:immediate-finish t))
    (let* ((file (expand-file-name "concepts/cubical_type_theory.org" root))
           (text (init-kb-test--file-string file)))
      (should (string-match-p
               (concat "\\`:PROPERTIES:\n:ID: +[-0-9a-f]+\n:LEVEL: +exposed\n"
                       ":CONFIRMED: nil\n:UPDATED: +\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\]\n"
                       ":END:\n#\\+title: Cubical Type Theory\n")
               text))
      (should (= (cl-count-if (lambda (line) (equal line ":PROPERTIES:"))
                              (split-string text "\n"))
                 1))
      (should (string-match-p "^\\* Notes$" text))
      (should (string-match-p "^\\* Relations$" text)))))

(ert-deftest init-kb-session-capture-records-ai-and-concepts ()
  "A session is a heading of today's file in sessions/, asking only for
the topic and AI; concepts are added one per call, also while capturing,
without duplicates.  No prompt asks to end a list."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha"))
          (b (init-kb-test--concept root "b" "id-b" "Beta"))
          prompts)
      (init-kb-test--index a b)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt &rest _)
                   (push prompt prompts)
                   (if (string-match-p "AI" prompt) "chatgpt" "NbE"))))
        (org-roam-dailies-capture-today))
      (should (= (length prompts) 2))
      (should-not (cl-some (lambda (prompt) (string-match-p "概念" prompt)) prompts))
      ;; In the capture buffer, the body of the new heading.
      (my/kb-session-add-concept (org-roam-node-from-id "id-a"))
      (my/kb-session-add-concept (org-roam-node-from-id "id-b"))
      (my/kb-session-add-concept (org-roam-node-from-id "id-a"))
      (org-capture-finalize)
      (let* ((file (expand-file-name (format-time-string "sessions/%Y-%m-%d.org") root))
             (text (init-kb-test--file-string file)))
        (should (string-match-p
                 (concat "^\\* [0-9][0-9]:[0-9][0-9] NbE\n:PROPERTIES:\n:AI: +chatgpt\n"
                         ":CONCEPTS: \\[\\[id:id-a\\]\\[Alpha\\]\\] "
                         "\\[\\[id:id-b\\]\\[Beta\\]\\]\n:END:")
                 text))
        (should (string-match-p (format-time-string "^#\\+title: %Y-%m-%d$") text))))))

(ert-deftest init-kb-session-add-concept-needs-a-session ()
  "Outside a session heading the command explains where to use it."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha"))
          (s (init-kb-test--write root "sessions/2026-11-12.org"
                                  ":PROPERTIES:" ":ID:       id-s" ":END:"
                                  "#+title: 2026-11-12" "" "* 10:00 NbE" "** detail" "text")))
      (init-kb-test--index a s)
      (with-current-buffer (find-file-noselect a)
        (should-error (my/kb-session-add-concept (org-roam-node-from-id "id-a"))
                      :type 'user-error))
      (with-current-buffer (find-file-noselect s)
        (goto-char (point-min))
        (should-error (my/kb-session-add-concept (org-roam-node-from-id "id-a"))
                      :type 'user-error)
        ;; From a subheading, the session is its top-level heading.
        (goto-char (point-max))
        (my/kb-session-add-concept (org-roam-node-from-id "id-a"))
        (goto-char (point-min))
        (should (re-search-forward
                 "^\\* 10:00 NbE\n:PROPERTIES:\n:CONCEPTS: \\[\\[id:id-a\\]\\[Alpha\\]\\]\n:END:"
                 nil t))))))

;;; Relations

(ert-deftest init-kb-relation-add-appends-to-the-relations-section ()
  "The item lands last in Relations, before the next heading; a missing
section is created, and a repeated relation is refused."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha"
                                    "" "* Relations" "- related :: [[id:id-c][Gamma]]"
                                    "" "* Later" "text"))
          (b (init-kb-test--concept root "b" "id-b" "Beta"))
          (c (init-kb-test--concept root "c" "id-c" "Gamma")))
      (init-kb-test--index a b c)
      (my/kb-relation-add a "requires" (org-roam-node-from-id "id-b"))
      (should (string-match-p
               (concat "\\* Relations\n- related :: \\[\\[id:id-c\\]\\[Gamma\\]\\]\n"
                       "- requires :: \\[\\[id:id-b\\]\\[Beta\\]\\]\n\n\\* Later")
               (init-kb-test--file-string a)))
      ;; Saved and indexed: the database knows the new link.
      (should (member "id-a" (mapcar #'car (org-roam-db-query
                                            [:select source :from links
                                             :where (= dest $s1)]
                                            "id-b"))))
      (should-error (my/kb-relation-add a "requires" (org-roam-node-from-id "id-b"))
                    :type 'user-error)
      (my/kb-relation-add b "prerequisite_of" (org-roam-node-from-id "id-a"))
      (should (string-match-p
               "\n\\* Relations\n- prerequisite_of :: \\[\\[id:id-a\\]\\[Alpha\\]\\]\n\\'"
               (init-kb-test--file-string b))))))

(ert-deftest init-kb-relation-add-in-the-concept-buffer-leaves-it-unsaved ()
  "In the concept's own buffer the item is inserted at point, like a link."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha" "" "* Relations"))
          (b (init-kb-test--concept root "b" "id-b" "Beta")))
      (init-kb-test--index a b)
      (with-current-buffer (find-file-noselect a)
        (goto-char (point-min))
        (my/kb-relation-add a "generalizes" (org-roam-node-from-id "id-b"))
        (should (buffer-modified-p))
        (should (looking-at-p "- generalizes :: \\[\\[id:id-b\\]\\[Beta\\]\\]"))
        (should-not (string-match-p "generalizes" (init-kb-test--file-string a)))))))

;;; Backlinks

(ert-deftest init-kb-backlinks-show-the-relation-name ()
  "Each backlink is labelled: relation names first, then sessions and links."
  (init-kb-test--with-kb
    (let ((target (init-kb-test--concept root "t" "id-t" "Target"))
          (user (init-kb-test--concept root "u" "id-u" "User"
                                       "" "* Relations" "- requires :: [[id:id-t][Target]]"))
          (general (init-kb-test--concept root "g" "id-g" "General"
                                          "" "* Relations"
                                          "- generalizes :: [[id:id-t][Target]]"))
          (mention (init-kb-test--concept root "m" "id-m" "Mention"
                                          "- see [[id:id-t][Target]]"))
          (session (init-kb-test--write root "sessions/2026-11-12.org"
                                        ":PROPERTIES:" ":ID:       id-s" ":END:"
                                        "#+title: 2026-11-12" ""
                                        "* 10:00 NbE" ":PROPERTIES:" ":AI:       claude"
                                        ":CONCEPTS: [[id:id-t][Target]]" ":END:")))
      (init-kb-test--index target user general mention session)
      (let ((text (with-temp-buffer
                    (org-roam-mode)
                    (let ((inhibit-read-only t))
                      (magit-insert-section (org-roam)
                        (my/kb-backlinks-section (org-roam-node-from-id "id-t"))))
                    (buffer-substring-no-properties (point-min) (point-max)))))
        (should (string-match-p "^\\[requires\\] User " text))
        (should (string-match-p "^\\[generalizes\\] General " text))
        (should (string-match-p "^\\[学习记录\\] 2026-11-12 " text))
        (should (string-match-p "^\\[链接\\] Mention " text))
        ;; Relations in the order of `my/kb-relations', then the rest.
        (should (< (string-match "\\[requires\\]" text)
                   (string-match "\\[generalizes\\]" text)
                   (string-match "\\[学习记录\\]" text)
                   (string-match "\\[链接\\]" text)))))))

;;; Table

(defun init-kb-test--row (title)
  "Move to the table row of TITLE."
  (goto-char (point-min))
  (should (search-forward title nil t))
  (beginning-of-line))

(ert-deftest init-kb-table-reads-the-database ()
  "Rows come from the database (a rewritten file shows until indexed),
LEVEL sorts by rank, and the filter keeps unconfirmed concepts."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha"))
          (b (init-kb-test--write root "concepts/b.org"
                                  ":PROPERTIES:" ":ID:       id-b" ":LEVEL:    implemented"
                                  ":CONFIRMED: t" ":UPDATED:  [2026-02-02]" ":END:"
                                  "#+title: Beta"))
          (s (init-kb-test--write root "sessions/2026-11-12.org"
                                  ":PROPERTIES:" ":ID:       id-s" ":END:"
                                  "#+title: 2026-11-12")))
      (init-kb-test--index a b s)
      ;; Rewritten, not yet indexed: the table shows the database.
      (with-temp-file a (insert "#+title: Changed\n"))
      (my/kb-table)
      (with-current-buffer "*知识库*"
        (should (derived-mode-p 'my/kb-table-mode))
        (should (equal (sort (mapcar #'car tabulated-list-entries))
                       '("id-a" "id-b")))
        (init-kb-test--row "Beta")
        (should (string-match-p "implemented +已确认 +2026-02-02 +tt\\|implemented +已确认 +2026-02-02"
                                (buffer-substring (point) (line-end-position))))
        (should (my/kb-table--level< (assoc "id-a" tabulated-list-entries)
                                     (assoc "id-b" tabulated-list-entries)))
        (my/kb-table-toggle-unconfirmed)
        (should (equal (mapcar #'car tabulated-list-entries) '("id-a")))
        (my/kb-table-toggle-unconfirmed)
        (should (= (length tabulated-list-entries) 2))))))

(ert-deftest init-kb-table-writes-level-and-confirmation-back ()
  "Raising, lowering and confirming write the top drawer and UPDATED,
update the database and the row in place."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha"))
          (today (format-time-string "[%Y-%m-%d]")))
      (init-kb-test--index a)
      (my/kb-table)
      (with-current-buffer "*知识库*"
        (init-kb-test--row "Alpha")
        (let ((my/kb-level-change-confirms nil))
          (my/kb-table-raise))
        (let ((text (init-kb-test--file-string a)))
          (should (string-match-p "^:LEVEL: +walked-through$" text))
          (should (string-match-p "^:CONFIRMED: nil$" text))
          (should (string-match-p (concat "^:UPDATED: +" (regexp-quote today) "$") text))
          ;; Still one drawer, before the title.
          (should (string-prefix-p ":PROPERTIES:\n:ID:" text)))
        (should (string-match-p "walked-through +待确认"
                                (buffer-substring (point) (line-end-position))))
        (should (equal (plist-get (car (my/kb-concepts)) :level) "walked-through"))
        (my/kb-table-lower)
        (should (string-match-p "^:LEVEL: +exposed$" (init-kb-test--file-string a)))
        (should (string-match-p "^:CONFIRMED: t$" (init-kb-test--file-string a)))
        (should-error (my/kb-table-lower) :type 'user-error)
        (let ((last-command-event ?4))
          (call-interactively #'my/kb-table-set-level))
        (should (string-match-p "^:LEVEL: +can-apply$" (init-kb-test--file-string a)))
        ;; From M-x, the level is read.
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "implemented")))
          (let ((last-command-event ?\r))
            (call-interactively #'my/kb-table-set-level)))
        (should (string-match-p "^:LEVEL: +implemented$" (init-kb-test--file-string a)))
        (init-kb-test--row "Alpha")
        (my/kb-table-confirm)
        (should (string-match-p "^:CONFIRMED: nil$" (init-kb-test--file-string a)))
        (should (equal (plist-get (car (my/kb-concepts)) :confirmed) "nil"))
        (init-kb-test--row "Alpha")
        (my/kb-table-confirm)
        (should (string-match-p "^:CONFIRMED: t$" (init-kb-test--file-string a)))))))

(ert-deftest init-kb-edit-refuses-a-modified-buffer ()
  "Unsaved changes of a visiting buffer are never saved behind my back."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha")))
      (init-kb-test--index a)
      (with-current-buffer (find-file-noselect a)
        (goto-char (point-max))
        (insert "draft\n")
        (should-error (my/kb-set-properties a '(("LEVEL" . "can-apply")))
                      :type 'user-error)
        (should-not (string-match-p "draft\\|can-apply" (init-kb-test--file-string a)))))))

;;; Following external changes

(ert-deftest init-kb-scan-follows-external-changes ()
  "Changed, new and deleted files are found by modification time and
indexed; afterwards a scan finds nothing, also for a file only touched."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha"))
          (b (init-kb-test--concept root "b" "id-b" "Beta"))
          (later (time-add nil 10))
          updated)
      (init-kb-test--index a b)
      (should-not (my/kb-sync--changed-files))
      (add-hook 'my/kb-sync-updated-hook (lambda (files) (setq updated files)))
      ;; An agent rewrites a, creates c, deletes b.
      (with-temp-file a
        (insert (string-replace "exposed" "can-apply" (init-kb-test--file-string a))))
      (set-file-times a later)
      (let ((c (init-kb-test--concept root "c" "id-c" "Gamma")))
        (init-kb-test--delete b)
        (should (equal (sort (my/kb-sync--changed-files)) (sort (list a b c))))
        (my/kb-sync-scan)
        (init-kb-test--drain)
        (should (equal (sort updated) (sort (list a b c))))
        (let ((concepts (my/kb-concepts)))
          (should (equal (sort (mapcar (lambda (concept) (plist-get concept :id)) concepts))
                         '("id-a" "id-c")))
          (should (equal (plist-get (seq-find (lambda (concept)
                                                (equal (plist-get concept :id) "id-a"))
                                              concepts)
                                    :level)
                         "can-apply")))
        (should-not (my/kb-sync--changed-files))
        ;; Touched, not changed: indexed once, then quiet, and no update.
        (setq updated 'none)
        (set-file-times c (time-add later 10))
        (should (equal (my/kb-sync--changed-files) (list c)))
        (my/kb-sync-scan)
        (init-kb-test--drain)
        (should (eq updated 'none))
        (should-not (my/kb-sync--changed-files))))))

(ert-deftest init-kb-scan-skips-hidden-and-temporary-files ()
  "Only Org files of the knowledge base are queued, never git's or locks."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha")))
      (init-kb-test--write root ".git/x.org" "x")
      (init-kb-test--write root "concepts/.#a.org" "x")
      (init-kb-test--write root "concepts/#a.org#" "x")
      (init-kb-test--write root "concepts/notes.txt" "x")
      (should (equal (my/kb-sync--changed-files) (list a))))))

(ert-deftest init-kb-scan-rebuilds-in-a-subprocess-when-many-changed ()
  "Past the threshold, a batch Emacs builds the database, which then
replaces the current one."
  (init-kb-test--with-kb
    (dotimes (i 4)
      (init-kb-test--concept root (format "c%d" i) (format "id-%d" i)
                             (format "Concept %d" i)))
    (let ((my/kb-sync-rebuild-threshold 2))
      (my/kb-sync-scan)
      (should (process-live-p my/kb-sync--rebuild))
      (should-not my/kb-sync--queue)
      (should (init-kb-test--wait (lambda () (null my/kb-sync--rebuild))))
      (should (= (length (my/kb-concepts)) 4))
      (should-not (my/kb-sync--changed-files)))))

;;; Validation and export

(ert-deftest init-kb-check-reports-problems-by-line ()
  "The validator prints compilation-style findings and fails on errors."
  (init-kb-test--with-kb
    (init-kb-test--concept root "a" "id-a" "Alpha"
                           "- see [[id:nowhere][X]]"
                           "" "* Relations"
                           "- requires :: [[id:id-b][Beta]]"
                           "- likes :: [[id:id-b][Beta]]"
                           "- no tag [[id:id-b][Beta]]"
                           "- related :: no link")
    (init-kb-test--write root "concepts/b.org"
                         ":PROPERTIES:" ":ID:       id-b" ":LEVEL:    master"
                         ":UPDATED:  2026-1-1" ":END:")
    (init-kb-test--write root "sessions/2026-11-12.org"
                         ":PROPERTIES:" ":ID:       id-a" ":END:" "#+title: 2026-11-12"
                         "* 10:00" ":PROPERTIES:" ":AI:       gemini"
                         ":CONCEPTS: [[id:id-b][Beta]] [[id:ghost][G]]" ":END:"
                         "* 11:00")
    (let* ((my/kb-relations '("requires" "related" "likes-not"))
           (result (init-kb-test--batch "my/kb-batch-check" root))
           (lines (split-string (cdr result) "\n" t)))
      (should (equal (car result) 1))
      (dolist (expected
               '("concepts/a.org:12:7: error: 悬空链接：id nowhere 不存在"
                 "concepts/a.org:16:1: error: 未知的关系名 likes"
                 "concepts/a.org:17:1: error: Relations 下的条目应写成"
                 "concepts/a.org:18:1: error: 关系 related 没有 id 链接"
                 "concepts/b.org:1:1: error: 缺少属性 CONFIRMED"
                 "concepts/b.org:1:1: error: 缺少 #+title"
                 "concepts/b.org:3:1: error: LEVEL 的值「master」不合法"
                 "concepts/b.org:4:1: error: UPDATED 的值「2026-1-1」不合法"
                 "sessions/2026-11-12.org:2:1: error: 重复的 ID id-a（另见 concepts/a.org:2）"
                 "sessions/2026-11-12.org:5:1: warning: AI 的值「gemini」"
                 "sessions/2026-11-12.org:8:30: error: 悬空链接：id ghost 不存在"
                 "sessions/2026-11-12.org:10:1: warning: 学习记录缺少 AI 属性"
                 "检查了 3 个文件：10 个错误，2 个警告"))
        (ert-info (expected)
          (should (cl-some (lambda (line) (string-prefix-p expected line)) lines))))
      ;; Customized relation names reach the subprocess.
      (should (string-match-p "可用：requires / related / likes-not" (cdr result))))))

(ert-deftest init-kb-publish-links-pages-without-touching-the-kb ()
  "The export runs asynchronously, turns id links into relative links,
writes an index, and leaves the knowledge base as it was."
  (init-kb-test--with-kb
    (init-kb-test--concept root "a" "id-a" "Alpha | A" "" "* Relations"
                           "- requires :: [[id:id-b][Beta]]")
    (init-kb-test--concept root "b" "id-b" "Beta")
    (init-kb-test--write root "sessions/2026-11-12.org"
                         ":PROPERTIES:" ":ID:       id-s" ":END:" "#+title: 2026-11-12"
                         "* 10:00 NbE" ":PROPERTIES:" ":AI:       claude"
                         ":CONCEPTS: [[id:id-a][Alpha]] [[id:gone][Gone]]" ":END:"
                         "* 11:00 Empty" ":PROPERTIES:" ":AI:       chatgpt"
                         ":CONCEPTS:" ":END:")
    (let ((before (directory-files-recursively root "" t)))
      (my/kb-publish)
      (should (process-live-p my/kb--publish))
      (should (init-kb-test--wait (lambda () (null my/kb--publish))))
      (should (equal (directory-files-recursively root "" t) before))
      (let ((page (lambda (file)
                    (init-kb-test--file-string
                     (expand-file-name file my/kb-publish-directory)))))
        (should (string-match-p "href=\"b.html#ID-id-b\"" (funcall page "concepts/a.html")))
        (should (string-match-p "掌握程度：exposed · 待确认 · 更新于 2026-01-01"
                                (funcall page "concepts/a.html")))
        (should (string-match-p "href=\"../index.html\"" (funcall page "concepts/a.html")))
        (let ((session (funcall page "sessions/2026-11-12.html")))
          (should (string-match-p "AI：claude · 涉及概念：<a href=\"../concepts/a.html#ID-id-a\">"
                                  session))
          (should (string-match-p "BROKEN LINK: gone" session))
          ;; A session without concepts shows only its AI.
          (should (string-match-p "AI：chatgpt\n" session))
          (should-not (string-match-p "AI：chatgpt · " session)))
        (let ((index (funcall page "index.html")))
          (should (string-match-p "<a href=\"concepts/a.html\">Alpha &vert; A</a>" index))
          (should (string-match-p "<a href=\"sessions/2026-11-12.html\">2026-11-12</a>"
                                  index))))
      ;; Again, incrementally.
      (my/kb-publish)
      (should (init-kb-test--wait (lambda () (null my/kb--publish))))
      (should (file-exists-p (expand-file-name "timestamps/kb.cache"
                                               my/kb-publish-cache-directory))))))

(provide 'init-kb-test)
;;; init-kb-test.el ends here
