;;; knowledge-batch.el --- Knowledge base format, checks, export -*- lexical-binding: t; -*-

;;; Commentary:

;; The file format of the personal knowledge base (see init-knowledge.el), and the
;; work that reads every file of it.  This file needs nothing but Org, so the
;; validator and the HTML export run in `emacs --batch -Q' subprocesses and
;; never block the editor:
;;
;;   emacs --batch -Q -L lisp/app -l knowledge-batch -f my/knowledge-batch-check DIR
;;   emacs --batch -Q -L lisp/app -l knowledge-batch -f my/knowledge-batch-publish \
;;         DIR OUT CACHE [force]
;;
;; Customized options reach the subprocess as `setq' forms evaluated before
;; this file loads; `defcustom' keeps a value that is already bound.
;;
;; The format, shared with the MCP server of knowledge-mcp.el, which reads and
;; writes it with the functions here:
;;
;; - One concept per file, concepts/SLUG.org: a file-level node whose
;;   property drawer, at the top of the file, holds ID, LEVEL, CONFIRMED and
;;   UPDATED (and optionally ROAM_ALIASES), followed by #+title and
;;   #+filetags.  LEVEL is one of `my/knowledge-levels'; CONFIRMED is t or nil;
;;   UPDATED is an inactive date, [YYYY-MM-DD].
;; - Relations are the items of the description list under the top-level
;;   heading "* Relations": "- NAME :: [[id:UUID][Title]]", NAME one of
;;   `my/knowledge-relations'.
;; - Learning sessions are org-roam dailies, sessions/YYYY-MM-DD.org, one
;;   heading per session with the properties AI (one of `my/knowledge-ais') and
;;   CONCEPTS, the id links of the concepts it covered.

;;; Code:

(require 'org)
(require 'org-element)
(require 'cl-lib)

(defgroup my/knowledge nil
  "Personal knowledge base on org-roam."
  :group 'org)

(defconst my/knowledge-levels
  '("exposed" "walked-through" "can-explain" "can-apply" "implemented")
  "Values of the LEVEL property, from the lowest mastery to the highest.")

(defcustom my/knowledge-relations '("requires" "prerequisite_of" "generalizes" "related")
  "Relation names allowed in the Relations section of a concept."
  :type '(repeat string)
  :group 'my/knowledge)

(defcustom my/knowledge-ais '("claude" "chatgpt")
  "Values of the AI property of a learning session."
  :type '(repeat string)
  :group 'my/knowledge)

(defconst my/knowledge-concept-properties '("ID" "LEVEL" "CONFIRMED" "UPDATED")
  "Properties every concept file has in its top property drawer.")

(defconst my/knowledge-relations-heading "Relations"
  "Title of the top-level heading that holds a concept's relations.")

(defconst my/knowledge-concepts-subdirectory "concepts/"
  "Directory of the concept files, relative to the knowledge base.")

(defconst my/knowledge-sessions-subdirectory "sessions/"
  "Directory of the learning sessions (org-roam dailies).")

(defun my/knowledge-date-string (&optional time)
  "Return TIME, or today, as an UPDATED value: an inactive date."
  (format-time-string "[%Y-%m-%d]" time))

(defun my/knowledge--item-tag (item)
  "Return the tag of the description list ITEM as a trimmed string, or nil."
  (when-let* ((tag (org-element-property :tag item)))
    (org-trim (substring-no-properties (org-element-interpret-data tag)))))

(defun my/knowledge--relations-headline-p (headline)
  "Return non-nil if HEADLINE is the top-level Relations heading."
  (and (eq (org-element-type headline) 'headline)
       (= (org-element-property :level headline) 1)
       (equal (org-element-property :raw-value headline)
              my/knowledge-relations-heading)))

(defun my/knowledge-relation-at-point ()
  "Return the relation name of the Relations item around point, or nil.
Point is on a link, as in a backlink of the org-roam database: the name
is the tag of the description item containing it, when that item is in
the top-level Relations section."
  (when-let* ((item (org-element-lineage (org-element-at-point) 'item t))
              (headline (org-element-lineage item 'headline))
              ((my/knowledge--relations-headline-p headline)))
    (my/knowledge--item-tag item)))

(defun my/knowledge-relation-items (&optional data)
  "Return the items of the Relations section of the current buffer.
DATA is the buffer parsed by `org-element-parse-buffer', parsed here if
nil.  Each element is (ITEM NAME LINKS): the item element, its tag (the
relation name) or nil, and the id links in the item, nested items
excluded."
  (let (result)
    (org-element-map (or data (org-element-parse-buffer)) 'headline
      (lambda (headline)
        (when (my/knowledge--relations-headline-p headline)
          (org-element-map (org-element-contents headline) 'item
            (lambda (item)
              (push (list item (my/knowledge--item-tag item)
                          (org-element-map (org-element-contents item) 'link
                            (lambda (link)
                              (and (equal (org-element-property :type link) "id")
                                   link))
                            nil nil 'item))
                    result))))))
    (nreverse result)))

(defun my/knowledge-slug (title)
  "Return the file name, without directory and extension, for TITLE.
The same as `org-roam-node-slugify': letters and digits kept, anything
else turned into underscores, lowercase.  Concepts live in
concepts/SLUG.org."
  (require 'ucs-normalize)
  (let ((slug-trim-chars
         ;; Combining diacritical marks dropped after decomposition.
         '(#x300 #x301 #x302 #x303 #x304 #x306 #x307
           #x308 #x309 #x30A #x30B #x30C #x31B #x323
           #x324 #x325 #x327 #x32D #x32E #x330 #x331)))
    (thread-last title
                 (ucs-normalize-NFD-string)
                 (seq-remove (lambda (char) (memq char slug-trim-chars)))
                 (apply #'string)
                 (ucs-normalize-NFC-string)
                 (replace-regexp-in-string "[^[:alnum:]]" "_")
                 (replace-regexp-in-string "__*" "_")
                 (replace-regexp-in-string "^_" "")
                 (replace-regexp-in-string "_$" "")
                 (downcase))))

(defun my/knowledge-insert-relation (relation id title)
  "Add the item RELATION :: [[id:ID][TITLE]] at the end of Relations.
The current buffer is a concept in Org mode; the section is created at
the end when it is missing.  Return the position of the new item, or nil
if the section has that relation to ID already."
  (unless (seq-some (pcase-lambda (`(,_ ,name ,links))
                      (and (equal name relation)
                           (seq-some (lambda (link)
                                       (equal (org-element-property :path link) id))
                                     links)))
                    (my/knowledge-relation-items))
    (let ((headline (org-element-map (org-element-parse-buffer 'headline)
                        'headline
                      (lambda (headline)
                        (and (my/knowledge--relations-headline-p headline) headline))
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
        (insert "\n\n* " my/knowledge-relations-heading))
      (insert "\n")
      (prog1 (point)
        (insert "- " relation " :: "
                (org-link-make-string (concat "id:" id) title))
        (when (eobp) (insert "\n"))))))

(defun my/knowledge--link-description (link)
  "Return the description of LINK as a string, or nil."
  (when-let* ((contents (org-element-contents link)))
    (org-trim (substring-no-properties (org-element-interpret-data contents)))))

(defun my/knowledge-concept-summary (&optional data)
  "Return a plist describing the concept in the current Org buffer.
DATA is the parsed buffer, parsed here if nil.  Keys are :id, :title,
:aliases, :level, :confirmed, :updated (property values or nil), :tags
and :relations, a list of (NAME ID TITLE) for the links of the Relations
items, NAME nil for an item without a tag."
  (let ((keywords (org-collect-keywords '("TITLE" "FILETAGS")))
        (property (lambda (name) (org-entry-get (point-min) name))))
    (list :id (funcall property "ID")
          :title (cadr (assoc "TITLE" keywords))
          :aliases (split-string-and-unquote
                    (or (funcall property "ROAM_ALIASES") ""))
          :level (funcall property "LEVEL")
          :confirmed (funcall property "CONFIRMED")
          :updated (funcall property "UPDATED")
          :tags (split-string (or (cadr (assoc "FILETAGS" keywords)) "")
                              ":" t "[ \t]+")
          :relations (cl-loop for (_ name links) in (my/knowledge-relation-items data)
                              append (mapcar
                                      (lambda (link)
                                        (list name
                                              (org-element-property :path link)
                                              (my/knowledge--link-description link)))
                                      links)))))

(defun my/knowledge-id-links (string)
  "Return the ids of the id links in STRING, in order."
  (let ((start 0) ids)
    (while (string-match "\\[\\[id:\\([^]:]+\\)" string start)
      (push (match-string 1 string) ids)
      (setq start (match-end 0)))
    (nreverse ids)))

(defun my/knowledge-sessions (&optional data)
  "Return the learning sessions in the current Org buffer, as plists.
DATA is the parsed buffer, parsed here if nil.  A session is a top-level
heading; keys are :heading, :ai, :concepts (the ids of its CONCEPTS) and
:begin, the position of the heading."
  (org-element-map (or data (org-element-parse-buffer 'headline)) 'headline
    (lambda (headline)
      (when (= (org-element-property :level headline) 1)
        (list :heading (org-element-property :raw-value headline)
              :ai (org-element-property :AI headline)
              :concepts (my/knowledge-id-links
                         (or (org-element-property :CONCEPTS headline) ""))
              :begin (org-element-property :begin headline))))))

(defun my/knowledge-write-atomically (file)
  "Write the current buffer to FILE through a temporary file and a rename.
Watchers see the rename, as they see an editor's atomic save, and never a
half-written file.  FILE keeps its modes; a new file gets the default.
The temporary name starts with a dot, which the knowledge base ignores."
  (let ((temporary (make-temp-file (expand-file-name ".knowledge-" (file-name-directory file))
                                   nil ".tmp"))
        (coding-system-for-write 'utf-8-unix))
    (condition-case err
        (progn
          (write-region nil nil temporary nil 'silent)
          ;; make-temp-file creates it private; keep the file's own modes.
          (set-file-modes temporary (or (file-modes file)
                                        (logand #o666 (default-file-modes))))
          (rename-file temporary file t))
      (error
       (ignore-errors (delete-file temporary))
       (signal (car err) (cdr err))))))

(defun my/knowledge-files (root)
  "Return the Org files under ROOT, sorted, skipping hidden files and directories."
  (sort (directory-files-recursively
         root "\\`[^.#].*\\.org\\'" nil
         (lambda (directory)
           (not (string-prefix-p "." (file-name-nondirectory directory)))))))

(defmacro my/knowledge-with-file (file &rest body)
  "Run BODY in a temporary Org buffer holding FILE."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert-file-contents ,file)
     (delay-mode-hooks
       (let ((org-inhibit-startup t))
         (org-mode)))
     ,@body))

;;; Validation

(defvar my/knowledge-batch--findings nil
  "Findings of the validation: (FILE LINE COLUMN SEVERITY MESSAGE).")

(defvar my/knowledge-batch--file nil
  "File being validated, relative to the knowledge base.")

(defun my/knowledge-batch--report (severity position format &rest args)
  "Record a finding of SEVERITY at POSITION of the current buffer.
SEVERITY is `error' or `warning'; the message is FORMAT applied to ARGS."
  (save-excursion
    (goto-char position)
    (push (list my/knowledge-batch--file (line-number-at-pos) (1+ (current-column))
                severity (apply #'format format args))
          my/knowledge-batch--findings)))

(defun my/knowledge-batch--top-drawer (data)
  "Return the property drawer of the file-level node in DATA, or nil."
  (org-element-map data 'property-drawer
    (lambda (drawer)
      (and (not (org-element-lineage drawer 'headline)) drawer))
    nil t 'headline))

(defun my/knowledge-batch--check-concept (data)
  "Validate the concept file in the current buffer, parsed as DATA."
  (let* ((drawer (my/knowledge-batch--top-drawer data))
         (properties (and drawer
                          (org-element-map drawer 'node-property
                            (lambda (property)
                              (cons (org-element-property :key property)
                                    property))))))
    (if (not drawer)
        (my/knowledge-batch--report 'error (point-min) "缺少文件顶部的 property drawer")
      (dolist (name my/knowledge-concept-properties)
        (unless (assoc-string name properties t)
          (my/knowledge-batch--report 'error (org-element-property :begin drawer)
                               "缺少属性 %s" name)))
      (pcase-dolist (`(,name ,valid ,expected)
                     `(("LEVEL" ,(lambda (value) (member value my/knowledge-levels))
                        ,(string-join my/knowledge-levels " / "))
                       ("CONFIRMED" ,(lambda (value) (member value '("t" "nil")))
                        "t / nil")
                       ("UPDATED"
                        ,(lambda (value)
                           (string-match-p "\\`\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\( [^]]+\\)?\\]\\'"
                                           value))
                        "[YYYY-MM-DD]")))
        (when-let* ((property (cdr (assoc-string name properties t)))
                    (value (or (org-element-property :value property) ""))
                    ((not (funcall valid value))))
          (my/knowledge-batch--report 'error (org-element-property :begin property)
                               "%s 的值「%s」不合法，应为 %s"
                               name value expected))))
    (unless (org-element-map data 'keyword
              (lambda (keyword)
                (equal (org-element-property :key keyword) "TITLE"))
              nil t)
      (my/knowledge-batch--report 'error (point-min) "缺少 #+title"))
    (pcase-dolist (`(,item ,name ,links) (my/knowledge-relation-items data))
      (let ((position (org-element-property :begin item)))
        (cond
         ((null name)
          (my/knowledge-batch--report 'error position
                               "Relations 下的条目应写成「关系名 :: [[id:…][…]]」"))
         ((not (member name my/knowledge-relations))
          (my/knowledge-batch--report 'error position "未知的关系名 %s，可用：%s"
                               name (string-join my/knowledge-relations " / ")))
         ((null links)
          (my/knowledge-batch--report 'error position "关系 %s 没有 id 链接" name)))))))

(defun my/knowledge-batch--check-session (data)
  "Validate the learning sessions in the current buffer, parsed as DATA."
  (org-element-map data 'headline
    (lambda (headline)
      (when (= (org-element-property :level headline) 1)
        (let ((ai (org-element-property :AI headline))
              (position (org-element-property :begin headline)))
          (cond
           ((null ai)
            (my/knowledge-batch--report 'warning position "学习记录缺少 AI 属性"))
           ((not (member ai my/knowledge-ais))
            (my/knowledge-batch--report 'warning position "AI 的值「%s」不在 %s 中"
                                 ai (string-join my/knowledge-ais " / ")))))))))

(defun my/knowledge-findings (root)
  "Validate the knowledge base ROOT; return (FILES . FINDINGS).
FILES is the number of files read.  FINDINGS are sorted lists (FILE LINE
COLUMN SEVERITY MESSAGE), FILE relative to ROOT and SEVERITY `error' or
`warning'."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (files (my/knowledge-files root))
         (ids (make-hash-table :test #'equal))
         links)
    (setq my/knowledge-batch--findings nil)
    (dolist (file files)
      (setq my/knowledge-batch--file (file-relative-name file root))
      (my/knowledge-with-file file
        (let ((data (org-element-parse-buffer)))
          (org-element-map data 'node-property
            (lambda (property)
              (when (equal (upcase (org-element-property :key property)) "ID")
                (let ((id (org-element-property :value property))
                      (position (org-element-property :begin property)))
                  (if-let* ((first (gethash id ids)))
                      (my/knowledge-batch--report
                       'error position "重复的 ID %s（另见 %s:%d）"
                       id (car first) (cdr first))
                    (puthash id (cons my/knowledge-batch--file
                                      (line-number-at-pos position))
                             ids))))))
          ;; Links in property values and keywords are not link objects, so
          ;; search the text, as org-roam does.
          (goto-char (point-min))
          (while (re-search-forward "\\[\\[id:\\([^]]+\\)\\]" nil t)
            (push (list my/knowledge-batch--file (match-beginning 0)
                        (replace-regexp-in-string "::.*\\'" "" (match-string 1))
                        (line-number-at-pos (match-beginning 0))
                        (save-excursion (goto-char (match-beginning 0))
                                        (1+ (current-column))))
                  links))
          (cond
           ((string-prefix-p my/knowledge-concepts-subdirectory my/knowledge-batch--file)
            (my/knowledge-batch--check-concept data))
           ((string-prefix-p my/knowledge-sessions-subdirectory my/knowledge-batch--file)
            (my/knowledge-batch--check-session data))))))
    (pcase-dolist (`(,file ,_ ,id ,line ,column) links)
      (unless (gethash id ids)
        (push (list file line column 'error (format "悬空链接：id %s 不存在" id))
              my/knowledge-batch--findings)))
    (cons (length files)
          (sort my/knowledge-batch--findings :key (lambda (finding) (take 3 finding))))))

(defun my/knowledge-batch-check ()
  "Validate the knowledge base given on the command line.
Print one finding per line in the format of compilation buffers, with
file names relative to the knowledge base, and a summary.  Exit with
status 1 if there are errors."
  (let ((result (my/knowledge-findings (or (pop command-line-args-left)
                                    (error "Usage: my/knowledge-batch-check DIR"))))
        (errors 0)
        (warnings 0))
    (setq command-line-args-left nil)
    (dolist (finding (cdr result))
      (pcase-let ((`(,file ,line ,column ,severity ,message) finding))
        (if (eq severity 'error) (cl-incf errors) (cl-incf warnings))
        (princ (format "%s:%d:%d: %s: %s\n" file line column severity message))))
    (princ (format "检查了 %d 个文件：%d 个错误，%d 个警告\n"
                   (car result) errors warnings))
    (kill-emacs (if (> errors 0) 1 0))))

;;; Export

(defvar org-publish-timestamp-directory)
(defvar org-publish-project-alist)
(defvar org-export-with-broken-links)
(defvar org-html-validation-link)

(defconst my/knowledge-batch--html-head
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<style>
body { max-width: 44rem; margin: 0 auto; padding: 1rem;
       font: 17px/1.6 -apple-system, system-ui, sans-serif; }
table { border-collapse: collapse; width: 100%; }
th, td { padding: .3em .5em; border-bottom: 1px solid #8884; text-align: left; }
nav { margin-bottom: 1rem; }
.knowledge-meta { color: #888; }
@media (prefers-color-scheme: dark) {
  body { background: #1d1f21; color: #ddd; }
  a { color: #8ab4f8; }
}
</style>"
  "Head of every exported page: readable on a phone, light or dark.")

(defvar my/knowledge-batch--root nil
  "Knowledge base being exported, ending in a slash.")

(defun my/knowledge-batch--preamble (info)
  "Return the link back to the index for the page exported with INFO."
  (format "<nav><a href=\"%sindex.html\">← 目录</a></nav>"
          (file-relative-name my/knowledge-batch--root
                              (file-name-directory (plist-get info :input-file)))))

(defun my/knowledge-batch--show-properties (_backend)
  "Show the properties of concepts and sessions in the exported text.
Property drawers are not exported.  Runs in the export's copy of the
buffer, before parsing, so the files are not touched."
  (let ((concept-line
         (when-let* ((level (org-entry-get (point-min) "LEVEL")))
           (format "@@html:<p class=\"knowledge-meta\">@@掌握程度：%s · %s · 更新于 %s@@html:</p>@@\n"
                   level
                   (if (equal (org-entry-get (point-min) "CONFIRMED") "t")
                       "已确认" "待确认")
                   (string-trim (or (org-entry-get (point-min) "UPDATED") "")
                                "\\[" "\\]"))))
        sessions)
    (goto-char (point-min))
    (while (re-search-forward org-outline-regexp-bol nil t)
      (let ((ai (org-entry-get (point) "AI"))
            (concepts (org-string-nw-p (org-entry-get (point) "CONCEPTS"))))
        (when (or ai concepts)
          (save-excursion
            (org-end-of-meta-data)
            (push (cons (point-marker)
                        (concat (and ai (format "AI：%s" ai))
                                (and ai concepts " · ")
                                (and concepts (format "涉及概念：%s" concepts))
                                "\n"))
                  sessions)))))
    (pcase-dolist (`(,marker . ,text) sessions)
      (goto-char marker)
      (insert text))
    (when concept-line
      (goto-char (point-min))
      (if (re-search-forward org-outline-regexp-bol nil t)
          (goto-char (match-beginning 0))
        (goto-char (point-max)))
      (insert "\n" concept-line "\n"))))

(defun my/knowledge-batch--index (root files)
  "Return the Org text of the index of the knowledge base ROOT.
FILES are its Org files."
  (let (concepts sessions)
    (dolist (file files)
      (let ((relative (file-relative-name file root)))
        (cond
         ((string-prefix-p my/knowledge-concepts-subdirectory relative)
          (my/knowledge-with-file file
            (let ((keywords (org-collect-keywords '("TITLE" "FILETAGS"))))
              (push (list (or (cadr (assoc "TITLE" keywords))
                              (file-name-base file))
                          relative
                          (org-entry-get (point-min) "LEVEL")
                          (org-entry-get (point-min) "CONFIRMED")
                          (org-entry-get (point-min) "UPDATED")
                          (string-join (split-string (or (cadr (assoc "FILETAGS" keywords))
                                                         "")
                                                     ":" t " +")
                                       " "))
                    concepts))))
         ((string-prefix-p my/knowledge-sessions-subdirectory relative)
          (push relative sessions)))))
    (let ((cell (lambda (text)
                  (replace-regexp-in-string "|" "\\vert{}" (or text "") t t)))
          (page (lambda (relative)
                  (concat (file-name-sans-extension relative) ".html"))))
      (concat
       "#+title: 知识库\n\n* 概念\n\n| 概念 | 掌握程度 | 确认 | 更新于 | 标签 |\n|-\n"
       (mapconcat
        (pcase-lambda (`(,title ,relative ,level ,confirmed ,updated ,tags))
          (format "| [[file:%s][%s]] | %s | %s | %s | %s |\n"
                  (funcall page relative) (funcall cell title)
                  (funcall cell level)
                  (if (equal confirmed "t") "已确认" "待确认")
                  (funcall cell (string-trim (or updated "") "\\[" "\\]"))
                  (funcall cell tags)))
        (sort concepts :key #'car))
       "\n* 学习记录\n\n"
       (mapconcat (lambda (relative)
                    (format "- [[file:%s][%s]]\n" (funcall page relative)
                            (file-name-base relative)))
                  (sort sessions :reverse t))))))

(defun my/knowledge-batch-publish ()
  "Export the knowledge base to HTML, with arguments from the command line.
The arguments are the knowledge base, the output directory, a cache
directory for org-publish timestamps and id locations, and optionally
\"force\" to export every file again.  Nothing is written to the
knowledge base."
  (require 'ox-publish)
  (require 'ox-html)
  (require 'org-id)
  (pcase-let* ((`(,root ,output ,cache ,force) command-line-args-left)
               ;; Export turns the files of id links into names relative to
               ;; the page, from org-id's true names: give it true names.
               (root (file-name-as-directory (file-truename root)))
               (output (file-name-as-directory (expand-file-name output)))
               (cache (file-name-as-directory (expand-file-name cache)))
               (files (my/knowledge-files root)))
    (setq command-line-args-left nil
          my/knowledge-batch--root root
          org-id-locations-file (expand-file-name "id-locations" cache)
          org-id-track-globally t
          org-publish-timestamp-directory (expand-file-name "timestamps/" cache)
          org-export-use-babel nil
          ;; A dangling link (see `my/knowledge-batch-check') must not stop the export.
          org-export-with-broken-links 'mark
          org-html-validation-link nil
          org-publish-project-alist
          `(("knowledge"
             :base-directory ,root
             :base-extension "org"
             :recursive t
             :exclude "\\(?:\\`\\|/\\)[.#]"
             :publishing-directory ,output
             :publishing-function org-html-publish-to-html
             :with-toc nil
             :section-numbers nil
             :with-author nil
             :with-creator nil
             :time-stamp-file nil
             :html-head ,my/knowledge-batch--html-head
             :html-head-include-scripts nil
             :html-preamble my/knowledge-batch--preamble
             :html-postamble nil)))
    (make-directory cache t)
    (make-directory output t)
    (add-hook 'org-export-before-parsing-functions #'my/knowledge-batch--show-properties)
    (princ (format "正在导出 %d 个文件…\n" (length files)))
    (org-id-update-id-locations files t)
    (org-publish "knowledge" (equal force "force"))
    (with-temp-buffer
      (insert (my/knowledge-batch--index root files))
      (org-mode)
      (let ((default-directory output))
        (org-export-to-file 'html (expand-file-name "index.html" output) nil nil nil nil
                            (list :with-toc nil :section-numbers nil
                                  :html-head my/knowledge-batch--html-head
                                  :html-head-include-scripts nil
                                  :html-preamble nil :html-postamble nil))))
    (princ (format "导出完成：%s\n" (expand-file-name "index.html" output)))))

(provide 'knowledge-batch)
;;; knowledge-batch.el ends here
