;;; knowledge-mcp.el --- MCP server for the knowledge base -*- lexical-binding: t; -*-

;;; Commentary:

;; A Model Context Protocol server, over stdio, through which AI assistants
;; read and write the knowledge base of init-knowledge.el.  bin/knowledge-mcp runs it in a
;; batch Emacs without the configuration:
;;
;;   emacs --batch -Q -L lisp/app -l knowledge-mcp -f my/knowledge-mcp-main [DIRECTORY]
;;
;; DIRECTORY defaults to $KNOWLEDGE_DIRECTORY, then ~/knowledge.  The server works on the
;; files themselves, with the parsing and editing of knowledge-batch.el, so it
;; needs no running Emacs and neither org-roam nor its database; the editor
;; follows the changes it makes.  It is independent of emx.
;;
;; Assistants may set LEVEL but never confirm it: every write of LEVEL sets
;; CONFIRMED to nil and UPDATED to today, and no tool sets CONFIRMED to t.
;; Files are written atomically.  What the files say is read again when
;; their modification time changes, so the index stays current while the
;; editor and other programs change them.  Reading a file costs a few
;; milliseconds, so the index is kept in $KNOWLEDGE_MCP_CACHE (bin/knowledge-mcp uses
;; var/knowledge-mcp/), and a restarted server reads only the files changed since.
;;
;; Customized `my/knowledge-relations' and `my/knowledge-ais' do not reach this process;
;; pass them as --eval forms before -l, as for the other batch commands.

;;; Code:

(require 'knowledge-batch)
(require 'org-id)

(define-error 'my/knowledge-mcp-error "Knowledge base tool error")

(defvar my/knowledge-mcp--root nil
  "The knowledge base served, a true directory name ending in a slash.")

(defvar my/knowledge-mcp--client-ai nil
  "AI of the connected client, guessed from its name at initialization.")

(defvar my/knowledge-mcp--cache (make-hash-table :test #'equal)
  "Hash table from Org files to (MTIME . CONTENTS) as read last.
CONTENTS is (concept . PLIST), (sessions . PLIST) or nil.")

(defconst my/knowledge-mcp--cache-version 1
  "Version of the saved index; change it when the readers change.")

(defvar my/knowledge-mcp--cache-file nil
  "File the index is saved in between runs, or nil.")

(defvar my/knowledge-mcp--cache-dirty nil
  "Non-nil if the index changed since it was saved.")

(defun my/knowledge-mcp--load-cache ()
  "Load the index saved for this knowledge base, if any and current."
  (when (and my/knowledge-mcp--cache-file (file-readable-p my/knowledge-mcp--cache-file))
    (condition-case err
        (let ((data (with-temp-buffer
                      (insert-file-contents my/knowledge-mcp--cache-file)
                      (read (current-buffer)))))
          (when (equal (car data) (list my/knowledge-mcp--cache-version my/knowledge-mcp--root))
            (pcase-dolist (`(,file . ,entry) (cdr data))
              (puthash file entry my/knowledge-mcp--cache))))
      (error (message "knowledge-mcp: ignoring the saved index: %s"
                      (error-message-string err))))))

(defun my/knowledge-mcp--save-cache ()
  "Save the index if it changed."
  (when (and my/knowledge-mcp--cache-file my/knowledge-mcp--cache-dirty)
    (setq my/knowledge-mcp--cache-dirty nil)
    (condition-case err
        (with-temp-buffer
          (let ((print-length nil) (print-level nil) entries)
            (maphash (lambda (file entry) (push (cons file entry) entries))
                     my/knowledge-mcp--cache)
            (prin1 (cons (list my/knowledge-mcp--cache-version my/knowledge-mcp--root) entries)
                   (current-buffer)))
          (make-directory (file-name-directory my/knowledge-mcp--cache-file) t)
          (my/knowledge-write-atomically my/knowledge-mcp--cache-file))
      (error (message "knowledge-mcp: cannot save the index: %s"
                      (error-message-string err))))))

(defun my/knowledge-mcp--fail (format &rest args)
  "Signal a tool error with the message FORMAT applied to ARGS."
  (signal 'my/knowledge-mcp-error (list (apply #'format format args))))

;;; Index

(defun my/knowledge-mcp--kind (file)
  "Return `concept', `sessions' or nil for FILE, by its directory."
  (let ((relative (file-relative-name file my/knowledge-mcp--root)))
    (cond ((string-prefix-p my/knowledge-concepts-subdirectory relative) 'concept)
          ((string-prefix-p my/knowledge-sessions-subdirectory relative) 'sessions))))

(defun my/knowledge-mcp--read (file)
  "Return the contents of FILE for the index."
  (pcase (my/knowledge-mcp--kind file)
    ('concept
     (my/knowledge-with-file file
       (cons 'concept (append (list :file file)
                              (my/knowledge-concept-summary (org-element-parse-buffer))))))
    ('sessions
     (my/knowledge-with-file file
       (cons 'sessions
             (list :file file
                   :date (or (cadr (assoc "TITLE" (org-collect-keywords '("TITLE"))))
                             (file-name-base file))
                   :sessions (my/knowledge-sessions)))))))

(defun my/knowledge-mcp--index ()
  "Return the contents of every Org file of the knowledge base.
Files changed since they were last read are read again."
  (unless (file-directory-p my/knowledge-mcp--root)
    (my/knowledge-mcp--fail "The knowledge base %s does not exist" my/knowledge-mcp--root))
  (let ((files (my/knowledge-files my/knowledge-mcp--root))
        (live (make-hash-table :test #'equal)))
    (dolist (file files)
      (let ((mtime (file-attribute-modification-time (file-attributes file)))
            (cached (gethash file my/knowledge-mcp--cache)))
        (unless (and cached (time-equal-p (car cached) mtime))
          (puthash file (cons mtime (my/knowledge-mcp--read file)) my/knowledge-mcp--cache)
          (setq my/knowledge-mcp--cache-dirty t))
        (puthash file t live)))
    (maphash (lambda (file _)
               (unless (gethash file live)
                 (remhash file my/knowledge-mcp--cache)
                 (setq my/knowledge-mcp--cache-dirty t)))
             my/knowledge-mcp--cache)
    (delq nil (mapcar (lambda (file) (cdr (gethash file my/knowledge-mcp--cache)))
                      files))))

(defun my/knowledge-mcp--concepts ()
  "Return the plists of all concepts, sorted by title."
  (sort (cl-loop for (kind . plist) in (my/knowledge-mcp--index)
                 when (eq kind 'concept) collect plist)
        :key (lambda (concept) (downcase (or (plist-get concept :title) "")))))

(defun my/knowledge-mcp--session-files ()
  "Return the plists of the session files, newest first."
  (sort (cl-loop for (kind . plist) in (my/knowledge-mcp--index)
                 when (eq kind 'sessions) collect plist)
        :key (lambda (file) (plist-get file :date)) :reverse t))

(defun my/knowledge-mcp--names (concept)
  "Return the title and aliases of CONCEPT, downcased."
  (mapcar #'downcase (delq nil (cons (plist-get concept :title)
                                     (plist-get concept :aliases)))))

(defun my/knowledge-mcp--find (reference &optional concepts)
  "Return the concept REFERENCE names: its id, title or an alias.
CONCEPTS defaults to all of them.  Signal an error if none or several
match."
  (unless (and (stringp reference) (not (string-blank-p reference)))
    (my/knowledge-mcp--fail "A concept id, title or alias is required"))
  (let* ((concepts (or concepts (my/knowledge-mcp--concepts)))
         (name (downcase (string-trim reference)))
         (matches (or (seq-filter (lambda (concept)
                                    (equal (plist-get concept :id) reference))
                                  concepts)
                      (seq-filter (lambda (concept)
                                    (member name (my/knowledge-mcp--names concept)))
                                  concepts))))
    (pcase matches
      ('nil (my/knowledge-mcp--fail "No concept is named \"%s\"; use knowledge_search to find it"
                             reference))
      (`(,concept) concept)
      (_ (my/knowledge-mcp--fail "\"%s\" names several concepts: %s; use an id"
                          reference
                          (mapconcat (lambda (concept)
                                       (format "%s (%s)" (plist-get concept :title)
                                               (plist-get concept :id)))
                                     matches ", "))))))

;;; JSON shapes

(defun my/knowledge-mcp--null (value)
  "Return VALUE, or :null for nil."
  (if (null value) :null value))

(defun my/knowledge-mcp--relative (file)
  "Return FILE relative to the knowledge base."
  (file-relative-name file my/knowledge-mcp--root))

(defun my/knowledge-mcp--concept-json (concept)
  "Return the JSON object summarizing CONCEPT."
  `((id . ,(my/knowledge-mcp--null (plist-get concept :id)))
    (title . ,(my/knowledge-mcp--null (plist-get concept :title)))
    (aliases . ,(vconcat (plist-get concept :aliases)))
    (level . ,(my/knowledge-mcp--null (plist-get concept :level)))
    (confirmed . ,(if (equal (plist-get concept :confirmed) "t") t :false))
    (updated . ,(my/knowledge-mcp--null (plist-get concept :updated)))
    (tags . ,(vconcat (plist-get concept :tags)))
    (file . ,(my/knowledge-mcp--relative (plist-get concept :file)))))

;;; Editing

(defun my/knowledge-mcp--edit (file function)
  "Call FUNCTION at the start of FILE in Org mode, then write FILE back.
Return the value of FUNCTION."
  (let ((result (my/knowledge-with-file file
                  (goto-char (point-min))
                  (prog1 (funcall function)
                    (my/knowledge-write-atomically file)))))
    (remhash file my/knowledge-mcp--cache)
    result))

(defun my/knowledge-mcp--check-text (text what &optional multiline)
  "Signal an error unless TEXT is a usable WHAT.
Single-line text must have no line breaks.  MULTILINE text may have
them, but no line starting a top-level heading, which would break the
structure of the file."
  (cond
   ((not (stringp text)) (my/knowledge-mcp--fail "%s must be a string" what))
   ((and (not multiline) (string-match-p "[\n\r]" text))
    (my/knowledge-mcp--fail "%s must be a single line" what))
   ((and multiline (string-match-p "^\\* " text))
    (my/knowledge-mcp--fail "%s must not contain top-level headings (\"* \"); use \"** \""
                     what))))

(defun my/knowledge-mcp--check-member (value allowed what)
  "Signal an error unless VALUE is one of ALLOWED, a list of WHAT."
  (unless (member value allowed)
    (my/knowledge-mcp--fail "Unknown %s \"%s\"; use one of: %s"
                     what value (string-join allowed ", "))))

(defun my/knowledge-mcp--set-level (file level)
  "Set LEVEL in FILE's top drawer, unconfirmed and updated today."
  (my/knowledge-mcp--edit file
                   (lambda ()
                     (org-entry-put (point-min) "LEVEL" level)
                     (org-entry-put (point-min) "CONFIRMED" "nil")
                     (org-entry-put (point-min) "UPDATED" (my/knowledge-date-string)))))

(defun my/knowledge-mcp--notes-end ()
  "Return the position where text is appended to the Notes section.
Create the section before Relations, or at the end, when it is missing."
  (goto-char (point-min))
  (if (re-search-forward "^\\* Notes[ \t]*$" nil t)
      (progn
        (org-end-of-subtree t t)
        (skip-chars-backward " \t\n")
        (end-of-line)
        (insert "\n")
        (point))
    (goto-char (point-min))
    (if (re-search-forward (format "^\\* %s[ \t]*$"
                                   (regexp-quote my/knowledge-relations-heading))
                           nil t)
        (goto-char (match-beginning 0))
      (goto-char (point-max))
      (unless (bolp) (insert "\n")))
    (insert "* Notes\n")
    (save-excursion (insert "\n"))
    (point)))

;;; Tools

(defun my/knowledge-mcp--search (arguments)
  "Find concepts matching ARGUMENTS of knowledge_search."
  (let* ((query (downcase (or (alist-get 'query arguments) "")))
         (terms (split-string query nil t))
         (level (alist-get 'level arguments))
         (confirmed (assq 'confirmed arguments))
         (tag (alist-get 'tag arguments))
         (limit (or (alist-get 'limit arguments) 50))
         (matches
          (seq-filter
           (lambda (concept)
             (let ((text (string-join (append (my/knowledge-mcp--names concept)
                                              (plist-get concept :tags))
                                      " ")))
               (and (seq-every-p (lambda (term) (string-search term text)) terms)
                    (or (null level) (equal level (plist-get concept :level)))
                    (or (null confirmed)
                        (eq (eq (cdr confirmed) t)
                            (equal (plist-get concept :confirmed) "t")))
                    (or (null tag) (member tag (plist-get concept :tags))))))
           (my/knowledge-mcp--concepts))))
    (when level (my/knowledge-mcp--check-member level my/knowledge-levels "level"))
    `((total . ,(length matches))
      (concepts . ,(vconcat (mapcar #'my/knowledge-mcp--concept-json
                                    (take limit matches)))))))

(defun my/knowledge-mcp--notes (file)
  "Return the text of the Notes section of FILE, or nil."
  (my/knowledge-with-file file
    (goto-char (point-min))
    (when (re-search-forward "^\\* Notes[ \t]*$" nil t)
      (let ((start (line-beginning-position 2)))
        (org-end-of-subtree t t)
        (org-string-nw-p (string-trim (buffer-substring-no-properties
                                       (min start (point)) (point))))))))

(defun my/knowledge-mcp--get (arguments)
  "Describe the concept of ARGUMENTS of knowledge_get_concept in full."
  (let* ((concepts (my/knowledge-mcp--concepts))
         (concept (my/knowledge-mcp--find (alist-get 'concept arguments) concepts))
         (id (plist-get concept :id))
         (titles (make-hash-table :test #'equal)))
    (dolist (other concepts)
      (puthash (plist-get other :id) (plist-get other :title) titles))
    (append
     (my/knowledge-mcp--concept-json concept)
     `((notes . ,(my/knowledge-mcp--null (my/knowledge-mcp--notes (plist-get concept :file))))
       (relations
        . ,(vconcat
            (mapcar (pcase-lambda (`(,name ,target ,description))
                      `((relation . ,(my/knowledge-mcp--null name))
                        (id . ,target)
                        (title . ,(my/knowledge-mcp--null (or (gethash target titles)
                                                       description)))
                        (exists . ,(if (gethash target titles) t :false))))
                    (plist-get concept :relations))))
       (incoming
        . ,(vconcat
            (cl-loop for other in concepts
                     append (cl-loop for (name target) in (plist-get other :relations)
                                     when (equal target id)
                                     collect `((relation . ,(my/knowledge-mcp--null name))
                                               (id . ,(plist-get other :id))
                                               (title . ,(plist-get other :title)))))))
       (sessions
        . ,(vconcat
            (cl-loop for file in (my/knowledge-mcp--session-files)
                     append (cl-loop for session in (plist-get file :sessions)
                                     when (member id (plist-get session :concepts))
                                     collect `((date . ,(plist-get file :date))
                                               (heading . ,(plist-get session :heading))
                                               (ai . ,(my/knowledge-mcp--null
                                                       (plist-get session :ai))))))))
       (org . ,(with-temp-buffer
                 (insert-file-contents (plist-get concept :file))
                 (buffer-string)))))))

(defun my/knowledge-mcp--create (arguments)
  "Create the concept of ARGUMENTS of knowledge_create_concept."
  (let* ((title (string-trim (or (alist-get 'title arguments) "")))
         (aliases (alist-get 'aliases arguments))
         (tags (alist-get 'tags arguments))
         (level (or (alist-get 'level arguments) (car my/knowledge-levels)))
         (notes (alist-get 'notes arguments))
         (relations (alist-get 'relations arguments))
         (concepts (my/knowledge-mcp--concepts))
         (file (expand-file-name (concat my/knowledge-concepts-subdirectory
                                         (my/knowledge-slug title) ".org")
                                 my/knowledge-mcp--root)))
    (when (string-empty-p title) (my/knowledge-mcp--fail "A title is required"))
    (my/knowledge-mcp--check-text title "The title")
    (dolist (alias aliases) (my/knowledge-mcp--check-text alias "An alias"))
    (dolist (tag tags)
      (unless (and (stringp tag) (string-match-p "\\`[[:alnum:]_@#%]+\\'" tag))
        (my/knowledge-mcp--fail "Tag \"%s\" may only contain letters, digits, _ @ # %%" tag)))
    (my/knowledge-mcp--check-member level my/knowledge-levels "level")
    (when notes (my/knowledge-mcp--check-text notes "The notes" t))
    (dolist (name (cons title aliases))
      (when-let* ((other (seq-find (lambda (concept)
                                     (member (downcase name) (my/knowledge-mcp--names concept)))
                                   concepts)))
        (my/knowledge-mcp--fail "\"%s\" already names the concept %s (%s)"
                         name (plist-get other :title) (plist-get other :id))))
    (when (string-empty-p (my/knowledge-slug title))
      (my/knowledge-mcp--fail "The title has no letters or digits for a file name"))
    (when (file-exists-p file)
      (my/knowledge-mcp--fail "The file %s exists already" (my/knowledge-mcp--relative file)))
    (let ((targets (mapcar (lambda (relation)
                             (let ((name (alist-get 'relation relation)))
                               (my/knowledge-mcp--check-member
                                name my/knowledge-relations "relation")
                               (cons name (my/knowledge-mcp--find (alist-get 'concept relation)
                                                           concepts))))
                           relations))
          (id (org-id-uuid)))
      (make-directory (file-name-directory file) t)
      (with-temp-buffer
        (insert ":PROPERTIES:\n"
                (format ":ID:       %s\n" id)
                (if aliases
                    (format ":ROAM_ALIASES: %s\n" (combine-and-quote-strings aliases))
                  "")
                (format ":LEVEL:    %s\n" level)
                ":CONFIRMED: nil\n"
                (format ":UPDATED:  %s\n" (my/knowledge-date-string))
                ":END:\n"
                (format "#+title: %s\n" title)
                (if tags (format "#+filetags: :%s:\n" (string-join tags ":")) "")
                "\n* Notes\n"
                (if notes (concat (string-trim notes) "\n") "")
                "\n* " my/knowledge-relations-heading "\n"
                (mapconcat (pcase-lambda (`(,name . ,target))
                             (format "- %s :: %s\n" name
                                     (org-link-make-string
                                      (concat "id:" (plist-get target :id))
                                      (plist-get target :title))))
                           targets))
        (my/knowledge-write-atomically file))
      `((id . ,id) (title . ,title) (level . ,level) (confirmed . :false)
        (file . ,(my/knowledge-mcp--relative file))))))

(defun my/knowledge-mcp--level (arguments)
  "Set the level of ARGUMENTS of knowledge_set_level, unconfirmed."
  (let ((concept (my/knowledge-mcp--find (alist-get 'concept arguments)))
        (level (alist-get 'level arguments)))
    (my/knowledge-mcp--check-member level my/knowledge-levels "level")
    (my/knowledge-mcp--set-level (plist-get concept :file) level)
    `((id . ,(plist-get concept :id)) (title . ,(plist-get concept :title))
      (previous . ,(my/knowledge-mcp--null (plist-get concept :level)))
      (level . ,level) (confirmed . :false))))

(defun my/knowledge-mcp--relation (arguments)
  "Add the relation of ARGUMENTS of knowledge_add_relation."
  (let* ((concepts (my/knowledge-mcp--concepts))
         (concept (my/knowledge-mcp--find (alist-get 'concept arguments) concepts))
         (relation (alist-get 'relation arguments))
         (target (my/knowledge-mcp--find (alist-get 'target arguments) concepts)))
    (my/knowledge-mcp--check-member relation my/knowledge-relations "relation")
    (when (equal (plist-get concept :id) (plist-get target :id))
      (my/knowledge-mcp--fail "A concept cannot relate to itself"))
    (unless (my/knowledge-mcp--edit (plist-get concept :file)
                             (lambda ()
                               (my/knowledge-insert-relation relation (plist-get target :id)
                                                      (plist-get target :title))))
      (my/knowledge-mcp--fail "%s already has %s :: %s" (plist-get concept :title)
                       relation (plist-get target :title)))
    `((concept . ,(plist-get concept :title)) (relation . ,relation)
      (target . ,(plist-get target :title)))))

(defun my/knowledge-mcp--append-notes (arguments)
  "Append the text of ARGUMENTS of knowledge_append_notes to a concept's Notes."
  (let ((concept (my/knowledge-mcp--find (alist-get 'concept arguments)))
        (text (string-trim (or (alist-get 'text arguments) ""))))
    (when (string-empty-p text) (my/knowledge-mcp--fail "The text is empty"))
    (my/knowledge-mcp--check-text text "The text" t)
    (my/knowledge-mcp--edit (plist-get concept :file)
                     (lambda ()
                       (goto-char (my/knowledge-mcp--notes-end))
                       (insert text)
                       (unless (looking-at-p "\n") (insert "\n"))))
    `((concept . ,(plist-get concept :title)) (appended . t))))

(defun my/knowledge-mcp--log-session (arguments)
  "Record the learning session of ARGUMENTS of knowledge_log_session."
  (let* ((topic (string-trim (or (alist-get 'topic arguments) "")))
         (ai (or (alist-get 'ai arguments) my/knowledge-mcp--client-ai
                 (my/knowledge-mcp--fail "Say which AI led the session: ai is one of %s"
                                  (string-join my/knowledge-ais ", "))))
         (date (or (alist-get 'date arguments) (format-time-string "%Y-%m-%d")))
         (time (or (alist-get 'time arguments) (format-time-string "%H:%M")))
         (notes (alist-get 'notes arguments))
         (concepts (my/knowledge-mcp--concepts))
         (covered (seq-uniq (mapcar (lambda (reference)
                                      (my/knowledge-mcp--find reference concepts))
                                    (alist-get 'concepts arguments))))
         (file (expand-file-name (concat my/knowledge-sessions-subdirectory date ".org")
                                 my/knowledge-mcp--root)))
    (when (string-empty-p topic) (my/knowledge-mcp--fail "A topic is required"))
    (my/knowledge-mcp--check-text topic "The topic")
    (my/knowledge-mcp--check-member ai my/knowledge-ais "ai")
    (unless (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" date)
      (my/knowledge-mcp--fail "The date must be YYYY-MM-DD"))
    (unless (string-match-p "\\`[0-9]\\{2\\}:[0-9]\\{2\\}\\'" time)
      (my/knowledge-mcp--fail "The time must be HH:MM"))
    (when notes (my/knowledge-mcp--check-text notes "The notes" t))
    (with-temp-buffer
      (if (file-exists-p file)
          (insert-file-contents file)
        ;; As org-roam-dailies creates it: a file-level node.
        (insert (format ":PROPERTIES:\n:ID:       %s\n:END:\n#+title: %s\n"
                        (org-id-uuid) date)))
      (goto-char (point-max))
      (skip-chars-backward " \t\n")
      (delete-region (point) (point-max))
      (insert (if (bobp) "" "\n\n")
              (format "* %s %s\n:PROPERTIES:\n:AI:       %s\n" time topic ai)
              ":CONCEPTS:"
              (mapconcat (lambda (concept)
                           (concat " " (org-link-make-string
                                        (concat "id:" (plist-get concept :id))
                                        (plist-get concept :title))))
                         covered)
              "\n:END:\n"
              (if notes (concat (string-trim notes) "\n") ""))
      (make-directory (file-name-directory file) t)
      (my/knowledge-write-atomically file))
    (remhash file my/knowledge-mcp--cache)
    `((file . ,(my/knowledge-mcp--relative file)) (heading . ,(format "%s %s" time topic))
      (ai . ,ai)
      (concepts . ,(vconcat (mapcar (lambda (concept) (plist-get concept :title))
                                    covered))))))

(defun my/knowledge-mcp--check (_arguments)
  "Validate the knowledge base."
  (let* ((result (my/knowledge-findings my/knowledge-mcp--root))
         (findings (cdr result)))
    `((files . ,(car result))
      (errors . ,(cl-count 'error findings :key #'cadddr))
      (warnings . ,(cl-count 'warning findings :key #'cadddr))
      (findings
       . ,(vconcat (mapcar (pcase-lambda (`(,file ,line ,column ,severity ,message))
                             `((file . ,file) (line . ,line) (column . ,column)
                               (severity . ,(symbol-name severity))
                               (message . ,message)))
                           findings))))))

(defun my/knowledge-mcp--concept-schema (description)
  "Return the schema of a concept reference described by DESCRIPTION."
  `((type . "string")
    (description . ,(concat description ": its id, title or an alias"))))

(defun my/knowledge-mcp--tools ()
  "Return the tools: (NAME DESCRIPTION INPUT-SCHEMA HANDLER)."
  (let ((levels (vconcat my/knowledge-levels))
        (relations (vconcat my/knowledge-relations))
        (ais (vconcat my/knowledge-ais)))
    `(("knowledge_search"
       ,(concat "List concepts of the user's knowledge base whose title, aliases or tags "
                "contain every word of query (all concepts when it is empty), optionally "
                "filtered by level, confirmation and tag.  Levels, lowest first: "
                (string-join my/knowledge-levels ", ") ".")
       ((type . "object")
        (properties
         (query (type . "string") (description . "Words to look for"))
         (level (type . "string") (enum . ,levels))
         (confirmed (type . "boolean")
                    (description . "Only concepts whose level the user has (not) confirmed"))
         (tag (type . "string"))
         (limit (type . "integer") (description . "At most this many, default 50"))))
       my/knowledge-mcp--search)
      ("knowledge_get_concept"
       ,(concat "Read one concept in full: its properties, notes, relations to other "
                "concepts, relations from them, the learning sessions that covered it, "
                "and the Org source of its file.")
       ((type . "object")
        (properties (concept . ,(my/knowledge-mcp--concept-schema "The concept")))
        (required . ["concept"]))
       my/knowledge-mcp--get)
      ("knowledge_create_concept"
       ,(concat "Create a concept the user has learned about.  Its level starts "
                "unconfirmed: only the user confirms levels.  Check with knowledge_search first "
                "that it does not exist under another name; add an alias instead.")
       ((type . "object")
        (properties
         (title (type . "string"))
         (aliases (type . "array") (items (type . "string"))
                  (description . "Other names, such as abbreviations"))
         (tags (type . "array") (items (type . "string"))
               (description . "Letters, digits and _ only, e.g. type_theory"))
         (level (type . "string") (enum . ,levels)
                (description . "How well the user knows it; default exposed"))
         (notes (type . "string")
                (description . ,(concat "Org text for the Notes section, e.g. \"- point\" "
                                        "lines; no top-level \"* \" headings")))
         (relations (type . "array")
                    (items (type . "object")
                           (properties
                            (relation (type . "string") (enum . ,relations))
                            (concept . ,(my/knowledge-mcp--concept-schema
                                         "The existing concept related to")))
                           (required . ["relation" "concept"]))
                    (description . ,(concat "requires: this needs the other first; "
                                            "prerequisite_of: the other needs this; "
                                            "generalizes: this generalizes the other; "
                                            "related: otherwise linked"))))
        (required . ["title"]))
       my/knowledge-mcp--create)
      ("knowledge_set_level"
       ,(concat "Record how well the user knows a concept now.  The level becomes "
                "unconfirmed until the user confirms it in Emacs.  Levels, lowest first: "
                (string-join my/knowledge-levels ", ") ".")
       ((type . "object")
        (properties (concept . ,(my/knowledge-mcp--concept-schema "The concept"))
                    (level (type . "string") (enum . ,levels)))
        (required . ["concept" "level"]))
       my/knowledge-mcp--level)
      ("knowledge_add_relation"
       ,(concat "Relate one concept to another, e.g. NbE requires MLTT.  "
                "requires: the concept needs the target first; prerequisite_of: the "
                "target needs the concept; generalizes: the concept generalizes the "
                "target; related: otherwise linked.")
       ((type . "object")
        (properties (concept . ,(my/knowledge-mcp--concept-schema "The concept"))
                    (relation (type . "string") (enum . ,relations))
                    (target . ,(my/knowledge-mcp--concept-schema "The target concept")))
        (required . ["concept" "relation" "target"]))
       my/knowledge-mcp--relation)
      ("knowledge_append_notes"
       "Append Org text, such as \"- point\" lines, to the Notes of a concept."
       ((type . "object")
        (properties (concept . ,(my/knowledge-mcp--concept-schema "The concept"))
                    (text (type . "string")
                          (description . "Org text; no top-level \"* \" headings")))
        (required . ["concept" "text"]))
       my/knowledge-mcp--append-notes)
      ("knowledge_log_session"
       ,(concat "Record a learning session with the user: what it was about, which AI "
                "led it and which concepts it covered.  Create missing concepts first.")
       ((type . "object")
        (properties
         (topic (type . "string") (description . "One line"))
         (ai (type . "string") (enum . ,ais)
             (description . "Which AI led it; defaults to this client's when known"))
         (concepts (type . "array")
                   (items . ,(my/knowledge-mcp--concept-schema "A concept covered")))
         (notes (type . "string")
                (description . "Org text for the session; no top-level \"* \" headings"))
         (date (type . "string") (description . "YYYY-MM-DD, default today"))
         (time (type . "string") (description . "HH:MM, default now")))
        (required . ["topic"]))
       my/knowledge-mcp--log-session)
      ("knowledge_check"
       ,(concat "Validate the knowledge base: properties, levels, relation names and "
                "links to missing concepts.  Messages are in Chinese.")
       ((type . "object") (properties . ,(make-hash-table)))
       my/knowledge-mcp--check))))

;;; Protocol

(defconst my/knowledge-mcp--instructions
  (concat
   "The user's personal knowledge base: concepts they have learned, how well "
   "(level, lowest first: " (string-join my/knowledge-levels ", ") "), how concepts "
   "relate, and the learning sessions with AI assistants that covered them.  "
   "Look concepts up before creating them.  After teaching the user, record the "
   "session with knowledge_log_session and update levels with knowledge_set_level.  You can "
   "never confirm a level: the user confirms them in Emacs.")
  "Instructions sent at initialization.")

(defun my/knowledge-mcp--guess-ai (client)
  "Return the member of `my/knowledge-ais' for CLIENT, a client name, or nil."
  (let* ((name (downcase (or client "")))
         (ai (cond ((string-match-p "claude" name) "claude")
                   ((string-match-p "codex\\|openai\\|chatgpt\\|gpt" name) "chatgpt"))))
    (and (member ai my/knowledge-ais) ai)))

(defun my/knowledge-mcp--call (params)
  "Run the tool named in PARAMS of tools/call; return the call's result."
  (let* ((name (alist-get 'name params))
         (tool (assoc name (my/knowledge-mcp--tools))))
    (condition-case err
        (progn
          (unless tool (my/knowledge-mcp--fail "Unknown tool %s" name))
          (let ((value (funcall (nth 3 tool) (alist-get 'arguments params))))
            `((content . [((type . "text")
                           (text . ,(decode-coding-string (json-serialize value)
                                                          'utf-8)))]))))
      (error
       `((content . [((type . "text")
                      (text . ,(if (eq (car err) 'my/knowledge-mcp-error)
                                   (cadr err)
                                 (error-message-string err))))])
         (isError . t))))))

(define-error 'my/knowledge-mcp--unknown "Method not found")

(defun my/knowledge-mcp--dispatch (method params)
  "Answer the request METHOD with PARAMS; return its result.
Signal `my/knowledge-mcp--unknown' for an unknown method."
  (pcase method
    ("initialize"
     (setq my/knowledge-mcp--client-ai
           (my/knowledge-mcp--guess-ai (alist-get 'name (alist-get 'clientInfo params))))
     `((protocolVersion . ,(or (alist-get 'protocolVersion params) "2025-06-18"))
       (capabilities (tools . ,(make-hash-table)))
       (serverInfo (name . "knowledge") (version . "1"))
       (instructions . ,my/knowledge-mcp--instructions)))
    ("ping" (make-hash-table))
    ("tools/list"
     `((tools . ,(vconcat
                  (mapcar (pcase-lambda (`(,name ,description ,schema ,_))
                            `((name . ,name) (description . ,description)
                              (inputSchema . ,schema)))
                          (my/knowledge-mcp--tools))))))
    ("tools/call" (my/knowledge-mcp--call params))
    (_ (signal 'my/knowledge-mcp--unknown (list method)))))

(defun my/knowledge-mcp--handle (line)
  "Return the response to the JSON-RPC message LINE, or nil for none."
  (let ((message (condition-case nil
                     (json-parse-string line :object-type 'alist :array-type 'list
                                        :null-object nil :false-object :false)
                   (json-error 'unparsable))))
    (if (or (eq message 'unparsable) (not (consp message)))
        `((jsonrpc . "2.0") (id . :null)
          (error (code . -32700) (message . "Parse error")))
      (let* ((request (assq 'id message))
             (response
              (condition-case err
                  `((result . ,(or (my/knowledge-mcp--dispatch (alist-get 'method message)
                                                        (alist-get 'params message))
                                   (make-hash-table))))
                (my/knowledge-mcp--unknown
                 `((error (code . -32601)
                          (message . ,(format "Method not found: %s" (cadr err))))))
                (error
                 `((error (code . -32603)
                          (message . ,(error-message-string err))))))))
        ;; Notifications, without an id, get no response.
        (when request
          `((jsonrpc . "2.0") (id . ,(cdr request)) ,@response))))))

(defun my/knowledge-mcp--send (response)
  "Write RESPONSE as one line of JSON to standard output."
  (princ (concat (decode-coding-string (json-serialize response) 'utf-8) "\n")))

(defun my/knowledge-mcp-main ()
  "Serve the knowledge base over stdio until standard input ends.
The directory is the first command-line argument, $KNOWLEDGE_DIRECTORY or ~/knowledge.
The index is saved in the directory $KNOWLEDGE_MCP_CACHE, when set."
  (set-language-environment "UTF-8")
  (setq locale-coding-system 'utf-8
        org-id-track-globally nil
        ;; Reading thousands of files allocates a lot.
        gc-cons-threshold (* 64 1024 1024))
  (set-keyboard-coding-system 'utf-8)
  (set-terminal-coding-system 'utf-8)
  (setq my/knowledge-mcp--root
        (file-name-as-directory
         (file-truename (or (pop command-line-args-left)
                            (getenv "KNOWLEDGE_DIRECTORY")
                            "~/knowledge")))
        command-line-args-left nil
        my/knowledge-mcp--cache-file
        (when-let* ((directory (getenv "KNOWLEDGE_MCP_CACHE")))
          (expand-file-name (concat (md5 my/knowledge-mcp--root) ".eld") directory)))
  (my/knowledge-mcp--load-cache)
  (message "knowledge-mcp: serving %s" my/knowledge-mcp--root)
  (let (line)
    (while (setq line (condition-case nil
                          (read-from-minibuffer "")
                        (end-of-file nil)))
      (unless (string-blank-p line)
        (condition-case err
            (progn
              (when-let* ((response (my/knowledge-mcp--handle line)))
                (my/knowledge-mcp--send response))
              (my/knowledge-mcp--save-cache))
          (error (message "knowledge-mcp: %s" (error-message-string err)))))))
  (kill-emacs 0))

(provide 'knowledge-mcp)
;;; knowledge-mcp.el ends here
