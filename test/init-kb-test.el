;;; init-kb-test.el --- Knowledge base tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise the knowledge base on temporary directories and databases:
;; creation, capture, relations, labelled backlinks and the table.  The module is loaded with `my/kb-directory' pointing at a
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
  (setq org-roam-db-location (expand-file-name "startup.db" init-kb-test--state)))

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
            (should (string-prefix-p ":PROPERTIES:\n:ID:" text)))))
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
  "A session is a heading of today's file in sessions/, with AI and the
id links of the concepts read for it."
  (init-kb-test--with-kb
    (let ((a (init-kb-test--concept root "a" "id-a" "Alpha"))
          (answers (list "Alpha" "")))
      (init-kb-test--index a)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt &rest _)
                   (cond ((string-match-p "AI" prompt) "chatgpt")
                         ((string-match-p "概念" prompt) (pop answers))
                         (t "NbE"))))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "NbE")))
        (org-roam-dailies-capture-today)
        (org-capture-finalize))
      (let ((text (init-kb-test--file-string
                   (expand-file-name (format-time-string "sessions/%Y-%m-%d.org") root))))
        (should (string-match-p
                 (concat "^\\* [0-9][0-9]:[0-9][0-9] NbE\n:PROPERTIES:\n:AI: +chatgpt\n"
                         ":CONCEPTS: \\[\\[id:id-a\\]\\[Alpha\\]\\]\n:END:")
                 text))
        (should (string-match-p (format-time-string "^#\\+title: %Y-%m-%d$") text))))))

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
        (my/kb-table-set-level "implemented")
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

(provide 'init-kb-test)
;;; init-kb-test.el ends here
