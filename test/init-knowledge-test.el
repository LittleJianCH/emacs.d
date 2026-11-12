;;; init-knowledge-test.el --- Knowledge base tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise the knowledge base on temporary directories and databases:
;; creation, capture, relations, labelled backlinks, the table, catching up
;; with external changes, and the batch validator and exporter (real
;; subprocesses).  The module is loaded with `my/knowledge-directory' pointing at a
;; temporary directory, so the real ~/knowledge and var/org-roam.db are never
;; touched.  Skipped unless org-roam is installed; nothing is installed.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'package)

(defvar my/knowledge-directory)
(defvar my/knowledge-publish-directory)
(defvar my/knowledge-publish-cache-directory)
(defvar my/knowledge-sync--queue)
(defvar my/knowledge-sync--queued)
(defvar my/knowledge-sync--indexed)
(defvar my/knowledge-sync--timer)
(defvar my/knowledge-sync--rebuild)
(defvar my/knowledge--publish)
(defvar my/knowledge-sync-rebuild-threshold)
(defvar my/knowledge-sync-updated-hook)
(defvar my/knowledge-level-change-confirms)
(defvar org-roam-directory)
(defvar org-roam-db-location)
(defvar org-id-track-globally)
(defvar org-id-locations-file)

(defconst init-knowledge-test--state (make-temp-file "knowledge-ert-" t)
  "Temporary directory for the module's startup knowledge base.")

(defconst init-knowledge-test--available (package-installed-p 'org-roam)
  "Non-nil if org-roam is installed, so the module can load.")

(when init-knowledge-test--available
  (setq my/knowledge-directory (expand-file-name "startup-knowledge/" init-knowledge-test--state)
        org-id-track-globally nil
        org-id-locations-file (expand-file-name "org-id-locations"
                                                init-knowledge-test--state))
  (require 'init-knowledge)
  ;; use-package set the real database; nothing has opened it yet.
  (setq org-roam-db-location (expand-file-name "startup.db" init-knowledge-test--state))
  (my/knowledge-sync-stop))

(add-hook 'kill-emacs-hook
          (lambda () (delete-directory init-knowledge-test--state t)))

(defun init-knowledge-test--write (root file &rest lines)
  "Write LINES to FILE under ROOT and return its absolute name."
  (let ((file (expand-file-name file root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (string-join lines "\n") "\n"))
    file))

(defun init-knowledge-test--concept (root slug id title &rest body)
  "Write the concept SLUG with ID and TITLE under ROOT, followed by BODY lines.
LEVEL is exposed and CONFIRMED nil."
  (apply #'init-knowledge-test--write root (format "concepts/%s.org" slug)
         ":PROPERTIES:" (format ":ID:       %s" id) ":LEVEL:    exposed"
         ":CONFIRMED: nil" ":UPDATED:  [2026-01-01]" ":END:"
         (format "#+title: %s" title) "#+filetags: :tt:" "" "* Notes" "- note"
         body))

(defun init-knowledge-test--file-string (file)
  "Return the contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun init-knowledge-test--delete (file)
  "Delete FILE the way another program would.
`delete-file' itself tells org-roam, through autosync's advice."
  (should (zerop (call-process "rm" nil nil nil "-f" file))))

(defun init-knowledge-test--drain ()
  "Index every queued file now, without timers."
  (while my/knowledge-sync--queue
    (when (timerp my/knowledge-sync--timer)
      (cancel-timer my/knowledge-sync--timer)
      (setq my/knowledge-sync--timer nil))
    (my/knowledge-sync--drain))
  (when (timerp my/knowledge-sync--timer)
    (cancel-timer my/knowledge-sync--timer)
    (setq my/knowledge-sync--timer nil)))

(defun init-knowledge-test--index (&rest files)
  "Index FILES in the database at once."
  (dolist (file files)
    (org-roam-db-update-file file)))

(defun init-knowledge-test--wait (predicate &optional seconds)
  "Wait up to SECONDS (default 120) for PREDICATE to return non-nil."
  (let ((deadline (time-add nil (or seconds 120))))
    (while (and (not (funcall predicate)) (time-less-p nil deadline))
      (accept-process-output nil 0.1))
    (funcall predicate)))

(defmacro init-knowledge-test--with-knowledge (&rest body)
  "Run BODY with an empty knowledge base and database, bound to `root'."
  (declare (indent 0) (debug t))
  `(progn
     (unless init-knowledge-test--available (ert-skip "org-roam is not installed"))
     (let* ((root (file-name-as-directory
                   (file-truename (make-temp-file "knowledge-test-" t))))
            (state (make-temp-file "knowledge-test-state-" t))
            (my/knowledge-directory root)
            (org-roam-directory root)
            (org-roam-db-location (expand-file-name "org-roam.db" state))
            (my/knowledge-publish-directory (expand-file-name "site/" state))
            (my/knowledge-publish-cache-directory (expand-file-name "cache/" state))
            (my/knowledge-sync--queue nil)
            (my/knowledge-sync--queued (make-hash-table :test #'equal))
            (my/knowledge-sync--indexed nil)
            (my/knowledge-sync-updated-hook nil))
       (ignore root)
       (make-directory (expand-file-name "concepts" root))
       (make-directory (expand-file-name "sessions" root))
       (unwind-protect (progn ,@body)
         (when (timerp (bound-and-true-p my/knowledge-sync--timer))
           (cancel-timer my/knowledge-sync--timer)
           (setq my/knowledge-sync--timer nil))
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (string-prefix-p root (file-truename (buffer-file-name buffer))))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (when-let* ((table (get-buffer "*知识库*"))) (kill-buffer table))
         (org-roam-db--close-all)
         (delete-directory root t)
         (delete-directory state t)))))

(defun init-knowledge-test--batch (function &rest args)
  "Run FUNCTION of knowledge-batch.el in a subprocess with ARGS.
Return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((status (apply #'call-process (car (my/knowledge--batch-command function))
                         nil t nil
                         (append (cdr (my/knowledge--batch-command function)) args))))
      (cons status (buffer-string)))))

;;; Creation

(ert-deftest init-knowledge-bootstrap-creates-two-related-concepts ()
  "A missing knowledge base gets two valid concepts relating to each other;
an existing one is left alone."
  (init-knowledge-test--with-knowledge
    (let ((my/knowledge-directory (expand-file-name "new/" root)))
      (my/knowledge-bootstrap)
      (let ((files (directory-files (expand-file-name "concepts" my/knowledge-directory)
                                    t "\\.org\\'")))
        (should (= (length files) 2))
        (should (file-directory-p (expand-file-name "sessions" my/knowledge-directory)))
        (let ((texts (mapcar #'init-knowledge-test--file-string files)))
          (should (cl-some (lambda (text) (string-match-p "^- requires :: \\[\\[id:" text))
                           texts))
          (should (cl-some (lambda (text)
                             (string-match-p "^- prerequisite_of :: \\[\\[id:" text))
                           texts))
          (dolist (text texts)
            (should (string-prefix-p ":PROPERTIES:\n:ID:" text))))
        ;; The examples follow the format the validator checks.
        (let ((result (init-knowledge-test--batch "my/knowledge-batch-check" my/knowledge-directory)))
          (should (equal (car result) 0))
          (should (string-match-p "0 个错误，0 个警告" (cdr result)))))
      ;; Let git init finish before the directory goes.
      (init-knowledge-test--wait (lambda () (file-directory-p
                                      (expand-file-name ".git" my/knowledge-directory)))
                          10)
      (let ((marker (init-knowledge-test--write my/knowledge-directory "concepts/mine.org" "x")))
        (my/knowledge-bootstrap)
        (should (equal (init-knowledge-test--file-string marker) "x\n"))
        (should (= (length (directory-files (expand-file-name "concepts" my/knowledge-directory)
                                            nil "\\.org\\'"))
                   3))))))

(ert-deftest init-knowledge-capture-fills-the-property-drawer ()
  "A captured concept has one top drawer, ID first, with the defaults."
  (init-knowledge-test--with-knowledge
    (org-roam-capture- :keys "c"
                       :node (org-roam-node-create :title "Cubical Type Theory")
                       :props '(:immediate-finish t))
    (let* ((file (expand-file-name "concepts/cubical_type_theory.org" root))
           (text (init-knowledge-test--file-string file)))
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

(ert-deftest init-knowledge-session-capture-records-ai-and-concepts ()
  "A session is a heading of today's file in sessions/, asking only for
the topic and AI; concepts are added one per call, also while capturing,
without duplicates.  No prompt asks to end a list."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha"))
          (b (init-knowledge-test--concept root "b" "id-b" "Beta"))
          prompts)
      (init-knowledge-test--index a b)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt &rest _)
                   (push prompt prompts)
                   (if (string-match-p "AI" prompt) "chatgpt" "NbE"))))
        (org-roam-dailies-capture-today))
      (should (= (length prompts) 2))
      (should-not (cl-some (lambda (prompt) (string-match-p "概念" prompt)) prompts))
      ;; In the capture buffer, the body of the new heading.
      (my/knowledge-session-add-concept (org-roam-node-from-id "id-a"))
      (my/knowledge-session-add-concept (org-roam-node-from-id "id-b"))
      (my/knowledge-session-add-concept (org-roam-node-from-id "id-a"))
      (org-capture-finalize)
      (let* ((file (expand-file-name (format-time-string "sessions/%Y-%m-%d.org") root))
             (text (init-knowledge-test--file-string file)))
        (should (string-match-p
                 (concat "^\\* [0-9][0-9]:[0-9][0-9] NbE\n:PROPERTIES:\n:AI: +chatgpt\n"
                         ":CONCEPTS: \\[\\[id:id-a\\]\\[Alpha\\]\\] "
                         "\\[\\[id:id-b\\]\\[Beta\\]\\]\n:END:")
                 text))
        (should (string-match-p (format-time-string "^#\\+title: %Y-%m-%d$") text))))))

(ert-deftest init-knowledge-session-add-concept-needs-a-session ()
  "Outside a session heading the command explains where to use it."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha"))
          (s (init-knowledge-test--write root "sessions/2026-11-12.org"
                                  ":PROPERTIES:" ":ID:       id-s" ":END:"
                                  "#+title: 2026-11-12" "" "* 10:00 NbE" "** detail" "text")))
      (init-knowledge-test--index a s)
      (with-current-buffer (find-file-noselect a)
        (should-error (my/knowledge-session-add-concept (org-roam-node-from-id "id-a"))
                      :type 'user-error))
      (with-current-buffer (find-file-noselect s)
        (goto-char (point-min))
        (should-error (my/knowledge-session-add-concept (org-roam-node-from-id "id-a"))
                      :type 'user-error)
        ;; From a subheading, the session is its top-level heading.
        (goto-char (point-max))
        (my/knowledge-session-add-concept (org-roam-node-from-id "id-a"))
        (goto-char (point-min))
        (should (re-search-forward
                 "^\\* 10:00 NbE\n:PROPERTIES:\n:CONCEPTS: \\[\\[id:id-a\\]\\[Alpha\\]\\]\n:END:"
                 nil t))))))

;;; The shared format layer

(ert-deftest init-knowledge-slug-matches-org-roam ()
  "Programs outside Emacs name concept files as org-roam does."
  (unless init-knowledge-test--available (ert-skip "org-roam is not installed"))
  (dolist (title '("Normalization by Evaluation" "Martin-Löf Type Theory"
                   "依值类型论" "  Cubical  NbE: (v2)!  " "C++ / Rust" "Ünïcödé café"
                   "λ-calculus" "a__b"))
    (ert-info (title)
      (should (equal (my/knowledge-slug title) (org-roam-node-slugify title))))))

(ert-deftest init-knowledge-readers-describe-concepts-and-sessions ()
  "The readers shared with the MCP server return what the files say."
  (with-temp-buffer
    (insert ":PROPERTIES:\n:ID:       id-n\n:ROAM_ALIASES: NbE \"Normal Forms\"\n"
            ":LEVEL:    implemented\n:CONFIRMED: t\n:UPDATED:  [2026-11-12]\n:END:\n"
            "#+title: Normalization by Evaluation\n#+filetags: :type_theory:pl:\n\n"
            "* Notes\n- x\n\n* Relations\n- requires :: [[id:id-m][MLTT]]\n"
            "- related :: [[id:id-a][A]] and [[id:id-b][B]]\n- untagged [[id:id-c][C]]\n")
    (org-mode)
    (should (equal (my/knowledge-concept-summary)
                   '(:id "id-n" :title "Normalization by Evaluation"
                     :aliases ("NbE" "Normal Forms") :level "implemented"
                     :confirmed "t" :updated "[2026-11-12]"
                     :tags ("type_theory" "pl")
                     :relations (("requires" "id-m" "MLTT") ("related" "id-a" "A")
                                 ("related" "id-b" "B") (nil "id-c" "C"))))))
  (with-temp-buffer
    (insert ":PROPERTIES:\n:ID:       id-s\n:END:\n#+title: 2026-11-12\n\n"
            "* 10:00 NbE\n:PROPERTIES:\n:AI:       claude\n"
            ":CONCEPTS: [[id:id-n][NbE]] [[id:id-m][MLTT]]\n:END:\n** detail\n"
            "* 11:00 Other\n:PROPERTIES:\n:AI:       chatgpt\n:CONCEPTS:\n:END:\n")
    (org-mode)
    (should (equal (mapcar (lambda (session) (plist-put session :begin nil))
                           (my/knowledge-sessions))
                   '((:heading "10:00 NbE" :ai "claude" :concepts ("id-n" "id-m")
                      :begin nil)
                     (:heading "11:00 Other" :ai "chatgpt" :concepts nil
                      :begin nil))))))

(ert-deftest init-knowledge-atomic-writes-keep-file-modes ()
  "A rewritten file keeps its modes, a new one gets the default ones,
and no temporary file is left behind."
  (let ((directory (make-temp-file "knowledge-modes-" t)))
    (unwind-protect
        (let ((old (expand-file-name "old.org" directory))
              (new (expand-file-name "new.org" directory)))
          (with-temp-file old (insert "x\n"))
          (set-file-modes old #o640)
          (with-temp-buffer
            (insert "y\n")
            (my/knowledge-write-atomically old)
            (my/knowledge-write-atomically new))
          (should (= (file-modes old) #o640))
          (should (= (file-modes new) (logand #o666 (default-file-modes))))
          (should (equal (with-temp-buffer (insert-file-contents old) (buffer-string))
                         "y\n"))
          (should (equal (directory-files directory nil "\\`[^.]\\|\\`\\.knowledge-")
                         '("new.org" "old.org"))))
      (delete-directory directory t))))

;;; Relations

(ert-deftest init-knowledge-relation-add-appends-to-the-relations-section ()
  "The item lands last in Relations, before the next heading; a missing
section is created, and a repeated relation is refused."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha"
                                    "" "* Relations" "- related :: [[id:id-c][Gamma]]"
                                    "" "* Later" "text"))
          (b (init-knowledge-test--concept root "b" "id-b" "Beta"))
          (c (init-knowledge-test--concept root "c" "id-c" "Gamma")))
      (init-knowledge-test--index a b c)
      (my/knowledge-relation-add a "requires" (org-roam-node-from-id "id-b"))
      (should (string-match-p
               (concat "\\* Relations\n- related :: \\[\\[id:id-c\\]\\[Gamma\\]\\]\n"
                       "- requires :: \\[\\[id:id-b\\]\\[Beta\\]\\]\n\n\\* Later")
               (init-knowledge-test--file-string a)))
      ;; Saved and indexed: the database knows the new link.
      (should (member "id-a" (mapcar #'car (org-roam-db-query
                                            [:select source :from links
                                             :where (= dest $s1)]
                                            "id-b"))))
      (should-error (my/knowledge-relation-add a "requires" (org-roam-node-from-id "id-b"))
                    :type 'user-error)
      (my/knowledge-relation-add b "prerequisite_of" (org-roam-node-from-id "id-a"))
      (should (string-match-p
               "\n\\* Relations\n- prerequisite_of :: \\[\\[id:id-a\\]\\[Alpha\\]\\]\n\\'"
               (init-knowledge-test--file-string b))))))

(ert-deftest init-knowledge-relation-add-in-the-concept-buffer-leaves-it-unsaved ()
  "In the concept's own buffer the item is inserted at point, like a link."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha" "" "* Relations"))
          (b (init-knowledge-test--concept root "b" "id-b" "Beta")))
      (init-knowledge-test--index a b)
      (with-current-buffer (find-file-noselect a)
        (goto-char (point-min))
        (my/knowledge-relation-add a "generalizes" (org-roam-node-from-id "id-b"))
        (should (buffer-modified-p))
        (should (looking-at-p "- generalizes :: \\[\\[id:id-b\\]\\[Beta\\]\\]"))
        (should-not (string-match-p "generalizes" (init-knowledge-test--file-string a)))))))

;;; Backlinks

(ert-deftest init-knowledge-backlinks-show-the-relation-name ()
  "Each backlink is labelled: relation names first, then sessions and links."
  (init-knowledge-test--with-knowledge
    (let ((target (init-knowledge-test--concept root "t" "id-t" "Target"))
          (user (init-knowledge-test--concept root "u" "id-u" "User"
                                       "" "* Relations" "- requires :: [[id:id-t][Target]]"))
          (general (init-knowledge-test--concept root "g" "id-g" "General"
                                          "" "* Relations"
                                          "- generalizes :: [[id:id-t][Target]]"))
          (mention (init-knowledge-test--concept root "m" "id-m" "Mention"
                                          "- see [[id:id-t][Target]]"))
          (session (init-knowledge-test--write root "sessions/2026-11-12.org"
                                        ":PROPERTIES:" ":ID:       id-s" ":END:"
                                        "#+title: 2026-11-12" ""
                                        "* 10:00 NbE" ":PROPERTIES:" ":AI:       claude"
                                        ":CONCEPTS: [[id:id-t][Target]]" ":END:")))
      (init-knowledge-test--index target user general mention session)
      (let ((text (with-temp-buffer
                    (org-roam-mode)
                    (let ((inhibit-read-only t))
                      (magit-insert-section (org-roam)
                        (my/knowledge-backlinks-section (org-roam-node-from-id "id-t"))))
                    (buffer-substring-no-properties (point-min) (point-max)))))
        (should (string-match-p "^\\[requires\\] User " text))
        (should (string-match-p "^\\[generalizes\\] General " text))
        (should (string-match-p "^\\[学习记录\\] 2026-11-12 " text))
        (should (string-match-p "^\\[链接\\] Mention " text))
        ;; Relations in the order of `my/knowledge-relations', then the rest.
        (should (< (string-match "\\[requires\\]" text)
                   (string-match "\\[generalizes\\]" text)
                   (string-match "\\[学习记录\\]" text)
                   (string-match "\\[链接\\]" text)))))))

;;; Table

(defun init-knowledge-test--row (title)
  "Move to the table row of TITLE."
  (goto-char (point-min))
  (should (search-forward title nil t))
  (beginning-of-line))

(ert-deftest init-knowledge-table-reads-the-database ()
  "Rows come from the database (a rewritten file shows until indexed),
LEVEL sorts by rank, and the filter keeps unconfirmed concepts."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha"))
          (b (init-knowledge-test--write root "concepts/b.org"
                                  ":PROPERTIES:" ":ID:       id-b" ":LEVEL:    implemented"
                                  ":CONFIRMED: t" ":UPDATED:  [2026-02-02]" ":END:"
                                  "#+title: Beta"))
          (s (init-knowledge-test--write root "sessions/2026-11-12.org"
                                  ":PROPERTIES:" ":ID:       id-s" ":END:"
                                  "#+title: 2026-11-12")))
      (init-knowledge-test--index a b s)
      ;; Rewritten, not yet indexed: the table shows the database.
      (with-temp-file a (insert "#+title: Changed\n"))
      (my/knowledge-table)
      (with-current-buffer "*知识库*"
        (should (derived-mode-p 'my/knowledge-table-mode))
        (should (equal (sort (mapcar #'car tabulated-list-entries))
                       '("id-a" "id-b")))
        (init-knowledge-test--row "Beta")
        (should (string-match-p "implemented +已确认 +2026-02-02 +tt\\|implemented +已确认 +2026-02-02"
                                (buffer-substring (point) (line-end-position))))
        (should (my/knowledge-table--level< (assoc "id-a" tabulated-list-entries)
                                     (assoc "id-b" tabulated-list-entries)))
        (my/knowledge-table-toggle-unconfirmed)
        (should (equal (mapcar #'car tabulated-list-entries) '("id-a")))
        (my/knowledge-table-toggle-unconfirmed)
        (should (= (length tabulated-list-entries) 2))))))

(ert-deftest init-knowledge-table-writes-level-and-confirmation-back ()
  "Raising, lowering and confirming write the top drawer and UPDATED,
update the database and the row in place."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha"))
          (today (format-time-string "[%Y-%m-%d]")))
      (init-knowledge-test--index a)
      (my/knowledge-table)
      (with-current-buffer "*知识库*"
        (init-knowledge-test--row "Alpha")
        (let ((my/knowledge-level-change-confirms nil))
          (my/knowledge-table-raise))
        (let ((text (init-knowledge-test--file-string a)))
          (should (string-match-p "^:LEVEL: +walked-through$" text))
          (should (string-match-p "^:CONFIRMED: nil$" text))
          (should (string-match-p (concat "^:UPDATED: +" (regexp-quote today) "$") text))
          ;; Still one drawer, before the title.
          (should (string-prefix-p ":PROPERTIES:\n:ID:" text)))
        (should (string-match-p "walked-through +待确认"
                                (buffer-substring (point) (line-end-position))))
        (should (equal (plist-get (car (my/knowledge-concepts)) :level) "walked-through"))
        (my/knowledge-table-lower)
        (should (string-match-p "^:LEVEL: +exposed$" (init-knowledge-test--file-string a)))
        (should (string-match-p "^:CONFIRMED: t$" (init-knowledge-test--file-string a)))
        (should-error (my/knowledge-table-lower) :type 'user-error)
        (let ((last-command-event ?4))
          (call-interactively #'my/knowledge-table-set-level))
        (should (string-match-p "^:LEVEL: +can-apply$" (init-knowledge-test--file-string a)))
        ;; From M-x, the level is read.
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "implemented")))
          (let ((last-command-event ?\r))
            (call-interactively #'my/knowledge-table-set-level)))
        (should (string-match-p "^:LEVEL: +implemented$" (init-knowledge-test--file-string a)))
        (init-knowledge-test--row "Alpha")
        (my/knowledge-table-confirm)
        (should (string-match-p "^:CONFIRMED: nil$" (init-knowledge-test--file-string a)))
        (should (equal (plist-get (car (my/knowledge-concepts)) :confirmed) "nil"))
        (init-knowledge-test--row "Alpha")
        (my/knowledge-table-confirm)
        (should (string-match-p "^:CONFIRMED: t$" (init-knowledge-test--file-string a)))))))

(ert-deftest init-knowledge-table-shows-backlinks-of-the-row ()
  "In the table, b shows the backlinks of the concept at point and they
follow the row; nothing asks Org for a node in the table buffer."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha"))
          (b (init-knowledge-test--concept root "b" "id-b" "Beta"
                                           "" "* Relations" "- requires :: [[id:id-a][Alpha]]"))
          (c (init-knowledge-test--concept root "c" "id-c" "Gamma"
                                           "" "* Relations" "- related :: [[id:id-b][Beta]]"))
          (warnings (get-buffer-create "*Warnings*")))
      (init-knowledge-test--index a b c)
      (with-current-buffer warnings (let ((inhibit-read-only t)) (erase-buffer)))
      (save-window-excursion
        (delete-other-windows)
        (my/knowledge-table)
        (unwind-protect
            (with-current-buffer "*知识库*"
              (init-knowledge-test--row "Alpha")
              (my/knowledge-backlinks)
              (should (get-buffer-window org-roam-buffer))
              (should (equal (org-roam-node-id org-roam-buffer-current-node) "id-a"))
              (should (string-match-p "\\[requires\\] Beta"
                                      (with-current-buffer org-roam-buffer
                                        (buffer-string))))
              ;; Moving to another row and finishing a command follows it.
              (init-knowledge-test--row "Beta")
              (my/knowledge-table--follow)
              (should (equal (org-roam-node-id org-roam-buffer-current-node) "id-b"))
              (should (string-match-p "\\[related\\] Gamma"
                                      (with-current-buffer org-roam-buffer
                                        (buffer-string))))
              (my/knowledge-backlinks)
              (should-not (get-buffer-window org-roam-buffer)))
          (when (get-buffer org-roam-buffer) (kill-buffer org-roam-buffer))))
      (should-not (string-match-p "org-element"
                                  (with-current-buffer warnings (buffer-string)))))))

(ert-deftest init-knowledge-edit-refuses-a-modified-buffer ()
  "Unsaved changes of a visiting buffer are never saved behind my back."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha")))
      (init-knowledge-test--index a)
      (with-current-buffer (find-file-noselect a)
        (goto-char (point-max))
        (insert "draft\n")
        (should-error (my/knowledge-set-properties a '(("LEVEL" . "can-apply")))
                      :type 'user-error)
        (should-not (string-match-p "draft\\|can-apply" (init-knowledge-test--file-string a)))))))

;;; Following external changes

(ert-deftest init-knowledge-scan-follows-external-changes ()
  "Changed, new and deleted files are found by modification time and
indexed; afterwards a scan finds nothing, also for a file only touched."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha"))
          (b (init-knowledge-test--concept root "b" "id-b" "Beta"))
          (later (time-add nil 10))
          updated)
      (init-knowledge-test--index a b)
      (should-not (my/knowledge-sync--changed-files))
      (add-hook 'my/knowledge-sync-updated-hook (lambda (files) (setq updated files)))
      ;; An agent rewrites a, creates c, deletes b.
      (with-temp-file a
        (insert (string-replace "exposed" "can-apply" (init-knowledge-test--file-string a))))
      (set-file-times a later)
      (let ((c (init-knowledge-test--concept root "c" "id-c" "Gamma")))
        (init-knowledge-test--delete b)
        (should (equal (sort (my/knowledge-sync--changed-files)) (sort (list a b c))))
        (my/knowledge-sync-scan)
        (init-knowledge-test--drain)
        (should (equal (sort updated) (sort (list a b c))))
        (let ((concepts (my/knowledge-concepts)))
          (should (equal (sort (mapcar (lambda (concept) (plist-get concept :id)) concepts))
                         '("id-a" "id-c")))
          (should (equal (plist-get (seq-find (lambda (concept)
                                                (equal (plist-get concept :id) "id-a"))
                                              concepts)
                                    :level)
                         "can-apply")))
        (should-not (my/knowledge-sync--changed-files))
        ;; Touched, not changed: indexed once, then quiet, and no update.
        (setq updated 'none)
        (set-file-times c (time-add later 10))
        (should (equal (my/knowledge-sync--changed-files) (list c)))
        (my/knowledge-sync-scan)
        (init-knowledge-test--drain)
        (should (eq updated 'none))
        (should-not (my/knowledge-sync--changed-files))))))

(ert-deftest init-knowledge-scan-skips-hidden-and-temporary-files ()
  "Only Org files of the knowledge base are queued, never git's or locks."
  (init-knowledge-test--with-knowledge
    (let ((a (init-knowledge-test--concept root "a" "id-a" "Alpha")))
      (init-knowledge-test--write root ".git/x.org" "x")
      (init-knowledge-test--write root "concepts/.#a.org" "x")
      (init-knowledge-test--write root "concepts/#a.org#" "x")
      (init-knowledge-test--write root "concepts/notes.txt" "x")
      (should (equal (my/knowledge-sync--changed-files) (list a))))))

(ert-deftest init-knowledge-scan-rebuilds-in-a-subprocess-when-many-changed ()
  "Past the threshold, a batch Emacs builds the database, which then
replaces the current one."
  (init-knowledge-test--with-knowledge
    (dotimes (i 4)
      (init-knowledge-test--concept root (format "c%d" i) (format "id-%d" i)
                             (format "Concept %d" i)))
    (let ((my/knowledge-sync-rebuild-threshold 2))
      (my/knowledge-sync-scan)
      (should (process-live-p my/knowledge-sync--rebuild))
      (should-not my/knowledge-sync--queue)
      (should (init-knowledge-test--wait (lambda () (null my/knowledge-sync--rebuild))))
      (should (= (length (my/knowledge-concepts)) 4))
      (should-not (my/knowledge-sync--changed-files)))))

;;; Validation and export

(ert-deftest init-knowledge-check-reports-problems-by-line ()
  "The validator prints compilation-style findings and fails on errors."
  (init-knowledge-test--with-knowledge
    (init-knowledge-test--concept root "a" "id-a" "Alpha"
                           "- see [[id:nowhere][X]]"
                           "" "* Relations"
                           "- requires :: [[id:id-b][Beta]]"
                           "- likes :: [[id:id-b][Beta]]"
                           "- no tag [[id:id-b][Beta]]"
                           "- related :: no link")
    (init-knowledge-test--write root "concepts/b.org"
                         ":PROPERTIES:" ":ID:       id-b" ":LEVEL:    master"
                         ":UPDATED:  2026-1-1" ":END:")
    (init-knowledge-test--write root "sessions/2026-11-12.org"
                         ":PROPERTIES:" ":ID:       id-a" ":END:" "#+title: 2026-11-12"
                         "* 10:00" ":PROPERTIES:" ":AI:       gemini"
                         ":CONCEPTS: [[id:id-b][Beta]] [[id:ghost][G]]" ":END:"
                         "* 11:00")
    (let* ((my/knowledge-relations '("requires" "related" "likes-not"))
           (result (init-knowledge-test--batch "my/knowledge-batch-check" root))
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

(ert-deftest init-knowledge-publish-links-pages-without-touching-the-knowledge-base ()
  "The export runs asynchronously, turns id links into relative links,
writes an index, and leaves the knowledge base as it was."
  (init-knowledge-test--with-knowledge
    (init-knowledge-test--concept root "a" "id-a" "Alpha | A" "" "* Relations"
                           "- requires :: [[id:id-b][Beta]]")
    (init-knowledge-test--concept root "b" "id-b" "Beta")
    (init-knowledge-test--write root "sessions/2026-11-12.org"
                         ":PROPERTIES:" ":ID:       id-s" ":END:" "#+title: 2026-11-12"
                         "* 10:00 NbE" ":PROPERTIES:" ":AI:       claude"
                         ":CONCEPTS: [[id:id-a][Alpha]] [[id:gone][Gone]]" ":END:"
                         "* 11:00 Empty" ":PROPERTIES:" ":AI:       chatgpt"
                         ":CONCEPTS:" ":END:")
    (let ((before (directory-files-recursively root "" t)))
      (my/knowledge-publish)
      (should (process-live-p my/knowledge--publish))
      (should (init-knowledge-test--wait (lambda () (null my/knowledge--publish))))
      (should (equal (directory-files-recursively root "" t) before))
      (let ((page (lambda (file)
                    (init-knowledge-test--file-string
                     (expand-file-name file my/knowledge-publish-directory)))))
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
      (my/knowledge-publish)
      (should (init-knowledge-test--wait (lambda () (null my/knowledge--publish))))
      (should (file-exists-p (expand-file-name "timestamps/knowledge.cache"
                                               my/knowledge-publish-cache-directory))))))

(provide 'init-knowledge-test)
;;; init-knowledge-test.el ends here
