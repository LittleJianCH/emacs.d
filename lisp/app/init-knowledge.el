;;; init-knowledge.el --- Personal knowledge graph on org-roam -*- lexical-binding: t; -*-

;;; Commentary:

;; A record of what I have learned and how well, kept in a git repository of
;; its own (~/knowledge by default, see `my/knowledge-directory'), which is
;; the `org-roam-directory'.  Each machine may register several and switch
;; between them.
;; AI assistants read and write it through the MCP server of knowledge-mcp.el
;; (bin/knowledge-mcp); Emacs is where I look at it, edit it and confirm levels.
;; The file format is described in knowledge-batch.el.
;;
;;   C-c n n   table of all concepts (SPC n n with evil): sort, raise or
;;             lower LEVEL, confirm, open
;;   C-c n f   find or create a concept      C-c n i   insert a link
;;   C-c n r   add a relation to a concept   C-c n b   backlinks buffer
;;             (in the table: of the concept at point, following the row)
;;   C-c n d   record a learning session     C-c n D   today's sessions
;;   C-c n c   add a concept to the session at point, one per call
;;   C-c n t   add a tag   C-c n a   add an alias
;;   C-c n g   graph of the concepts (org-roam-ui, inside Emacs)
;;   C-c n v   validate the knowledge base (compilation buffer)
;;   C-c n p   export to HTML for the phone (C-u: everything again)
;;   C-c n s   catch up with external changes now   C-c n S   rebuild
;;   C-c n w   switch knowledge base             C-c n W   register one
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
;;   `my/knowledge-sync-scan-interval' seconds once Emacs is idle, when a frame
;;   gains focus, and on `g' in the table.  It catches in-place writes and
;;   whatever changed while Emacs was not running.
;; - `my/knowledge-sync-enqueue', for callers that know what they changed.
;;
;; The queue is drained by timers while Emacs is idle, a file at a time,
;; giving way as soon as input arrives; `org-roam-db-update-file' skips
;; files whose contents hash has not changed.  When a scan finds more than
;; `my/knowledge-sync-rebuild-threshold' changed files (the first run, a large
;; git checkout), a batch Emacs builds a new database in a temporary file,
;; which then replaces the current one, and a scan picks up what changed
;; meanwhile.  Validation and HTML export likewise run in subprocesses.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'knowledge-batch)

(defcustom my/knowledge-directory (expand-file-name "~/knowledge/")
  "Knowledge base for a machine that has none registered yet.
A knowledge base is a git repository of its own, the `org-roam-directory'.
This one is created with two example concepts if it does not exist, and
registered; see `my/knowledge-register' for others.  The current one is
in `my/knowledge-current-directory'."
  :type 'directory
  :group 'my/knowledge)

(defvar my/knowledge-current nil
  "Name of the current knowledge base.")

(defvar my/knowledge-current-directory nil
  "Directory of the current knowledge base, or nil before one is chosen.")

(defcustom my/knowledge-publish-directory (my/var "knowledge-site/")
  "Directory `my/knowledge-publish' writes the HTML version of the knowledge base to."
  :type 'directory
  :group 'my/knowledge)

(defcustom my/knowledge-level-change-confirms t
  "Non-nil means changing LEVEL in the table also sets CONFIRMED to t.
The change is mine, not an assistant's, so the new level is confirmed."
  :type 'boolean
  :group 'my/knowledge)

(defcustom my/knowledge-sync-scan-interval 120
  "Seconds between scans for files changed outside Emacs.
Each scan waits for Emacs to be idle."
  :type 'natnum
  :group 'my/knowledge)

(defcustom my/knowledge-sync-rebuild-threshold 200
  "Changed files a scan may queue; beyond this the database is rebuilt.
The rebuild runs in a subprocess, see `my/knowledge-sync-rebuild'."
  :type 'natnum
  :group 'my/knowledge)

(defface my/knowledge-relation '((t :inherit org-verbatim :weight bold))
  "Face of relation names in the backlinks buffer."
  :group 'my/knowledge)

(defun my/knowledge-root ()
  "Return the true name of the current knowledge base, ending in a slash."
  (file-name-as-directory (file-truename (or my/knowledge-current-directory
                                             my/knowledge-directory))))

(defun my/knowledge-concepts-directory ()
  "Return the directory of the concept files."
  (expand-file-name my/knowledge-concepts-subdirectory (my/knowledge-root)))

(defun my/knowledge-concept-file-p (file)
  "Return non-nil if FILE is a concept file."
  (and file (string-prefix-p (my/knowledge-concepts-directory) (expand-file-name file))))

;;; Creating the knowledge base

(defconst my/knowledge--examples
  '(("Martin-Löf Type Theory" "MLTT" "can-explain" "t"
     ("依值类型论：Π、Σ、恒等类型和宇宙"
      "判断相等与命题相等的区别")
     ("prerequisite_of" . "Normalization by Evaluation"))
    ("Normalization by Evaluation" "NbE" "walked-through" "nil"
     ("eval 进语义域，quote 读回范式")
     ("requires" . "Martin-Löf Type Theory")))
  "Example concepts: title, alias, LEVEL, CONFIRMED, notes and a relation.")

(defun my/knowledge--example-file (root title)
  "Return the concept file for the example TITLE under ROOT."
  (expand-file-name (concat my/knowledge-concepts-subdirectory
                            (org-roam-node-slug (org-roam-node-create :title title))
                            ".org")
                    root))

(defun my/knowledge--git-init (root)
  "Make ROOT a git repository, asynchronously, if git is available."
  (when (executable-find "git")
    (let ((default-directory root))
      (make-process :name "knowledge-git-init" :command '("git" "init" "--quiet")
                    :buffer nil :noquery t))))

(defun my/knowledge-bootstrap (&optional directory)
  "Create DIRECTORY with two related example concepts.
DIRECTORY defaults to `my/knowledge-directory'.  Do nothing if it exists:
existing data is never touched.  The new directory becomes a git
repository; `git init' runs asynchronously."
  (let ((root (expand-file-name (or directory my/knowledge-directory))))
    (unless (file-exists-p root)
      (make-directory (expand-file-name my/knowledge-concepts-subdirectory root) t)
      (make-directory (expand-file-name my/knowledge-sessions-subdirectory root) t)
      (let ((ids (mapcar (lambda (example) (cons (car example) (org-id-uuid)))
                         my/knowledge--examples)))
        (pcase-dolist (`(,title ,alias ,level ,confirmed ,notes
                                (,relation . ,target))
                       my/knowledge--examples)
          (with-temp-file (my/knowledge--example-file root title)
            (insert ":PROPERTIES:\n"
                    (format ":ID:       %s\n" (cdr (assoc title ids)))
                    (format ":ROAM_ALIASES: %s\n" alias)
                    (format ":LEVEL:    %s\n" level)
                    (format ":CONFIRMED: %s\n" confirmed)
                    (format ":UPDATED:  %s\n" (my/knowledge-date-string))
                    ":END:\n"
                    (format "#+title: %s\n" title)
                    "#+filetags: :type_theory:\n\n* Notes\n"
                    (mapconcat (lambda (note) (concat "- " note "\n")) notes)
                    "\n* " my/knowledge-relations-heading "\n"
                    (format "- %s :: [[id:%s][%s]]\n"
                            relation (cdr (assoc target ids)) target)))))
      (my/knowledge--git-init root)
      (message "已创建知识库 %s，含两个示例概念" root))))

;;; org-roam

(defun my/knowledge--enable-autosync ()
  "Turn on `org-roam-db-autosync-mode' without its full synchronization.
Enabling the mode runs `org-roam-db-sync', which reads every file; the
scans of `my/knowledge-sync-start' catch up asynchronously instead."
  (cl-letf (((symbol-function 'org-roam-db-sync) #'ignore))
    (org-roam-db-autosync-mode 1)))

(use-package org-roam
  :ensure t
  :demand t
  :custom
  (org-roam-dailies-directory my/knowledge-sessions-subdirectory)
  (org-roam-capture-templates
   `(("c" "概念" plain "* Notes\n%?\n\n* Relations\n"
      :target (file+head
               ,(concat my/knowledge-concepts-subdirectory "${slug}.org")
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
               ":AI:       %^{AI|" (string-join my/knowledge-ais "|") "}\n"
               ;; Filled one concept at a time with C-c n c.
               ":CONCEPTS:\n:END:\n%?")
      :target (file+head "%<%Y-%m-%d>.org" "#+title: %<%Y-%m-%d>\n"))))
  (org-roam-mode-sections (list #'my/knowledge-backlinks-section
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
(declare-function org-roam-buffer-render-contents "org-roam-mode")
(declare-function org-roam-node-from-id "org-roam-node")
(defvar org-roam-buffer)
(defvar org-roam-buffer-current-node)
(defvar org-roam-buffer-current-directory)
(declare-function org-roam-tag-add "org-roam-node")
(declare-function org-roam-alias-add "org-roam-node")
(declare-function magit-insert-heading "magit-section")
(declare-function magit-insert-section--create "magit-section")
(declare-function magit-insert-section--finish "magit-section")

;;; Editing files

(defun my/knowledge--edit-file (file function)
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
        (my/knowledge-write-atomically file)))
    (org-roam-db-update-file file)
    result))

(defun my/knowledge-set-properties (file properties)
  "Set PROPERTIES, an alist of names and values, in FILE's top drawer.
UPDATED is set to today as well."
  (my/knowledge--edit-file
   file
   (lambda ()
     (pcase-dolist (`(,name . ,value)
                    (append properties
                            (list (cons "UPDATED" (my/knowledge-date-string)))))
       (org-entry-put (point-min) name value)))))

;;; Reading concepts

(defun my/knowledge--concept-node-p (node)
  "Return non-nil if NODE is a concept: the file-level node of a concept file."
  (and (= (org-roam-node-level node) 0)
       (my/knowledge-concept-file-p (org-roam-node-file node))))

(defun my/knowledge-read-concept (prompt &optional exclude)
  "Read a concept with PROMPT; return its node, or nil on empty input.
EXCLUDE is an id that is not offered."
  (let ((node (org-roam-node-read
               nil (lambda (node)
                     (and (my/knowledge--concept-node-p node)
                          (not (equal (org-roam-node-id node) exclude))))
               nil t prompt)))
    (and (org-roam-node-id node) node)))

(defun my/knowledge--link (node)
  "Return an id link to NODE described by its title."
  (org-link-make-string (concat "id:" (org-roam-node-id node))
                        (org-roam-node-title node)))

(defun my/knowledge-session-add-concept (concept)
  "Add CONCEPT to the CONCEPTS property of the learning session at point.
The session is the top-level heading around point in a file of
sessions/, also in the buffer capturing it; run this once per concept.
A concept listed already is not added again."
  (interactive (list (or (my/knowledge-read-concept "涉及的概念：")
                         (user-error "没有选择概念"))))
  (let ((file (buffer-file-name (buffer-base-buffer)))
        (title (org-roam-node-title concept)))
    (unless (and file
                 (string-prefix-p (expand-file-name my/knowledge-sessions-subdirectory
                                                    (my/knowledge-root))
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
                         (string-trim (concat concepts " " (my/knowledge--link concept))))
          (message "已关联：%s" title))))))

;;; Relations

(defun my/knowledge--insert-relation (relation node)
  "Add RELATION to NODE as the last item of the Relations section.
The current buffer is a concept in Org mode.  Return the position of the
new item; signal an error if the relation is there already."
  (or (my/knowledge-insert-relation relation (org-roam-node-id node)
                             (org-roam-node-title node))
      (user-error "已有这条关系：%s :: %s" relation (org-roam-node-title node))))

(defun my/knowledge-relation-add (file relation target)
  "Add the relation RELATION from the concept FILE to the concept TARGET.
Interactively, FILE is the current buffer's concept, or one read first;
then choose the relation name, from `my/knowledge-relations', and the target.
In the concept's own buffer the item is inserted and left unsaved, like
an inserted link; otherwise the file is saved and indexed."
  (interactive
   (let* ((file (if (my/knowledge-concept-file-p buffer-file-name)
                    buffer-file-name
                  (org-roam-node-file
                   (or (my/knowledge-read-concept "为哪个概念添加关系：")
                       (user-error "没有选择概念")))))
          (relation (completing-read "关系：" my/knowledge-relations nil t))
          (source (caar (org-roam-db-query
                         [:select id :from nodes
                          :where (and (= file $s1) (= level 0))]
                         file))))
     (list file relation
           (or (my/knowledge-read-concept (format "%s 的目标概念：" relation) source)
               (user-error "没有选择目标概念")))))
  (if (and buffer-file-name (file-equal-p file buffer-file-name))
      (let ((position (save-excursion
                        (save-restriction
                          (widen)
                          (my/knowledge--insert-relation relation target)))))
        (unless (<= (point-min) position (point-max))
          (widen))
        (goto-char position))
    (my/knowledge--edit-file file (lambda ()
                             (my/knowledge--insert-relation relation target))))
  (message "已添加关系：%s :: %s" relation (org-roam-node-title target)))

;;; Backlinks with relation names

(defun my/knowledge--link-kind ()
  "Return how the link at point refers to its target.
A relation name for an item of the Relations section, `session' for the
CONCEPTS property of a learning session, nil for anything else."
  (or (my/knowledge-relation-at-point)
      (let ((element (org-element-at-point)))
        (and (eq (org-element-type element) 'node-property)
             (equal (org-element-property :key element) "CONCEPTS")
             'session))))

(defun my/knowledge--backlink-kinds (backlinks)
  "Return a hash table from each of BACKLINKS to its `my/knowledge--link-kind'.
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
                         (puthash backlink (my/knowledge--link-kind) kinds)))))
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

(defun my/knowledge--kind-label (kind)
  "Return the label shown before a backlink of KIND."
  (pcase kind
    ('session "学习记录")
    ('nil "链接")
    (_ kind)))

(defun my/knowledge--kind-rank (kind)
  "Return the sort rank of a backlink of KIND: relations first."
  (pcase kind
    ('session (1+ (length my/knowledge-relations)))
    ('nil (+ 2 (length my/knowledge-relations)))
    (_ (or (seq-position my/knowledge-relations kind) (length my/knowledge-relations)))))

(defun my/knowledge-backlinks-section (node)
  "Insert the backlinks of NODE, each labelled with how it links.
Replaces `org-roam-backlinks-section' in `org-roam-mode-sections': the
label is the relation name when the source's Relations section names
NODE (\"requires\" means the source requires NODE), \"学习记录\" for a
session that covered it and \"链接\" for any other link.  Relations come
first, in the order of `my/knowledge-relations'."
  (when-let* ((backlinks (org-roam-backlinks-get node)))
    (let* ((kinds (my/knowledge--backlink-kinds backlinks))
           (backlinks
            (sort backlinks
                  :key (lambda (backlink)
                         (list (my/knowledge--kind-rank (gethash backlink kinds))
                               (org-roam-node-title
                                (org-roam-backlink-source-node backlink)))))))
      (magit-insert-section (org-roam-backlinks)
        (magit-insert-heading "反向链接：")
        (dolist (backlink backlinks)
          (my/knowledge--insert-backlink backlink (gethash backlink kinds)))
        (insert ?\n)))))

(defun my/knowledge--insert-backlink (backlink kind)
  "Insert BACKLINK labelled with KIND, as `org-roam-node-insert-section' does."
  (let ((source (org-roam-backlink-source-node backlink))
        (point (org-roam-backlink-point backlink))
        (outline (plist-get (org-roam-backlink-properties backlink) :outline)))
    (magit-insert-section section (org-roam-node-section)
      (insert (propertize (format "[%s]" (my/knowledge--kind-label kind))
                          'font-lock-face (if (stringp kind)
                                              'my/knowledge-relation
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

(defvar my/knowledge-sync--queue nil
  "Files waiting to be indexed, oldest first.")

(defvar my/knowledge-sync--queued (make-hash-table :test #'equal)
  "Set of the files in `my/knowledge-sync--queue'.")

(defvar my/knowledge-sync--indexed nil
  "Files whose index changed since the queue was last empty.")

(defvar my/knowledge-sync--timer nil
  "Timer of the next drain of the queue.")

(defvar my/knowledge-sync--scan-timer nil
  "Repeating timer of the periodic scan.")

(defvar my/knowledge-sync--watches nil
  "Alist of watched directories and their file-notify descriptors.")

(defvar my/knowledge-sync--rebuild nil
  "Process rebuilding the database, while it runs.")

(defvar my/knowledge-sync-updated-hook nil
  "Hook run once the queue is empty, with the files whose index changed.
After a rebuild the argument is nil.")

(defun my/knowledge-sync--file-p (file)
  "Return non-nil if FILE, an absolute name, belongs in the database."
  (let ((name (file-name-nondirectory file)))
    (and (string-suffix-p ".org" name)
         (not (string-match-p "\\`[.#]" name))
         (not (string-match-p "/\\.git/" file))
         (string-prefix-p (my/knowledge-root) file)
         (org-roam-file-p file))))

(defun my/knowledge-sync--arm (delay)
  "Drain the queue after DELAY seconds of idleness, unless a drain is due.
When Emacs is idle already, an idle timer would wait for the next idle
period, so a plain timer is used."
  (unless (timerp my/knowledge-sync--timer)
    (setq my/knowledge-sync--timer
          (if (current-idle-time)
              (run-with-timer delay nil #'my/knowledge-sync--drain)
            (run-with-idle-timer delay nil #'my/knowledge-sync--drain)))))

(defun my/knowledge-sync-enqueue (&rest files)
  "Queue FILES for indexing while Emacs is idle.
Files that no longer exist are removed from the database instead."
  (dolist (file files)
    (let ((file (expand-file-name file)))
      (when (and (my/knowledge-sync--file-p file)
                 (not (gethash file my/knowledge-sync--queued)))
        (puthash file t my/knowledge-sync--queued)
        (setq my/knowledge-sync--queue (nconc my/knowledge-sync--queue (list file))))))
  (when my/knowledge-sync--queue
    (my/knowledge-sync--arm 0.5)))

(defun my/knowledge-sync--hash (file)
  "Return the contents hash the database has for FILE, or nil."
  (caar (org-roam-db-query [:select hash :from files :where (= file $s1)] file)))

(defun my/knowledge-sync--index (file)
  "Bring the database up to date with FILE.
Return non-nil if that changed the database."
  (let ((before (my/knowledge-sync--hash file)))
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
    (not (equal before (my/knowledge-sync--hash file)))))

(defun my/knowledge-sync--drain ()
  "Index queued files until input arrives or 50 ms have passed."
  (setq my/knowledge-sync--timer nil)
  (unless my/knowledge-sync--rebuild
    (let ((deadline (time-add nil 0.05)))
      (while (and my/knowledge-sync--queue
                  (not (input-pending-p))
                  (time-less-p nil deadline))
        (let ((file (pop my/knowledge-sync--queue)))
          (remhash file my/knowledge-sync--queued)
          (when (my/knowledge-sync--index file)
            (push file my/knowledge-sync--indexed)))))
    (cond
     (my/knowledge-sync--queue (my/knowledge-sync--arm 0.1))
     (my/knowledge-sync--indexed
      (let ((files (nreverse my/knowledge-sync--indexed)))
        (setq my/knowledge-sync--indexed nil)
        (run-hook-with-args 'my/knowledge-sync-updated-hook files))))))

(defun my/knowledge-sync--directories (root)
  "Return ROOT and its subdirectories, skipping hidden ones such as .git."
  (cons root
        (cl-loop for (name . attributes)
                 in (directory-files-and-attributes root t "\\`[^.]" t)
                 when (eq (file-attribute-type attributes) t)
                 append (my/knowledge-sync--directories (file-name-as-directory name)))))

(defun my/knowledge-sync--changed-files ()
  "Return the files whose modification time differs from the database's.
Files the database has but the disk does not are included."
  (let ((known (make-hash-table :test #'equal))
        changed)
    (pcase-dolist (`(,file ,mtime)
                   (org-roam-db-query [:select [file mtime] :from files]))
      (puthash file mtime known))
    (dolist (directory (my/knowledge-sync--directories (my/knowledge-root)))
      (pcase-dolist (`(,file . ,attributes)
                     (directory-files-and-attributes directory t "\\.org\\'" t))
        (when (and (null (file-attribute-type attributes))
                   (my/knowledge-sync--file-p file))
          (let ((mtime (gethash file known)))
            (remhash file known)
            (unless (and mtime
                         (time-equal-p mtime (file-attribute-modification-time
                                              attributes)))
              (push file changed))))))
    (maphash (lambda (file _) (push file changed)) known)
    changed))

(defun my/knowledge-sync-scan ()
  "Queue the files of the knowledge base changed since they were indexed.
Too many changes rebuild the database instead, see
`my/knowledge-sync-rebuild-threshold'.  Files the database has from
another directory, after switching knowledge bases, are removed
at once."
  (interactive)
  (unless my/knowledge-sync--rebuild
    (let* ((root (my/knowledge-root))
           (changed (my/knowledge-sync--changed-files))
           (elsewhere (seq-remove (lambda (file) (string-prefix-p root file))
                                  changed)))
      (when elsewhere
        (dolist (file elsewhere)
          (org-roam-db-clear-file file))
        (setq changed (seq-difference changed elsewhere))
        (run-hook-with-args 'my/knowledge-sync-updated-hook elsewhere))
      (cond
       ((> (length changed) my/knowledge-sync-rebuild-threshold)
        (my/knowledge-sync-rebuild))
       (changed
        (apply #'my/knowledge-sync-enqueue changed)
        (when (called-interactively-p 'interactive)
          (message "知识库：%d 个文件待更新" (length changed))))
       ((called-interactively-p 'interactive)
        (message "知识库数据库已是最新"))))))

(defun my/knowledge-sync--scan-when-idle ()
  "Scan once Emacs has been idle for a second."
  (if (and (current-idle-time) (time-less-p 1 (current-idle-time)))
      (my/knowledge-sync-scan)
    (run-with-idle-timer 1 nil #'my/knowledge-sync-scan)))

(defun my/knowledge-sync--focus-changed ()
  "Scan when a frame gains focus: other programs may have changed files."
  (when (seq-some #'frame-focus-state (frame-list))
    (my/knowledge-sync--scan-when-idle)))

(defun my/knowledge-sync--notify (event)
  "Queue the files of the file-notify EVENT; watch new directories."
  (pcase-let ((`(,descriptor ,action ,file ,file1) event))
    (pcase action
      ('stopped
       (setq my/knowledge-sync--watches (seq-remove (lambda (watch)
                                               (equal (cdr watch) descriptor))
                                             my/knowledge-sync--watches)))
      ((or 'created 'changed 'deleted 'renamed)
       (dolist (name (delq nil (list file file1)))
         (if (and (memq action '(created renamed)) (file-directory-p name))
             (progn
               (my/knowledge-sync--watch (file-name-as-directory name))
               (my/knowledge-sync--scan-when-idle))
           (my/knowledge-sync-enqueue name)))))))

(defun my/knowledge-sync--watch (directory)
  "Watch DIRECTORY for changes, unless it is watched already or hidden."
  (unless (or (assoc directory my/knowledge-sync--watches)
              (string-match-p "/\\." (substring directory
                                                (length (my/knowledge-root)))))
    (condition-case err
        (push (cons directory (file-notify-add-watch
                               directory '(change) #'my/knowledge-sync--notify))
              my/knowledge-sync--watches)
      (file-notify-error
       (message "知识库：无法监视 %s：%s" directory (error-message-string err))))))

(defun my/knowledge-sync-start ()
  "Follow changes made to the knowledge base outside Emacs.
Watch its directories, scan now and every `my/knowledge-sync-scan-interval'
seconds, and when a frame gains focus."
  (my/knowledge-sync-stop)
  (dolist (directory (my/knowledge-sync--directories (my/knowledge-root)))
    (my/knowledge-sync--watch directory))
  (setq my/knowledge-sync--scan-timer
        (run-with-timer my/knowledge-sync-scan-interval my/knowledge-sync-scan-interval
                        #'my/knowledge-sync--scan-when-idle))
  (add-function :after after-focus-change-function #'my/knowledge-sync--focus-changed)
  (run-with-idle-timer 1 nil #'my/knowledge-sync-scan))

(defun my/knowledge-sync-stop ()
  "Stop following external changes."
  (pcase-dolist (`(,_ . ,descriptor) my/knowledge-sync--watches)
    (file-notify-rm-watch descriptor))
  (setq my/knowledge-sync--watches nil)
  (when (timerp my/knowledge-sync--scan-timer)
    (cancel-timer my/knowledge-sync--scan-timer))
  (setq my/knowledge-sync--scan-timer nil)
  (remove-function after-focus-change-function #'my/knowledge-sync--focus-changed))

(defun my/knowledge--emacs ()
  "Return the file name of the running Emacs, for batch subprocesses."
  (expand-file-name invocation-name invocation-directory))

(defun my/knowledge-sync-rebuild ()
  "Rebuild the database from every file, in a batch Emacs.
The new database is written to a temporary file and replaces the
current one when complete; a scan then picks up files changed during
the rebuild.  Emacs stays usable throughout."
  (interactive)
  (when (process-live-p my/knowledge-sync--rebuild)
    (user-error "知识库数据库正在重建"))
  (let* ((target org-roam-db-location)
         (temporary (concat target ".rebuild"))
         (form
          `(progn
             (setq package-user-dir ,package-user-dir)
             (package-initialize)
             (require 'org-roam)
             (setq org-roam-directory ,(my/knowledge-root)
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
    (setq my/knowledge-sync--rebuild
          (make-process
           :name "knowledge-rebuild"
           :buffer (get-buffer-create " *知识库重建*")
           :command (list (my/knowledge--emacs) "--batch" "-Q"
                          "--eval" (prin1-to-string form))
           :noquery t
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (setq my/knowledge-sync--rebuild nil)
               (if (and (zerop (process-exit-status process))
                        (file-exists-p temporary))
                   (progn
                     (org-roam-db--close-all)
                     (rename-file temporary target t)
                     (message "知识库：数据库已重建")
                     (my/knowledge-sync-scan)
                     ;; Files queued during the rebuild wait for no new event.
                     (when my/knowledge-sync--queue
                       (my/knowledge-sync--arm 0.5))
                     (run-hook-with-args 'my/knowledge-sync-updated-hook nil))
                 (message "知识库：重建数据库失败，详见 %s"
                          (buffer-name (process-buffer process))))))))))

;;; Validation and export

(defun my/knowledge--batch-command (function &rest args)
  "Return the command running FUNCTION of knowledge-batch.el with ARGS, a list.
The subprocess is a batch Emacs without the configuration, given the
current values of the options it reads."
  (append (list (my/knowledge--emacs) "--batch" "-Q"
                "-L" (file-name-directory (locate-library "knowledge-batch"))
                "--eval" (prin1-to-string
                          `(setq my/knowledge-relations ',my/knowledge-relations
                                 my/knowledge-ais ',my/knowledge-ais))
                "-l" "knowledge-batch" "-f" function)
          args))

(defun my/knowledge-check ()
  "Validate the knowledge base in a subprocess.
Findings appear in a compilation buffer; \\[next-error] visits each: an
invalid or missing property, a relation name not in `my/knowledge-relations',
an id link to nothing."
  (interactive)
  (let ((default-directory (my/knowledge-root)))
    (compilation-start
     (mapconcat #'shell-quote-argument
                (my/knowledge--batch-command "my/knowledge-batch-check" (my/knowledge-root))
                " ")
     nil (lambda (_) "*知识库校验*"))))

(defvar my/knowledge--publish nil
  "Process exporting the knowledge base, while it runs.")

(defvar my/knowledge-publish-cache-directory (my/var "knowledge-publish/")
  "Directory of org-publish timestamps and id locations for the export.")

(defun my/knowledge--publish-subdirectory ()
  "Return the subdirectory of the current knowledge base in export directories."
  (file-name-as-directory
   (let ((slug (my/knowledge-slug (or my/knowledge-current ""))))
     (if (string-empty-p slug) "default" slug))))

(defun my/knowledge-publish-output ()
  "Return the directory the current knowledge base is exported to."
  (expand-file-name (my/knowledge--publish-subdirectory) my/knowledge-publish-directory))

(defun my/knowledge-publish (&optional force)
  "Export the knowledge base to HTML, see `my/knowledge-publish-output'.
Each knowledge base has its directory in `my/knowledge-publish-directory'.
Runs in a subprocess; only changed files are exported again unless
FORCE, the prefix argument, is non-nil.  Links between concepts become
links between pages, and index.html lists every concept."
  (interactive "P")
  (when (process-live-p my/knowledge--publish)
    (user-error "知识库正在导出"))
  (let ((buffer (get-buffer-create "*知识库导出*"))
        (output (my/knowledge-publish-output)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (message "知识库：正在后台导出到 %s…" output)
    (setq my/knowledge--publish
          (make-process
           :name "knowledge-publish"
           :buffer buffer
           :command (apply #'my/knowledge--batch-command "my/knowledge-batch-publish"
                           (my/knowledge-root) output
                           (expand-file-name (my/knowledge--publish-subdirectory)
                                             my/knowledge-publish-cache-directory)
                           (and force '("force")))
           :noquery t
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (setq my/knowledge--publish nil)
               (if (zerop (process-exit-status process))
                   (message "知识库已导出：%s"
                            (expand-file-name "index.html" output))
                 (message "知识库导出失败")
                 (display-buffer (process-buffer process)))))))))

;;; Table of concepts

(defun my/knowledge-concepts ()
  "Return the concepts recorded in the database, as plists.
Keys are :id, :file, :title, :level, :confirmed, :updated (property
values, or nil) and :tags.  Nothing is read from the files."
  (let ((tags (make-hash-table :test #'equal))
        (directory (my/knowledge-concepts-directory)))
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

(defvar-local my/knowledge-table--concepts nil
  "Hash table from the ids of the listed concepts to their plists.")

(defvar-local my/knowledge-table--unconfirmed nil
  "Non-nil means the table lists only concepts not confirmed.")

(defun my/knowledge-table--level< (a b)
  "Return non-nil if entry A has a lower LEVEL than entry B.
Values not in `my/knowledge-levels' come first."
  (< (or (seq-position my/knowledge-levels (aref (cadr a) 1)) -1)
     (or (seq-position my/knowledge-levels (aref (cadr b) 1)) -1)))

(defun my/knowledge-table--entry (concept)
  "Return the `tabulated-list-entries' entry of CONCEPT."
  (let ((level (plist-get concept :level))
        (updated (plist-get concept :updated)))
    (list (plist-get concept :id)
          (vector (plist-get concept :title)
                  (cond ((null level) (propertize "缺失" 'face 'org-warning))
                        ((member level my/knowledge-levels) level)
                        (t (propertize level 'face 'org-warning)))
                  (if (equal (plist-get concept :confirmed) "t")
                      "已确认"
                    (propertize "待确认" 'face 'org-todo))
                  (if (and updated (string-match "[0-9-]+" updated))
                      (match-string 0 updated)
                    "")
                  (propertize (string-join (plist-get concept :tags) " ")
                              'face 'org-tag)))))

(defun my/knowledge-table--refresh ()
  "Read the concepts from the database into the table."
  (let ((concepts (make-hash-table :test #'equal))
        (width 10)
        entries)
    (dolist (concept (my/knowledge-concepts))
      (puthash (plist-get concept :id) concept concepts)
      (unless (and my/knowledge-table--unconfirmed
                   (equal (plist-get concept :confirmed) "t"))
        (setq width (max width (string-width (plist-get concept :title))))
        (push (my/knowledge-table--entry concept) entries)))
    (setq my/knowledge-table--concepts concepts
          tabulated-list-entries entries
          mode-name (format "知识库「%s」%s" (or my/knowledge-current "")
                            (if my/knowledge-table--unconfirmed "：待确认" "")))
    (setf (cadr (aref tabulated-list-format 0)) (min width 48))
    (tabulated-list-init-header)))

(defvar-keymap my/knowledge-table-mode-map
  :doc "Keys of the knowledge base table."
  :parent tabulated-list-mode-map
  "RET" #'my/knowledge-table-open
  "o" #'my/knowledge-table-open
  "+" #'my/knowledge-table-raise
  "=" #'my/knowledge-table-raise
  "-" #'my/knowledge-table-lower
  "1" #'my/knowledge-table-set-level
  "2" #'my/knowledge-table-set-level
  "3" #'my/knowledge-table-set-level
  "4" #'my/knowledge-table-set-level
  "5" #'my/knowledge-table-set-level
  "c" #'my/knowledge-table-confirm
  "u" #'my/knowledge-table-toggle-unconfirmed
  "b" #'my/knowledge-backlinks
  "g" #'my/knowledge-table-refresh)

(define-derived-mode my/knowledge-table-mode tabulated-list-mode "知识库"
  "Table of the concepts of the knowledge base.
\\<my/knowledge-table-mode-map>\\[my/knowledge-table-raise] and \\[my/knowledge-table-lower] \
raise and lower LEVEL, 1 to 5 set it, \
\\[my/knowledge-table-confirm] confirms or unconfirms it;
each change is written to the concept's file, with today as UPDATED.
\\[my/knowledge-table-toggle-unconfirmed] lists only unconfirmed concepts, \
\\[tabulated-list-sort] sorts by the column at point,
\\[my/knowledge-table-open] opens the concept, \
\\[my/knowledge-backlinks] shows its backlinks, following the row, and
\\[my/knowledge-table-refresh] catches up with external changes.

\\{my/knowledge-table-mode-map}"
  (setq tabulated-list-format
        (vector (list "标题" 30 t)
                (list "掌握程度" 15 #'my/knowledge-table--level<)
                (list "确认" 7 t)
                (list "更新于" 11 t)
                (list "标签" 0 t))
        tabulated-list-padding 1
        tabulated-list-sort-key '("标题"))
  (add-hook 'tabulated-list-revert-hook #'my/knowledge-table--refresh nil t)
  (add-hook 'post-command-hook #'my/knowledge-table--follow nil t))

(defconst my/knowledge-table--buffer "*知识库*"
  "Name of the table buffer.")

(defun my/knowledge-table ()
  "List the concepts of the knowledge base in a table."
  (interactive)
  (let ((buffer (get-buffer-create my/knowledge-table--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'my/knowledge-table-mode)
        (my/knowledge-table-mode))
      (revert-buffer))
    (pop-to-buffer-same-window buffer)))

(defun my/knowledge-table--concept ()
  "Return the plist of the concept at point."
  (or (gethash (tabulated-list-get-id) my/knowledge-table--concepts)
      (user-error "这一行没有概念")))

(defun my/knowledge-table--update (concept properties)
  "Write PROPERTIES, an alist, to CONCEPT's file and show them in its row."
  (my/knowledge-set-properties (plist-get concept :file) properties)
  (pcase-dolist (`(,name . ,value) properties)
    (setq concept (plist-put concept (intern (concat ":" (downcase name))) value)))
  (setq concept (plist-put concept :updated (my/knowledge-date-string)))
  (puthash (plist-get concept :id) concept my/knowledge-table--concepts)
  (let ((cells (cadr (my/knowledge-table--entry concept))))
    (dolist (column '(1 2 3))
      (tabulated-list-set-col column (aref cells column) t))))

(defun my/knowledge-table-set-level (level)
  "Set the LEVEL of the concept at point to LEVEL.
Interactively, a digit key chooses the level of that rank in
`my/knowledge-levels'; otherwise the level is read.  With
`my/knowledge-level-change-confirms', the level is also confirmed."
  (interactive
   (list (if (and (characterp last-command-event)
                  (<= ?1 last-command-event ?9))
             (or (nth (- last-command-event ?1) my/knowledge-levels)
                 (user-error "没有这一级"))
           (completing-read "掌握程度：" my/knowledge-levels nil t))))
  (let ((concept (my/knowledge-table--concept)))
    (my/knowledge-table--update concept
                         (cons (cons "LEVEL" level)
                               (and my/knowledge-level-change-confirms
                                    '(("CONFIRMED" . "t")))))
    (message "%s：%s" (plist-get concept :title) level)))

(defun my/knowledge-table--shift-level (delta)
  "Move the LEVEL of the concept at point DELTA steps up `my/knowledge-levels'.
A missing or unknown level becomes the lowest one."
  (let* ((rank (seq-position my/knowledge-levels
                             (plist-get (my/knowledge-table--concept) :level)))
         (new (if rank (+ rank delta) 0)))
    (unless (< -1 new (length my/knowledge-levels))
      (user-error (if (> delta 0) "已是最高的掌握程度" "已是最低的掌握程度")))
    (my/knowledge-table-set-level (nth new my/knowledge-levels))))

(defun my/knowledge-table-raise ()
  "Raise the LEVEL of the concept at point by one."
  (interactive)
  (my/knowledge-table--shift-level 1))

(defun my/knowledge-table-lower ()
  "Lower the LEVEL of the concept at point by one."
  (interactive)
  (my/knowledge-table--shift-level -1))

(defun my/knowledge-table-confirm ()
  "Confirm the LEVEL of the concept at point, or unconfirm a confirmed one.
Then move to the next line."
  (interactive)
  (let* ((concept (my/knowledge-table--concept))
         (confirm (not (equal (plist-get concept :confirmed) "t"))))
    (my/knowledge-table--update concept
                         (list (cons "CONFIRMED" (if confirm "t" "nil"))))
    (message "%s：%s" (plist-get concept :title) (if confirm "已确认" "待确认"))
    (forward-line 1)))

(defun my/knowledge-table-toggle-unconfirmed ()
  "Toggle between listing every concept and only the unconfirmed ones."
  (interactive)
  (setq my/knowledge-table--unconfirmed (not my/knowledge-table--unconfirmed))
  (revert-buffer))

(defun my/knowledge-table-refresh ()
  "Reread the table, and catch up with files changed outside Emacs.
The table is updated again once those files are indexed."
  (interactive)
  (my/knowledge-sync-scan)
  (revert-buffer))

(defun my/knowledge-table-open ()
  "Visit the file of the concept at point."
  (interactive)
  (find-file (plist-get (my/knowledge-table--concept) :file)))

(defun my/knowledge--show-backlinks (node)
  "Show the backlinks of NODE in the persistent org-roam buffer."
  (setq org-roam-buffer-current-node node
        org-roam-buffer-current-directory org-roam-directory)
  (with-current-buffer (get-buffer-create org-roam-buffer)
    (org-roam-buffer-render-contents)))

(defun my/knowledge-table--row-node ()
  "Return the node of the concept at point in the table, or nil."
  (when-let* ((id (tabulated-list-get-id)))
    (org-roam-node-from-id id)))

(defun my/knowledge-backlinks ()
  "Show or hide the backlinks buffer.
In the table it shows the concept at point, and follows the row as
point moves; elsewhere it is `org-roam-buffer-toggle', which follows
the node at point in Org files."
  (interactive)
  (cond
   ((not (derived-mode-p 'my/knowledge-table-mode))
    (org-roam-buffer-toggle))
   ((get-buffer-window org-roam-buffer)
    (quit-window nil (get-buffer-window org-roam-buffer)))
   (t
    (my/knowledge--show-backlinks (or (my/knowledge-table--row-node)
                                      (user-error "这一行没有概念")))
    (display-buffer org-roam-buffer))))

(defun my/knowledge-table--follow ()
  "Show the backlinks of the row at point, if they are displayed."
  (when-let* (((get-buffer-window org-roam-buffer 'visible))
              (id (tabulated-list-get-id))
              ((not (and org-roam-buffer-current-node
                         (equal id (org-roam-node-id org-roam-buffer-current-node)))))
              (node (org-roam-node-from-id id)))
    (my/knowledge--show-backlinks node)))

(defun my/knowledge-table--sync-updated (_files)
  "Reread a live table after the database caught up with changes."
  (when-let* ((buffer (get-buffer my/knowledge-table--buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'my/knowledge-table-mode)
        (revert-buffer)))))

(add-hook 'my/knowledge-sync-updated-hook #'my/knowledge-table--sync-updated)

;;; Graph

;; org-roam-ui draws the graph in a web page, served by Emacs and shown in
;; an xwidget, which talks back over a websocket (open a node, follow the
;; current buffer).  As shipped, it lets any web site open in a browser read
;; any file through http://localhost:35901/img/PATH (CORS allows every
;; origin), read the notes, and delete any file over the websocket; the
;; HTTP server even listens on every interface.  So here the server listens
;; on localhost only and runs only while a graph buffer is open, requests
;; must name localhost (no DNS rebinding), images come only from the
;; knowledge base, no CORS header is sent, the websocket accepts only the
;; page's own origin, and deleting from the page is disabled.

(declare-function org-roam-ui-mode "org-roam-ui")
(declare-function websocket-origin "websocket")
(declare-function websocket-close "websocket")
(declare-function httpd-error "simple-httpd")
(declare-function httpd-send-file "simple-httpd")
(declare-function xwidget-webkit-browse-url "xwidget")
(declare-function xwidget-webkit-current-session "xwidget")
(declare-function xwidget-buffer "xwidget.c")
(defvar org-roam-ui-mode)
(defvar org-roam-ui-port)
(defvar httpd-host)

(defvar my/knowledge-graph--buffers nil
  "Live buffers showing the graph.")

(defun my/knowledge-graph--local-host-p (host)
  "Return non-nil if HOST, a Host header or origin host, is this machine."
  (and host (string-match-p "\\`\\(?:localhost\\|127\\.0\\.0\\.1\\)\\(?::[0-9]+\\)?\\'"
                            host)))

(defun my/knowledge-graph--guard-http (servlet proc path query request &rest rest)
  "Call SERVLET with PROC, PATH, QUERY, REQUEST and REST if it is safe.
The request must name localhost; an image must be a file of the
knowledge base.  The response allows no other origin."
  (let ((file (and (string-prefix-p "/img/" path)
                   (expand-file-name (org-link-decode (substring path 5))))))
    (cond
     ((not (and (my/knowledge-graph--local-host-p (cadr (assoc "Host" request)))
                (or (null file)
                    (and (file-regular-p file)
                         (string-prefix-p (my/knowledge-root)
                                          (file-truename file))))))
      (httpd-error proc 403))
     ;; org-roam-ui's image servlet sends a second header after the file,
     ;; which current simple-httpd refuses; send the file alone.
     (file (httpd-send-file proc file request))
     (t
      (let ((send (symbol-function 'httpd-send-header)))
        (cl-letf (((symbol-function 'httpd-send-header)
                   (lambda (proc mime status &rest headers)
                     (cl-remf headers :Access-Control-Allow-Origin)
                     (apply send proc mime status headers))))
          (apply servlet proc path query request rest)))))))

(defun my/knowledge-graph--guard-socket (handler socket &rest arguments)
  "Call HANDLER with SOCKET and ARGUMENTS only for the graph page itself."
  (let ((origin (websocket-origin socket)))
    (if (and origin
             (string-match "\\`http://\\([^/]+\\)\\'" origin)
             (my/knowledge-graph--local-host-p (match-string 1 origin)))
        (apply handler socket arguments)
      (message "知识图谱：拒绝来自 %s 的连接" (or origin "未知来源"))
      (websocket-close socket))))

(defun my/knowledge-graph--refuse-delete (_data)
  "Refuse to delete a file for the graph page."
  (message "知识图谱：不能从图谱里删除，请在 Emacs 里删除文件"))

(use-package org-roam-ui
  :ensure t
  :defer t
  :custom
  (org-roam-ui-sync-theme t)
  (org-roam-ui-follow t)
  (org-roam-ui-update-on-save t)
  (org-roam-ui-open-on-start nil)
  (org-roam-ui-browser-function #'my/knowledge-graph--show)
  :config
  (setq httpd-host 'local)
  (dolist (servlet '(httpd/node httpd/img))
    (advice-add servlet :around #'my/knowledge-graph--guard-http))
  (dolist (handler '(org-roam-ui--ws-on-open org-roam-ui--ws-on-message))
    (advice-add handler :around #'my/knowledge-graph--guard-socket))
  (advice-add 'org-roam-ui--on-msg-delete-node :override
              #'my/knowledge-graph--refuse-delete))

(defun my/knowledge-graph--stop-when-unused ()
  "Stop the graph server once no graph buffer is left."
  (setq my/knowledge-graph--buffers
        (seq-filter (lambda (buffer)
                      (and (buffer-live-p buffer)
                           (not (eq buffer (current-buffer)))))
                    my/knowledge-graph--buffers))
  (when (and (null my/knowledge-graph--buffers) org-roam-ui-mode)
    (org-roam-ui-mode -1)))

(defun my/knowledge-graph--close ()
  "Close the graph buffers, which stops the graph server."
  (mapc #'kill-buffer (seq-filter #'buffer-live-p my/knowledge-graph--buffers))
  (setq my/knowledge-graph--buffers nil)
  (when (bound-and-true-p org-roam-ui-mode)
    (org-roam-ui-mode -1)))

(defun my/knowledge-graph--show (url)
  "Show URL in an xwidget in another window, as a graph buffer."
  (let ((switch-to-buffer-obey-display-actions t)
        (display-buffer-overriding-action
         '((display-buffer-use-some-window display-buffer-pop-up-window)
           (inhibit-same-window . t))))
    (xwidget-webkit-browse-url url t))
  (when-let* ((session (xwidget-webkit-current-session))
              (buffer (xwidget-buffer session)))
    (push buffer my/knowledge-graph--buffers)
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook #'my/knowledge-graph--stop-when-unused nil t))))

(defun my/knowledge-graph ()
  "Show the graph of the concepts and sessions, with org-roam-ui.
Clicking a node opens it here; the graph follows the node at point.  The
local server runs while a graph buffer is open."
  (interactive)
  (unless (featurep 'xwidget-internal)
    (user-error "这个 Emacs 没有编译 xwidget，无法在内部显示图谱"))
  (require 'org-roam-ui)
  (unless org-roam-ui-mode
    (org-roam-ui-mode 1))
  (my/knowledge-graph--show (format "http://localhost:%d" org-roam-ui-port)))

;;; Several knowledge bases

;; Each machine registers its own knowledge bases, by name, in
;; `my/knowledge-bases-file' under var/, so no path belongs to the
;; configuration.  One is current at a time: org-roam, the table, the sync,
;; validation, export and the graph all work on it.  Each has a database of
;; its own in `my/knowledge-db-directory', so a base switched back to is
;; still indexed, and only what changed meanwhile is read again.

(defvar my/knowledge-bases-file (my/var "knowledge-bases.eld")
  "File of the knowledge bases registered on this machine.
It holds a plist: :bases, an alist of names and directories, and
:current, the name of the current one.")

(defvar my/knowledge-db-directory (my/var "org-roam/")
  "Directory of the databases of the knowledge bases, one file each.")

(defun my/knowledge--state ()
  "Return the plist saved in `my/knowledge-bases-file', or nil."
  (when (file-readable-p my/knowledge-bases-file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents my/knowledge-bases-file)
          (read (current-buffer)))
      (error
       (display-warning 'init-knowledge
                        (format "无法读取 %s：%s" my/knowledge-bases-file
                                (error-message-string err)))
       nil))))

(defun my/knowledge-bases ()
  "Return the registered knowledge bases: an alist of names and directories."
  (plist-get (my/knowledge--state) :bases))

(defun my/knowledge--save-state (bases current)
  "Save BASES, an alist of names and directories, with CURRENT the current name."
  (make-directory (file-name-directory my/knowledge-bases-file) t)
  (with-temp-buffer
    (let ((print-length nil) (print-level nil))
      (insert ";; Knowledge bases of this machine, see init-knowledge.el.\n")
      (prin1 (list :current current :bases bases) (current-buffer))
      (insert "\n"))
    (my/knowledge-write-atomically my/knowledge-bases-file)))

(defun my/knowledge--db-file (directory)
  "Return the database file of the knowledge base in DIRECTORY."
  (let ((root (file-name-as-directory (file-truename directory))))
    (expand-file-name (format "%s-%s.db"
                              (my/knowledge-slug
                               (file-name-nondirectory (directory-file-name root)))
                              (substring (md5 root) 0 8))
                      my/knowledge-db-directory)))

(defun my/knowledge--registered-name (directory bases)
  "Return the name under which DIRECTORY is in BASES, or nil."
  (car (seq-find (lambda (base) (file-equal-p (cdr base) directory)) bases)))

(defun my/knowledge--activate (name directory)
  "Make DIRECTORY, registered as NAME, the current knowledge base.
Close the previous base's database, stop following its files and close
the graph; then open this base's database and follow its files."
  (my/knowledge-sync-stop)
  (when (timerp my/knowledge-sync--timer)
    (cancel-timer my/knowledge-sync--timer))
  (when (process-live-p my/knowledge-sync--rebuild)
    ;; Its database would replace the new base's.
    (delete-process my/knowledge-sync--rebuild))
  (clrhash my/knowledge-sync--queued)
  (setq my/knowledge-sync--timer nil
        my/knowledge-sync--rebuild nil
        my/knowledge-sync--queue nil
        my/knowledge-sync--indexed nil)
  (my/knowledge-graph--close)
  (org-roam-db--close-all)
  (make-directory my/knowledge-db-directory t)
  (setq my/knowledge-current name
        my/knowledge-current-directory (file-name-as-directory
                                        (expand-file-name directory))
        org-roam-directory (my/knowledge-root)
        org-roam-db-location (my/knowledge--db-file directory)
        org-roam-buffer-current-node nil)
  (my/knowledge-sync-start)
  (my/knowledge-table--sync-updated nil))

(defun my/knowledge--read-base (prompt)
  "Read the name of a registered knowledge base with PROMPT."
  (let* ((bases (or (my/knowledge-bases) (user-error "还没有登记知识库")))
         (completion-extra-properties
          (list :annotation-function
                (lambda (name)
                  (concat "  " (abbreviate-file-name (cdr (assoc name bases)))
                          (if (equal name my/knowledge-current) "（当前）" ""))))))
    (completing-read prompt bases nil t)))

(defun my/knowledge-switch (name)
  "Make the registered knowledge base NAME current, also after a restart."
  (interactive (list (my/knowledge--read-base "切换到知识库：")))
  (let* ((bases (my/knowledge-bases))
         (directory (or (cdr (assoc name bases))
                        (user-error "没有登记名为「%s」的知识库" name))))
    (unless (file-directory-p directory)
      (user-error "知识库「%s」的目录 %s 不存在" name directory))
    (my/knowledge--save-state bases name)
    (my/knowledge--activate name directory)
    (message "已切换到知识库「%s」：%s" name (abbreviate-file-name directory))))

(defun my/knowledge-register (name directory &optional stay)
  "Register DIRECTORY as the knowledge base NAME on this machine.
Then switch to it, unless STAY, the prefix argument, is non-nil.  A
missing directory is created, with concepts/ and sessions/, as a git
repository; in an existing one only missing subdirectories are added."
  (interactive
   (let ((directory (read-directory-name "知识库目录：")))
     (unless (or (file-directory-p directory)
                 (y-or-n-p (format "%s 不存在，创建吗？" directory)))
       (user-error "已取消"))
     (list (read-string "名称：" (file-name-nondirectory
                                  (directory-file-name directory)))
           directory current-prefix-arg)))
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (state (my/knowledge--state))
         (bases (plist-get state :bases))
         (name (string-trim name)))
    (when (string-empty-p name)
      (user-error "名称不能为空"))
    (when (assoc name bases)
      (user-error "已有名为「%s」的知识库" name))
    (when-let* ((other (my/knowledge--registered-name directory bases)))
      (user-error "这个目录已登记为「%s」" other))
    (let ((new (not (file-exists-p directory))))
      (dolist (subdirectory (list my/knowledge-concepts-subdirectory
                                  my/knowledge-sessions-subdirectory))
        (make-directory (expand-file-name subdirectory directory) t))
      (when new
        (my/knowledge--git-init directory)))
    (my/knowledge--save-state (append bases (list (cons name directory)))
                              (plist-get state :current))
    (if stay
        (message "已登记知识库「%s」：%s" name (abbreviate-file-name directory))
      (my/knowledge-switch name))))

(defun my/knowledge-unregister (name)
  "Forget the registered knowledge base NAME on this machine.
Its files stay; its database is deleted.  The current one cannot be
unregistered: switch to another first."
  (interactive (list (my/knowledge--read-base "取消登记知识库：")))
  (let* ((state (my/knowledge--state))
         (bases (plist-get state :bases))
         (directory (or (cdr (assoc name bases))
                        (user-error "没有登记名为「%s」的知识库" name))))
    (when (equal name my/knowledge-current)
      (user-error "「%s」是当前知识库，请先切换到别的" name))
    (when (and (called-interactively-p 'any)
               (not (yes-or-no-p (format "取消登记「%s」？%s 里的文件不会删除 "
                                         name (abbreviate-file-name directory)))))
      (user-error "已取消"))
    (my/knowledge--save-state (assoc-delete-all name bases)
                              (plist-get state :current))
    (let ((database (my/knowledge--db-file directory)))
      (when (file-exists-p database)
        (delete-file database)))
    (message "已取消登记知识库「%s」，文件仍在 %s" name
             (abbreviate-file-name directory))))

(defun my/knowledge--unique-name (name bases)
  "Return NAME, or NAME with a number added, not yet in BASES."
  (let ((candidate name) (n 1))
    (while (assoc candidate bases)
      (setq n (1+ n) candidate (format "%s-%d" name n)))
    candidate))

(defun my/knowledge--initialize ()
  "Make this machine's current knowledge base current in Emacs.
Without one, or if its directory is gone, use `my/knowledge-directory',
created if missing and registered under its file name."
  (let* ((state (my/knowledge--state))
         (bases (plist-get state :bases))
         (name (plist-get state :current))
         (directory (cdr (assoc name bases))))
    (unless (and directory (file-directory-p directory))
      (when directory
        (display-warning 'init-knowledge
                         (format "知识库「%s」的目录 %s 不存在，改用 %s"
                                 name directory my/knowledge-directory)))
      (setq directory (file-name-as-directory (expand-file-name my/knowledge-directory)))
      (my/knowledge-bootstrap directory)
      (setq name (or (my/knowledge--registered-name directory bases)
                     (my/knowledge--unique-name
                      (file-name-nondirectory (directory-file-name directory))
                      bases)))
      (unless (assoc name bases)
        (setq bases (append bases (list (cons name directory)))))
      (my/knowledge--save-state bases name))
    (my/knowledge--activate name directory)))

;;; Keys

(defvar-keymap my/knowledge-command-map
  :doc "Knowledge base commands, under C-c n (SPC n with evil)."
  "n" #'my/knowledge-table
  "f" #'org-roam-node-find
  "i" #'org-roam-node-insert
  "r" #'my/knowledge-relation-add
  "b" #'my/knowledge-backlinks
  "d" #'org-roam-dailies-capture-today
  "c" #'my/knowledge-session-add-concept
  "D" #'org-roam-dailies-goto-today
  "t" #'org-roam-tag-add
  "a" #'org-roam-alias-add
  "g" #'my/knowledge-graph
  "v" #'my/knowledge-check
  "p" #'my/knowledge-publish
  "s" #'my/knowledge-sync-scan
  "S" #'my/knowledge-sync-rebuild
  "w" #'my/knowledge-switch
  "W" #'my/knowledge-register)

(keymap-global-set "C-c n" my/knowledge-command-map)

;; evil may be turned off (see `my/use-evil'); declare it for the compiler.
;; SPC n itself is bound in init-evil.el, so it works before this loads.
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-define-key* "evil-core")

(with-eval-after-load 'evil
  (evil-set-initial-state 'my/knowledge-table-mode 'normal)
  (evil-define-key* '(normal motion) my/knowledge-table-mode-map
    (kbd "RET") #'my/knowledge-table-open
    "o" #'my/knowledge-table-open
    "+" #'my/knowledge-table-raise
    "=" #'my/knowledge-table-raise
    "-" #'my/knowledge-table-lower
    "1" #'my/knowledge-table-set-level
    "2" #'my/knowledge-table-set-level
    "3" #'my/knowledge-table-set-level
    "4" #'my/knowledge-table-set-level
    "5" #'my/knowledge-table-set-level
    "c" #'my/knowledge-table-confirm
    "u" #'my/knowledge-table-toggle-unconfirmed
    "S" #'tabulated-list-sort
    "b" #'my/knowledge-backlinks
    "gr" #'my/knowledge-table-refresh
    "q" #'quit-window))

(my/knowledge--enable-autosync)
(my/knowledge--initialize)

(provide 'init-knowledge)
;;; init-knowledge.el ends here
