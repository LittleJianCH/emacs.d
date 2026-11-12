;;; init-kb.el --- Personal knowledge graph on org-roam -*- lexical-binding: t; -*-

;;; Commentary:

;; A record of what I have learned and how well, kept in a git repository of
;; its own (`my/kb-directory', ~/kb), which is the `org-roam-directory'.
;; AI assistants will read and write it through MCP; Emacs is where I look
;; at it and edit it.  The file format is described in kb-batch.el.
;;
;;   C-c n n   table of all concepts (SPC n n with evil): sort, raise or
;;             lower LEVEL, confirm, open
;;   C-c n f   find or create a concept      C-c n i   insert a link
;;   C-c n r   add a relation to a concept   C-c n b   backlinks buffer
;;   C-c n d   record a learning session     C-c n D   today's sessions
;;   C-c n c   add a concept to the session at point, one per call
;;   C-c n t   add a tag   C-c n a   add an alias
;;   C-c n v   validate the knowledge base (compilation buffer)
;;   C-c n p   export to HTML for the phone (C-u: everything again)
;;   C-c n s   catch up with external changes now   C-c n S   rebuild
;;
;; Keeping the database current without blocking.  Saves inside Emacs are
;; handled by `org-roam-db-autosync-mode', enabled here without the full
;; `org-roam-db-sync' it would run at once.  Agents change files outside
;; Emacs, so three things feed a queue of files to index:
;;
;; - file-notify watches on the knowledge base's directories.  On macOS they
;;   are kqueue watches, which report files created, deleted or renamed in
;;   a directory (so editors' atomic saves) but not a file rewritten in
;;   place; one watch per file would take thousands of descriptors.
;; - A scan comparing the modification time of every file, from one
;;   `directory-files-and-attributes' per directory, with the files table
;;   of the database.  It reads no file contents and takes milliseconds for
;;   thousands of files, so it runs when the module loads, every
;;   `my/kb-sync-scan-interval' seconds once Emacs is idle, when a frame
;;   gains focus, and on `g' in the table.  It catches in-place writes and
;;   whatever changed while Emacs was not running.
;; - `my/kb-sync-enqueue', for callers that know what they changed.
;;
;; The queue is drained by timers while Emacs is idle, a file at a time,
;; giving way as soon as input arrives; `org-roam-db-update-file' skips
;; files whose contents hash has not changed.  When a scan finds more than
;; `my/kb-sync-rebuild-threshold' changed files (the first run, a large
;; git checkout), a batch Emacs builds a new database in a temporary file,
;; which then replaces the current one, and a scan picks up what changed
;; meanwhile.  Validation and HTML export likewise run in subprocesses.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'kb-batch)

(defcustom my/kb-directory (expand-file-name "~/kb/")
  "The knowledge base: a git repository of its own, the `org-roam-directory'.
It is created with two example concepts when the module loads, if it
does not exist yet.  Takes effect after a restart."
  :type 'directory
  :group 'my/kb)

(defcustom my/kb-publish-directory (my/var "kb-site/")
  "Directory `my/kb-publish' writes the HTML version of the knowledge base to."
  :type 'directory
  :group 'my/kb)

(defcustom my/kb-level-change-confirms t
  "Non-nil means changing LEVEL in the table also sets CONFIRMED to t.
The change is mine, not an assistant's, so the new level is confirmed."
  :type 'boolean
  :group 'my/kb)

(defcustom my/kb-sync-scan-interval 120
  "Seconds between scans for files changed outside Emacs.
Each scan waits for Emacs to be idle."
  :type 'natnum
  :group 'my/kb)

(defcustom my/kb-sync-rebuild-threshold 200
  "Changed files a scan may queue; beyond this the database is rebuilt.
The rebuild runs in a subprocess, see `my/kb-sync-rebuild'."
  :type 'natnum
  :group 'my/kb)

(defface my/kb-relation '((t :inherit org-verbatim :weight bold))
  "Face of relation names in the backlinks buffer."
  :group 'my/kb)

(defun my/kb-root ()
  "Return the true name of `my/kb-directory', ending in a slash."
  (file-name-as-directory (file-truename my/kb-directory)))

(defun my/kb-concepts-directory ()
  "Return the directory of the concept files."
  (expand-file-name my/kb-concepts-subdirectory (my/kb-root)))

(defun my/kb-concept-file-p (file)
  "Return non-nil if FILE is a concept file."
  (and file (string-prefix-p (my/kb-concepts-directory) (expand-file-name file))))

;;; Creating the knowledge base

(defconst my/kb--examples
  '(("Martin-Löf Type Theory" "MLTT" "can-explain" "t"
     ("依值类型论：Π、Σ、恒等类型和宇宙"
      "判断相等与命题相等的区别")
     ("prerequisite_of" . "Normalization by Evaluation"))
    ("Normalization by Evaluation" "NbE" "walked-through" "nil"
     ("eval 进语义域，quote 读回范式")
     ("requires" . "Martin-Löf Type Theory")))
  "Example concepts: title, alias, LEVEL, CONFIRMED, notes and a relation.")

(defun my/kb--example-file (root title)
  "Return the concept file for the example TITLE under ROOT."
  (expand-file-name (concat my/kb-concepts-subdirectory
                            (org-roam-node-slug (org-roam-node-create :title title))
                            ".org")
                    root))

(defun my/kb-bootstrap ()
  "Create `my/kb-directory' with two related example concepts.
Do nothing if the directory exists: existing data is never touched.
The new directory becomes a git repository; `git init' runs
asynchronously."
  (let ((root (expand-file-name my/kb-directory)))
    (unless (file-exists-p root)
      (make-directory (expand-file-name my/kb-concepts-subdirectory root) t)
      (make-directory (expand-file-name my/kb-sessions-subdirectory root) t)
      (let ((ids (mapcar (lambda (example) (cons (car example) (org-id-uuid)))
                         my/kb--examples)))
        (pcase-dolist (`(,title ,alias ,level ,confirmed ,notes
                                (,relation . ,target))
                       my/kb--examples)
          (with-temp-file (my/kb--example-file root title)
            (insert ":PROPERTIES:\n"
                    (format ":ID:       %s\n" (cdr (assoc title ids)))
                    (format ":ROAM_ALIASES: %s\n" alias)
                    (format ":LEVEL:    %s\n" level)
                    (format ":CONFIRMED: %s\n" confirmed)
                    (format ":UPDATED:  %s\n" (my/kb-date-string))
                    ":END:\n"
                    (format "#+title: %s\n" title)
                    "#+filetags: :type_theory:\n\n* Notes\n"
                    (mapconcat (lambda (note) (concat "- " note "\n")) notes)
                    "\n* " my/kb-relations-heading "\n"
                    (format "- %s :: [[id:%s][%s]]\n"
                            relation (cdr (assoc target ids)) target)))))
      (when (executable-find "git")
        (let ((default-directory root))
          (make-process :name "kb-git-init" :command '("git" "init" "--quiet")
                        :buffer nil :noquery t)))
      (message "已创建知识库 %s，含两个示例概念" root))))

;;; org-roam

(defun my/kb--enable-autosync ()
  "Turn on `org-roam-db-autosync-mode' without its full synchronization.
Enabling the mode runs `org-roam-db-sync', which reads every file; the
scans of `my/kb-sync-start' catch up asynchronously instead."
  (cl-letf (((symbol-function 'org-roam-db-sync) #'ignore))
    (org-roam-db-autosync-mode 1)))

(use-package org-roam
  :ensure t
  :demand t
  :custom
  (org-roam-directory (my/kb-root))
  (org-roam-db-location (my/var "org-roam.db"))
  (org-roam-dailies-directory my/kb-sessions-subdirectory)
  (org-roam-capture-templates
   `(("c" "概念" plain "* Notes\n%?\n\n* Relations\n"
      :target (file+head
               ,(concat my/kb-concepts-subdirectory "${slug}.org")
               ,(concat ":PROPERTIES:\n"
                        ":ID:       ${id}\n"
                        ":LEVEL:    exposed\n"
                        ":CONFIRMED: nil\n"
                        ":UPDATED:  %<[%Y-%m-%d]>\n"
                        ":END:\n"
                        "#+title: ${title}\n"))
      :unnarrowed t)))
  (org-roam-dailies-capture-templates
   `(("s" "学习记录" entry
      ;; The time, so several sessions a day stay apart.
      ,(concat "* %<%H:%M> %^{主题}\n:PROPERTIES:\n"
               ":AI:       %^{AI|" (string-join my/kb-ais "|") "}\n"
               ;; Filled one concept at a time with C-c n c.
               ":CONCEPTS:\n:END:\n%?")
      :target (file+head "%<%Y-%m-%d>.org" "#+title: %<%Y-%m-%d>\n"))))
  (org-roam-mode-sections (list #'my/kb-backlinks-section
                                #'org-roam-reflinks-section))
)

(require 'org-id)
(require 'org-roam)
(require 'org-roam-dailies)

;; use-package loads org-roam while compiling, which makes the compiler
;; doubt its functions exist at run time; they do, after the requires.
(declare-function org-roam-db-query "org-roam-db")
(declare-function org-roam-db-update-file "org-roam-db")
(declare-function org-roam-db-clear-file "org-roam-db")
(declare-function org-roam-db--close-all "org-roam-db")
(declare-function org-roam-node-read "org-roam-node")
(declare-function org-roam-node-create "org-roam-node")
(declare-function org-roam-node-slug "org-roam-node")
(declare-function org-roam-backlinks-get "org-roam-mode")
(declare-function org-roam-preview-get-contents "org-roam-mode")
(declare-function org-roam-fontify-like-in-org-mode "org-roam-utils")
(declare-function org-roam-buffer-toggle "org-roam-mode")
(declare-function org-roam-tag-add "org-roam-node")
(declare-function org-roam-alias-add "org-roam-node")
(declare-function magit-insert-heading "magit-section")
(declare-function magit-insert-section--create "magit-section")
(declare-function magit-insert-section--finish "magit-section")

;;; Editing files

(defun my/kb--edit-file (file function)
  "Call FUNCTION at the start of FILE, save FILE and index it.
A buffer visiting FILE is edited and saved; it must have no unsaved
changes, and is first reverted if FILE changed on disk.  Otherwise FILE
is edited in a temporary Org buffer and written back.  Return the value
of FUNCTION."
  (let ((buffer (find-buffer-visiting file))
        result)
    (if buffer
        (with-current-buffer buffer
          (when (buffer-modified-p)
            (user-error "%s 有未保存的修改，请先保存" (buffer-name)))
          (unless (verify-visited-file-modtime buffer)
            (revert-buffer t t t))
          (setq result (org-with-wide-buffer
                        (goto-char (point-min))
                        (funcall function)))
          (save-buffer))
      (with-temp-buffer
        (insert-file-contents file)
        (delay-mode-hooks
          (let ((org-inhibit-startup t))
            (org-mode)))
        (goto-char (point-min))
        (setq result (funcall function))
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region nil nil file nil 'silent))))
    (org-roam-db-update-file file)
    result))

(defun my/kb-set-properties (file properties)
  "Set PROPERTIES, an alist of names and values, in FILE's top drawer.
UPDATED is set to today as well."
  (my/kb--edit-file
   file
   (lambda ()
     (pcase-dolist (`(,name . ,value)
                    (append properties
                            (list (cons "UPDATED" (my/kb-date-string)))))
       (org-entry-put (point-min) name value)))))

;;; Reading concepts

(defun my/kb--concept-node-p (node)
  "Return non-nil if NODE is a concept: the file-level node of a concept file."
  (and (= (org-roam-node-level node) 0)
       (my/kb-concept-file-p (org-roam-node-file node))))

(defun my/kb-read-concept (prompt &optional exclude)
  "Read a concept with PROMPT; return its node, or nil on empty input.
EXCLUDE is an id that is not offered."
  (let ((node (org-roam-node-read
               nil (lambda (node)
                     (and (my/kb--concept-node-p node)
                          (not (equal (org-roam-node-id node) exclude))))
               nil t prompt)))
    (and (org-roam-node-id node) node)))

(defun my/kb--link (node)
  "Return an id link to NODE described by its title."
  (org-link-make-string (concat "id:" (org-roam-node-id node))
                        (org-roam-node-title node)))

(defun my/kb-session-add-concept (concept)
  "Add CONCEPT to the CONCEPTS property of the learning session at point.
The session is the top-level heading around point in a file of
sessions/, also in the buffer capturing it; run this once per concept.
A concept listed already is not added again."
  (interactive (list (or (my/kb-read-concept "涉及的概念：")
                         (user-error "没有选择概念"))))
  (let ((file (buffer-file-name (buffer-base-buffer)))
        (title (org-roam-node-title concept)))
    (unless (and file
                 (string-prefix-p (expand-file-name my/kb-sessions-subdirectory
                                                    (my/kb-root))
                                  (file-truename file)))
      (user-error "请在学习记录（sessions/ 下的文件）里使用"))
    (when (org-before-first-heading-p)
      (user-error "请把光标放在某次学习记录的标题下"))
    (save-excursion
      (org-back-to-heading t)
      (while (and (> (org-outline-level) 1) (org-up-heading-safe)))
      (let ((concepts (or (org-entry-get (point) "CONCEPTS") "")))
        (if (string-search (format "[[id:%s]" (org-roam-node-id concept)) concepts)
            (message "已关联过：%s" title)
          (org-entry-put (point) "CONCEPTS"
                         (string-trim (concat concepts " " (my/kb--link concept))))
          (message "已关联：%s" title))))))

;;; Relations

(defun my/kb--insert-relation (relation node)
  "Add RELATION to NODE as the last item of the Relations section.
The current buffer is a concept in Org mode.  Create the section at the
end when it is missing.  Return the position of the new item."
  (let ((id (org-roam-node-id node)))
    (pcase-dolist (`(,_ ,name ,links) (my/kb-relation-items))
      (when (and (equal name relation)
                 (seq-some (lambda (link)
                             (equal (org-element-property :path link) id))
                           links))
        (user-error "已有这条关系：%s :: %s"
                    relation (org-roam-node-title node)))))
  (let ((headline (org-element-map (org-element-parse-buffer 'headline)
                      'headline
                    (lambda (headline)
                      (and (my/kb--relations-headline-p headline) headline))
                    nil t)))
    (if headline
        (progn
          (goto-char (org-element-property :begin headline))
          (org-end-of-subtree t t)
          (skip-chars-backward " \t\n")
          (end-of-line))
      (goto-char (point-max))
      (skip-chars-backward " \t\n")
      (delete-region (point) (point-max))
      (insert "\n\n* " my/kb-relations-heading))
    (insert "\n")
    (prog1 (point)
      (insert "- " relation " :: " (my/kb--link node))
      (when (eobp) (insert "\n")))))

(defun my/kb-relation-add (file relation target)
  "Add the relation RELATION from the concept FILE to the concept TARGET.
Interactively, FILE is the current buffer's concept, or one read first;
then choose the relation name, from `my/kb-relations', and the target.
In the concept's own buffer the item is inserted and left unsaved, like
an inserted link; otherwise the file is saved and indexed."
  (interactive
   (let* ((file (if (my/kb-concept-file-p buffer-file-name)
                    buffer-file-name
                  (org-roam-node-file
                   (or (my/kb-read-concept "为哪个概念添加关系：")
                       (user-error "没有选择概念")))))
          (relation (completing-read "关系：" my/kb-relations nil t))
          (source (caar (org-roam-db-query
                         [:select id :from nodes
                          :where (and (= file $s1) (= level 0))]
                         file))))
     (list file relation
           (or (my/kb-read-concept (format "%s 的目标概念：" relation) source)
               (user-error "没有选择目标概念")))))
  (if (and buffer-file-name (file-equal-p file buffer-file-name))
      (let ((position (save-excursion
                        (save-restriction
                          (widen)
                          (my/kb--insert-relation relation target)))))
        (unless (<= (point-min) position (point-max))
          (widen))
        (goto-char position))
    (my/kb--edit-file file (lambda ()
                             (my/kb--insert-relation relation target))))
  (message "已添加关系：%s :: %s" relation (org-roam-node-title target)))

;;; Backlinks with relation names

(defun my/kb--link-kind ()
  "Return how the link at point refers to its target.
A relation name for an item of the Relations section, `session' for the
CONCEPTS property of a learning session, nil for anything else."
  (or (my/kb-relation-at-point)
      (let ((element (org-element-at-point)))
        (and (eq (org-element-type element) 'node-property)
             (equal (org-element-property :key element) "CONCEPTS")
             'session))))

(defun my/kb--backlink-kinds (backlinks)
  "Return a hash table from each of BACKLINKS to its `my/kb--link-kind'.
Each source file is read once, from its buffer if one visits it."
  (let ((kinds (make-hash-table :test #'eq)))
    (pcase-dolist (`(,file . ,group)
                   (seq-group-by (lambda (backlink)
                                   (org-roam-node-file
                                    (org-roam-backlink-source-node backlink)))
                                 backlinks))
      (let ((compute (lambda ()
                       (dolist (backlink group)
                         (goto-char (org-roam-backlink-point backlink))
                         (puthash backlink (my/kb--link-kind) kinds)))))
        (if-let* ((buffer (find-buffer-visiting file)))
            (with-current-buffer buffer
              (org-with-wide-buffer (funcall compute)))
          (when (file-exists-p file)
            (with-temp-buffer
              (insert-file-contents file)
              (delay-mode-hooks
                (let ((org-inhibit-startup t))
                  (org-mode)))
              (funcall compute))))))
    kinds))

(defun my/kb--kind-label (kind)
  "Return the label shown before a backlink of KIND."
  (pcase kind
    ('session "学习记录")
    ('nil "链接")
    (_ kind)))

(defun my/kb--kind-rank (kind)
  "Return the sort rank of a backlink of KIND: relations first."
  (pcase kind
    ('session (1+ (length my/kb-relations)))
    ('nil (+ 2 (length my/kb-relations)))
    (_ (or (seq-position my/kb-relations kind) (length my/kb-relations)))))

(defun my/kb-backlinks-section (node)
  "Insert the backlinks of NODE, each labelled with how it links.
Replaces `org-roam-backlinks-section' in `org-roam-mode-sections': the
label is the relation name when the source's Relations section names
NODE (\"requires\" means the source requires NODE), \"学习记录\" for a
session that covered it and \"链接\" for any other link.  Relations come
first, in the order of `my/kb-relations'."
  (when-let* ((backlinks (org-roam-backlinks-get node)))
    (let* ((kinds (my/kb--backlink-kinds backlinks))
           (backlinks
            (sort backlinks
                  :key (lambda (backlink)
                         (list (my/kb--kind-rank (gethash backlink kinds))
                               (org-roam-node-title
                                (org-roam-backlink-source-node backlink)))))))
      (magit-insert-section (org-roam-backlinks)
        (magit-insert-heading "反向链接：")
        (dolist (backlink backlinks)
          (my/kb--insert-backlink backlink (gethash backlink kinds)))
        (insert ?\n)))))

(defun my/kb--insert-backlink (backlink kind)
  "Insert BACKLINK labelled with KIND, as `org-roam-node-insert-section' does."
  (let ((source (org-roam-backlink-source-node backlink))
        (point (org-roam-backlink-point backlink))
        (outline (plist-get (org-roam-backlink-properties backlink) :outline)))
    (magit-insert-section section (org-roam-node-section)
      (insert (propertize (format "[%s]" (my/kb--kind-label kind))
                          'font-lock-face (if (stringp kind)
                                              'my/kb-relation
                                            'org-roam-olp))
              " "
              (propertize (org-roam-node-title source)
                          'font-lock-face 'org-roam-title)
              (format " (%s)"
                      (propertize (if outline
                                      (mapconcat #'org-link-display-format
                                                 outline " > ")
                                    "Top")
                                  'font-lock-face 'org-roam-olp)))
      (magit-insert-heading)
      (oset section node source)
      (magit-insert-section section (org-roam-preview-section)
        (insert (org-roam-fontify-like-in-org-mode
                 (org-roam-preview-get-contents (org-roam-node-file source) point))
                "\n")
        (oset section file (org-roam-node-file source))
        (oset section point point)
        (insert ?\n)))))

;;; Following external changes

(defvar my/kb-sync--queue nil
  "Files waiting to be indexed, oldest first.")

(defvar my/kb-sync--queued (make-hash-table :test #'equal)
  "Set of the files in `my/kb-sync--queue'.")

(defvar my/kb-sync--indexed nil
  "Files whose index changed since the queue was last empty.")

(defvar my/kb-sync--timer nil
  "Timer of the next drain of the queue.")

(defvar my/kb-sync--scan-timer nil
  "Repeating timer of the periodic scan.")

(defvar my/kb-sync--watches nil
  "Alist of watched directories and their file-notify descriptors.")

(defvar my/kb-sync--rebuild nil
  "Process rebuilding the database, while it runs.")

(defvar my/kb-sync-updated-hook nil
  "Hook run once the queue is empty, with the files whose index changed.
After a rebuild the argument is nil.")

(defun my/kb-sync--file-p (file)
  "Return non-nil if FILE, an absolute name, belongs in the database."
  (let ((name (file-name-nondirectory file)))
    (and (string-suffix-p ".org" name)
         (not (string-match-p "\\`[.#]" name))
         (not (string-match-p "/\\.git/" file))
         (string-prefix-p (my/kb-root) file)
         (org-roam-file-p file))))

(defun my/kb-sync--arm (delay)
  "Drain the queue after DELAY seconds of idleness, unless a drain is due.
When Emacs is idle already, an idle timer would wait for the next idle
period, so a plain timer is used."
  (unless (timerp my/kb-sync--timer)
    (setq my/kb-sync--timer
          (if (current-idle-time)
              (run-with-timer delay nil #'my/kb-sync--drain)
            (run-with-idle-timer delay nil #'my/kb-sync--drain)))))

(defun my/kb-sync-enqueue (&rest files)
  "Queue FILES for indexing while Emacs is idle.
Files that no longer exist are removed from the database instead."
  (dolist (file files)
    (let ((file (expand-file-name file)))
      (when (and (my/kb-sync--file-p file)
                 (not (gethash file my/kb-sync--queued)))
        (puthash file t my/kb-sync--queued)
        (setq my/kb-sync--queue (nconc my/kb-sync--queue (list file))))))
  (when my/kb-sync--queue
    (my/kb-sync--arm 0.5)))

(defun my/kb-sync--hash (file)
  "Return the contents hash the database has for FILE, or nil."
  (caar (org-roam-db-query [:select hash :from files :where (= file $s1)] file)))

(defun my/kb-sync--index (file)
  "Bring the database up to date with FILE.
Return non-nil if that changed the database."
  (let ((before (my/kb-sync--hash file)))
    (if (not (file-exists-p file))
        (org-roam-db-clear-file file)
      ;; A buffer that has not caught up with the file yet would be indexed
      ;; in its place.
      (when-let* ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer
          (unless (or (buffer-modified-p) (verify-visited-file-modtime buffer))
            (revert-buffer t t t))))
      (condition-case err
          (progn
            (org-roam-db-update-file file)
            ;; Unchanged contents leave the old time behind, which the next
            ;; scan would report again.
            (org-roam-db-query [:update files :set (= mtime $s1)
                                :where (= file $s2)]
                               (file-attribute-modification-time
                                (file-attributes file))
                               file))
        (error
         (org-roam-db-clear-file file)
         (message "知识库：无法索引 %s：%s" file (error-message-string err)))))
    (not (equal before (my/kb-sync--hash file)))))

(defun my/kb-sync--drain ()
  "Index queued files until input arrives or 50 ms have passed."
  (setq my/kb-sync--timer nil)
  (unless my/kb-sync--rebuild
    (let ((deadline (time-add nil 0.05)))
      (while (and my/kb-sync--queue
                  (not (input-pending-p))
                  (time-less-p nil deadline))
        (let ((file (pop my/kb-sync--queue)))
          (remhash file my/kb-sync--queued)
          (when (my/kb-sync--index file)
            (push file my/kb-sync--indexed)))))
    (cond
     (my/kb-sync--queue (my/kb-sync--arm 0.1))
     (my/kb-sync--indexed
      (let ((files (nreverse my/kb-sync--indexed)))
        (setq my/kb-sync--indexed nil)
        (run-hook-with-args 'my/kb-sync-updated-hook files))))))

(defun my/kb-sync--directories (root)
  "Return ROOT and its subdirectories, skipping hidden ones such as .git."
  (cons root
        (cl-loop for (name . attributes)
                 in (directory-files-and-attributes root t "\\`[^.]" t)
                 when (eq (file-attribute-type attributes) t)
                 append (my/kb-sync--directories (file-name-as-directory name)))))

(defun my/kb-sync--changed-files ()
  "Return the files whose modification time differs from the database's.
Files the database has but the disk does not are included."
  (let ((known (make-hash-table :test #'equal))
        changed)
    (pcase-dolist (`(,file ,mtime)
                   (org-roam-db-query [:select [file mtime] :from files]))
      (puthash file mtime known))
    (dolist (directory (my/kb-sync--directories (my/kb-root)))
      (pcase-dolist (`(,file . ,attributes)
                     (directory-files-and-attributes directory t "\\.org\\'" t))
        (when (and (null (file-attribute-type attributes))
                   (my/kb-sync--file-p file))
          (let ((mtime (gethash file known)))
            (remhash file known)
            (unless (and mtime
                         (time-equal-p mtime (file-attribute-modification-time
                                              attributes)))
              (push file changed))))))
    (maphash (lambda (file _) (push file changed)) known)
    changed))

(defun my/kb-sync-scan ()
  "Queue the files of the knowledge base changed since they were indexed.
Too many changes rebuild the database instead, see
`my/kb-sync-rebuild-threshold'."
  (interactive)
  (unless my/kb-sync--rebuild
    (let ((changed (my/kb-sync--changed-files)))
      (cond
       ((> (length changed) my/kb-sync-rebuild-threshold)
        (my/kb-sync-rebuild))
       (changed
        (apply #'my/kb-sync-enqueue changed)
        (when (called-interactively-p 'interactive)
          (message "知识库：%d 个文件待更新" (length changed))))
       ((called-interactively-p 'interactive)
        (message "知识库数据库已是最新"))))))

(defun my/kb-sync--scan-when-idle ()
  "Scan once Emacs has been idle for a second."
  (if (and (current-idle-time) (time-less-p 1 (current-idle-time)))
      (my/kb-sync-scan)
    (run-with-idle-timer 1 nil #'my/kb-sync-scan)))

(defun my/kb-sync--focus-changed ()
  "Scan when a frame gains focus: other programs may have changed files."
  (when (seq-some #'frame-focus-state (frame-list))
    (my/kb-sync--scan-when-idle)))

(defun my/kb-sync--notify (event)
  "Queue the files of the file-notify EVENT; watch new directories."
  (pcase-let ((`(,descriptor ,action ,file ,file1) event))
    (pcase action
      ('stopped
       (setq my/kb-sync--watches (seq-remove (lambda (watch)
                                               (equal (cdr watch) descriptor))
                                             my/kb-sync--watches)))
      ((or 'created 'changed 'deleted 'renamed)
       (dolist (name (delq nil (list file file1)))
         (if (and (memq action '(created renamed)) (file-directory-p name))
             (progn
               (my/kb-sync--watch (file-name-as-directory name))
               (my/kb-sync--scan-when-idle))
           (my/kb-sync-enqueue name)))))))

(defun my/kb-sync--watch (directory)
  "Watch DIRECTORY for changes, unless it is watched already or hidden."
  (unless (or (assoc directory my/kb-sync--watches)
              (string-match-p "/\\." (substring directory
                                                (length (my/kb-root)))))
    (condition-case err
        (push (cons directory (file-notify-add-watch
                               directory '(change) #'my/kb-sync--notify))
              my/kb-sync--watches)
      (file-notify-error
       (message "知识库：无法监视 %s：%s" directory (error-message-string err))))))

(defun my/kb-sync-start ()
  "Follow changes made to the knowledge base outside Emacs.
Watch its directories, scan now and every `my/kb-sync-scan-interval'
seconds, and when a frame gains focus."
  (my/kb-sync-stop)
  (dolist (directory (my/kb-sync--directories (my/kb-root)))
    (my/kb-sync--watch directory))
  (setq my/kb-sync--scan-timer
        (run-with-timer my/kb-sync-scan-interval my/kb-sync-scan-interval
                        #'my/kb-sync--scan-when-idle))
  (add-function :after after-focus-change-function #'my/kb-sync--focus-changed)
  (run-with-idle-timer 1 nil #'my/kb-sync-scan))

(defun my/kb-sync-stop ()
  "Stop following external changes."
  (pcase-dolist (`(,_ . ,descriptor) my/kb-sync--watches)
    (file-notify-rm-watch descriptor))
  (setq my/kb-sync--watches nil)
  (when (timerp my/kb-sync--scan-timer)
    (cancel-timer my/kb-sync--scan-timer))
  (setq my/kb-sync--scan-timer nil)
  (remove-function after-focus-change-function #'my/kb-sync--focus-changed))

(defun my/kb--emacs ()
  "Return the file name of the running Emacs, for batch subprocesses."
  (expand-file-name invocation-name invocation-directory))

(defun my/kb-sync-rebuild ()
  "Rebuild the database from every file, in a batch Emacs.
The new database is written to a temporary file and replaces the
current one when complete; a scan then picks up files changed during
the rebuild.  Emacs stays usable throughout."
  (interactive)
  (when (process-live-p my/kb-sync--rebuild)
    (user-error "知识库数据库正在重建"))
  (let* ((target org-roam-db-location)
         (temporary (concat target ".rebuild"))
         (form
          `(progn
             (setq package-user-dir ,package-user-dir)
             (package-initialize)
             (require 'org-roam)
             (setq org-roam-directory ,(my/kb-root)
                   org-roam-db-location ,temporary
                   org-roam-file-exclude-regexp ',org-roam-file-exclude-regexp
                   org-roam-file-extensions ',org-roam-file-extensions
                   org-roam-db-extra-links-elements
                   ',org-roam-db-extra-links-elements
                   org-roam-db-extra-links-exclude-keys
                   ',org-roam-db-extra-links-exclude-keys
                   org-id-track-globally nil)
             (org-roam-db-sync))))
    (when (file-exists-p temporary)
      (delete-file temporary))
    (message "知识库：正在后台重建数据库…")
    (setq my/kb-sync--rebuild
          (make-process
           :name "kb-rebuild"
           :buffer (get-buffer-create " *知识库重建*")
           :command (list (my/kb--emacs) "--batch" "-Q"
                          "--eval" (prin1-to-string form))
           :noquery t
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (setq my/kb-sync--rebuild nil)
               (if (and (zerop (process-exit-status process))
                        (file-exists-p temporary))
                   (progn
                     (org-roam-db--close-all)
                     (rename-file temporary target t)
                     (message "知识库：数据库已重建")
                     (my/kb-sync-scan)
                     ;; Files queued during the rebuild wait for no new event.
                     (when my/kb-sync--queue
                       (my/kb-sync--arm 0.5))
                     (run-hook-with-args 'my/kb-sync-updated-hook nil))
                 (message "知识库：重建数据库失败，详见 %s"
                          (buffer-name (process-buffer process))))))))))

;;; Validation and export

(defun my/kb--batch-command (function &rest args)
  "Return the command running FUNCTION of kb-batch.el with ARGS, a list.
The subprocess is a batch Emacs without the configuration, given the
current values of the options it reads."
  (append (list (my/kb--emacs) "--batch" "-Q"
                "-L" (file-name-directory (locate-library "kb-batch"))
                "--eval" (prin1-to-string
                          `(setq my/kb-relations ',my/kb-relations
                                 my/kb-ais ',my/kb-ais))
                "-l" "kb-batch" "-f" function)
          args))

(defun my/kb-check ()
  "Validate the knowledge base in a subprocess.
Findings appear in a compilation buffer; \\[next-error] visits each: an
invalid or missing property, a relation name not in `my/kb-relations',
an id link to nothing."
  (interactive)
  (let ((default-directory (my/kb-root)))
    (compilation-start
     (mapconcat #'shell-quote-argument
                (my/kb--batch-command "my/kb-batch-check" (my/kb-root))
                " ")
     nil (lambda (_) "*知识库校验*"))))

(defvar my/kb--publish nil
  "Process exporting the knowledge base, while it runs.")

(defvar my/kb-publish-cache-directory (my/var "kb-publish/")
  "Directory of org-publish timestamps and id locations for the export.")

(defun my/kb-publish (&optional force)
  "Export the knowledge base to HTML in `my/kb-publish-directory'.
Runs in a subprocess; only changed files are exported again unless
FORCE, the prefix argument, is non-nil.  Links between concepts become
links between pages, and index.html lists every concept."
  (interactive "P")
  (when (process-live-p my/kb--publish)
    (user-error "知识库正在导出"))
  (let ((buffer (get-buffer-create "*知识库导出*"))
        (output (expand-file-name my/kb-publish-directory)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (message "知识库：正在后台导出到 %s…" output)
    (setq my/kb--publish
          (make-process
           :name "kb-publish"
           :buffer buffer
           :command (apply #'my/kb--batch-command "my/kb-batch-publish"
                           (my/kb-root) output my/kb-publish-cache-directory
                           (and force '("force")))
           :noquery t
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (setq my/kb--publish nil)
               (if (zerop (process-exit-status process))
                   (message "知识库已导出：%s"
                            (expand-file-name "index.html" output))
                 (message "知识库导出失败")
                 (display-buffer (process-buffer process)))))))))

;;; Table of concepts

(defun my/kb-concepts ()
  "Return the concepts recorded in the database, as plists.
Keys are :id, :file, :title, :level, :confirmed, :updated (property
values, or nil) and :tags.  Nothing is read from the files."
  (let ((tags (make-hash-table :test #'equal))
        (directory (my/kb-concepts-directory)))
    (pcase-dolist (`(,id ,tag) (org-roam-db-query [:select [node-id tag] :from tags]))
      (push tag (gethash id tags)))
    (cl-loop for (id file title properties)
             in (org-roam-db-query [:select [id file title properties]
                                    :from nodes :where (= level 0)])
             when (string-prefix-p directory file)
             collect (list :id id :file file :title title
                           :level (cdr (assoc "LEVEL" properties))
                           :confirmed (cdr (assoc "CONFIRMED" properties))
                           :updated (cdr (assoc "UPDATED" properties))
                           :tags (sort (gethash id tags))))))

(defvar-local my/kb-table--concepts nil
  "Hash table from the ids of the listed concepts to their plists.")

(defvar-local my/kb-table--unconfirmed nil
  "Non-nil means the table lists only concepts not confirmed.")

(defun my/kb-table--level< (a b)
  "Return non-nil if entry A has a lower LEVEL than entry B.
Values not in `my/kb-levels' come first."
  (< (or (seq-position my/kb-levels (aref (cadr a) 1)) -1)
     (or (seq-position my/kb-levels (aref (cadr b) 1)) -1)))

(defun my/kb-table--entry (concept)
  "Return the `tabulated-list-entries' entry of CONCEPT."
  (let ((level (plist-get concept :level))
        (updated (plist-get concept :updated)))
    (list (plist-get concept :id)
          (vector (plist-get concept :title)
                  (cond ((null level) (propertize "缺失" 'face 'org-warning))
                        ((member level my/kb-levels) level)
                        (t (propertize level 'face 'org-warning)))
                  (if (equal (plist-get concept :confirmed) "t")
                      "已确认"
                    (propertize "待确认" 'face 'org-todo))
                  (if (and updated (string-match "[0-9-]+" updated))
                      (match-string 0 updated)
                    "")
                  (propertize (string-join (plist-get concept :tags) " ")
                              'face 'org-tag)))))

(defun my/kb-table--refresh ()
  "Read the concepts from the database into the table."
  (let ((concepts (make-hash-table :test #'equal))
        (width 10)
        entries)
    (dolist (concept (my/kb-concepts))
      (puthash (plist-get concept :id) concept concepts)
      (unless (and my/kb-table--unconfirmed
                   (equal (plist-get concept :confirmed) "t"))
        (setq width (max width (string-width (plist-get concept :title))))
        (push (my/kb-table--entry concept) entries)))
    (setq my/kb-table--concepts concepts
          tabulated-list-entries entries
          mode-name (if my/kb-table--unconfirmed "知识库：待确认" "知识库"))
    (setf (cadr (aref tabulated-list-format 0)) (min width 48))
    (tabulated-list-init-header)))

(defvar-keymap my/kb-table-mode-map
  :doc "Keys of the knowledge base table."
  :parent tabulated-list-mode-map
  "RET" #'my/kb-table-open
  "o" #'my/kb-table-open
  "+" #'my/kb-table-raise
  "=" #'my/kb-table-raise
  "-" #'my/kb-table-lower
  "1" #'my/kb-table-set-level
  "2" #'my/kb-table-set-level
  "3" #'my/kb-table-set-level
  "4" #'my/kb-table-set-level
  "5" #'my/kb-table-set-level
  "c" #'my/kb-table-confirm
  "u" #'my/kb-table-toggle-unconfirmed
  "g" #'my/kb-table-refresh)

(define-derived-mode my/kb-table-mode tabulated-list-mode "知识库"
  "Table of the concepts of the knowledge base.
\\<my/kb-table-mode-map>\\[my/kb-table-raise] and \\[my/kb-table-lower] raise and lower LEVEL, 1 to 5 set it, \
\\[my/kb-table-confirm] confirms or unconfirms it;
each change is written to the concept's file, with today as UPDATED.
\\[my/kb-table-toggle-unconfirmed] lists only unconfirmed concepts, \
\\[tabulated-list-sort] sorts by the column at point,
\\[my/kb-table-open] opens the concept and \\[my/kb-table-refresh] \
catches up with external changes.

\\{my/kb-table-mode-map}"
  (setq tabulated-list-format
        (vector (list "标题" 30 t)
                (list "掌握程度" 15 #'my/kb-table--level<)
                (list "确认" 7 t)
                (list "更新于" 11 t)
                (list "标签" 0 t))
        tabulated-list-padding 1
        tabulated-list-sort-key '("标题"))
  (add-hook 'tabulated-list-revert-hook #'my/kb-table--refresh nil t))

(defconst my/kb-table--buffer "*知识库*"
  "Name of the table buffer.")

(defun my/kb-table ()
  "List the concepts of the knowledge base in a table."
  (interactive)
  (let ((buffer (get-buffer-create my/kb-table--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'my/kb-table-mode)
        (my/kb-table-mode))
      (revert-buffer))
    (pop-to-buffer-same-window buffer)))

(defun my/kb-table--concept ()
  "Return the plist of the concept at point."
  (or (gethash (tabulated-list-get-id) my/kb-table--concepts)
      (user-error "这一行没有概念")))

(defun my/kb-table--update (concept properties)
  "Write PROPERTIES, an alist, to CONCEPT's file and show them in its row."
  (my/kb-set-properties (plist-get concept :file) properties)
  (pcase-dolist (`(,name . ,value) properties)
    (setq concept (plist-put concept (intern (concat ":" (downcase name))) value)))
  (setq concept (plist-put concept :updated (my/kb-date-string)))
  (puthash (plist-get concept :id) concept my/kb-table--concepts)
  (let ((cells (cadr (my/kb-table--entry concept))))
    (dolist (column '(1 2 3))
      (tabulated-list-set-col column (aref cells column) t))))

(defun my/kb-table-set-level (level)
  "Set the LEVEL of the concept at point to LEVEL.
Interactively, a digit key chooses the level of that rank in
`my/kb-levels'; otherwise the level is read.  With
`my/kb-level-change-confirms', the level is also confirmed."
  (interactive
   (list (if (and (characterp last-command-event)
                  (<= ?1 last-command-event ?9))
             (or (nth (- last-command-event ?1) my/kb-levels)
                 (user-error "没有这一级"))
           (completing-read "掌握程度：" my/kb-levels nil t))))
  (let ((concept (my/kb-table--concept)))
    (my/kb-table--update concept
                         (cons (cons "LEVEL" level)
                               (and my/kb-level-change-confirms
                                    '(("CONFIRMED" . "t")))))
    (message "%s：%s" (plist-get concept :title) level)))

(defun my/kb-table--shift-level (delta)
  "Move the LEVEL of the concept at point DELTA steps up `my/kb-levels'.
A missing or unknown level becomes the lowest one."
  (let* ((rank (seq-position my/kb-levels
                             (plist-get (my/kb-table--concept) :level)))
         (new (if rank (+ rank delta) 0)))
    (unless (< -1 new (length my/kb-levels))
      (user-error (if (> delta 0) "已是最高的掌握程度" "已是最低的掌握程度")))
    (my/kb-table-set-level (nth new my/kb-levels))))

(defun my/kb-table-raise ()
  "Raise the LEVEL of the concept at point by one."
  (interactive)
  (my/kb-table--shift-level 1))

(defun my/kb-table-lower ()
  "Lower the LEVEL of the concept at point by one."
  (interactive)
  (my/kb-table--shift-level -1))

(defun my/kb-table-confirm ()
  "Confirm the LEVEL of the concept at point, or unconfirm a confirmed one.
Then move to the next line."
  (interactive)
  (let* ((concept (my/kb-table--concept))
         (confirm (not (equal (plist-get concept :confirmed) "t"))))
    (my/kb-table--update concept
                         (list (cons "CONFIRMED" (if confirm "t" "nil"))))
    (message "%s：%s" (plist-get concept :title) (if confirm "已确认" "待确认"))
    (forward-line 1)))

(defun my/kb-table-toggle-unconfirmed ()
  "Toggle between listing every concept and only the unconfirmed ones."
  (interactive)
  (setq my/kb-table--unconfirmed (not my/kb-table--unconfirmed))
  (revert-buffer))

(defun my/kb-table-refresh ()
  "Reread the table, and catch up with files changed outside Emacs.
The table is updated again once those files are indexed."
  (interactive)
  (my/kb-sync-scan)
  (revert-buffer))

(defun my/kb-table-open ()
  "Visit the file of the concept at point."
  (interactive)
  (find-file (plist-get (my/kb-table--concept) :file)))

(defun my/kb-table--sync-updated (_files)
  "Reread a live table after the database caught up with changes."
  (when-let* ((buffer (get-buffer my/kb-table--buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'my/kb-table-mode)
        (revert-buffer)))))

(add-hook 'my/kb-sync-updated-hook #'my/kb-table--sync-updated)

;;; Keys

(defvar-keymap my/kb-command-map
  :doc "Knowledge base commands, under C-c n (SPC n with evil)."
  "n" #'my/kb-table
  "f" #'org-roam-node-find
  "i" #'org-roam-node-insert
  "r" #'my/kb-relation-add
  "b" #'org-roam-buffer-toggle
  "d" #'org-roam-dailies-capture-today
  "c" #'my/kb-session-add-concept
  "D" #'org-roam-dailies-goto-today
  "t" #'org-roam-tag-add
  "a" #'org-roam-alias-add
  "v" #'my/kb-check
  "p" #'my/kb-publish
  "s" #'my/kb-sync-scan
  "S" #'my/kb-sync-rebuild)

(keymap-global-set "C-c n" my/kb-command-map)

;; evil may be turned off (see `my/use-evil'); declare it for the compiler.
;; SPC n itself is bound in init-evil.el, so it works before this loads.
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-define-key* "evil-core")

(with-eval-after-load 'evil
  (evil-set-initial-state 'my/kb-table-mode 'normal)
  (evil-define-key* '(normal motion) my/kb-table-mode-map
    (kbd "RET") #'my/kb-table-open
    "o" #'my/kb-table-open
    "+" #'my/kb-table-raise
    "=" #'my/kb-table-raise
    "-" #'my/kb-table-lower
    "1" #'my/kb-table-set-level
    "2" #'my/kb-table-set-level
    "3" #'my/kb-table-set-level
    "4" #'my/kb-table-set-level
    "5" #'my/kb-table-set-level
    "c" #'my/kb-table-confirm
    "u" #'my/kb-table-toggle-unconfirmed
    "S" #'tabulated-list-sort
    "gr" #'my/kb-table-refresh
    "q" #'quit-window))

(my/kb-bootstrap)
(my/kb--enable-autosync)
(my/kb-sync-start)

(provide 'init-kb)
;;; init-kb.el ends here
