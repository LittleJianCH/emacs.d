;;; kb-batch.el --- Knowledge base format, validation and export -*- lexical-binding: t; -*-

;;; Commentary:

;; The file format of the personal knowledge base (see init-kb.el).  It
;; needs nothing but Org.
;;
;; The format, shared with the MCP layer that will read and write it:
;;
;; - One concept per file, concepts/SLUG.org: a file-level node whose
;;   property drawer, at the top of the file, holds ID, LEVEL, CONFIRMED and
;;   UPDATED (and optionally ROAM_ALIASES), followed by #+title and
;;   #+filetags.  LEVEL is one of `my/kb-levels'; CONFIRMED is t or nil;
;;   UPDATED is an inactive date, [YYYY-MM-DD].
;; - Relations are the items of the description list under the top-level
;;   heading "* Relations": "- NAME :: [[id:UUID][Title]]", NAME one of
;;   `my/kb-relations'.
;; - Learning sessions are org-roam dailies, sessions/YYYY-MM-DD.org, one
;;   heading per session with the properties AI (one of `my/kb-ais') and
;;   CONCEPTS, the id links of the concepts it covered.

;;; Code:

(require 'org)
(require 'org-element)
(require 'cl-lib)

(defgroup my/kb nil
  "Personal knowledge base on org-roam."
  :group 'org)

(defconst my/kb-levels
  '("exposed" "walked-through" "can-explain" "can-apply" "implemented")
  "Values of the LEVEL property, from the lowest mastery to the highest.")

(defcustom my/kb-relations '("requires" "prerequisite_of" "generalizes" "related")
  "Relation names allowed in the Relations section of a concept."
  :type '(repeat string)
  :group 'my/kb)

(defcustom my/kb-ais '("claude" "chatgpt")
  "Values of the AI property of a learning session."
  :type '(repeat string)
  :group 'my/kb)

(defconst my/kb-concept-properties '("ID" "LEVEL" "CONFIRMED" "UPDATED")
  "Properties every concept file has in its top property drawer.")

(defconst my/kb-relations-heading "Relations"
  "Title of the top-level heading that holds a concept's relations.")

(defconst my/kb-concepts-subdirectory "concepts/"
  "Directory of the concept files, relative to the knowledge base.")

(defconst my/kb-sessions-subdirectory "sessions/"
  "Directory of the learning sessions (org-roam dailies).")

(defun my/kb-date-string (&optional time)
  "Return TIME, or today, as an UPDATED value: an inactive date."
  (format-time-string "[%Y-%m-%d]" time))

(defun my/kb--item-tag (item)
  "Return the tag of the description list ITEM as a trimmed string, or nil."
  (when-let* ((tag (org-element-property :tag item)))
    (org-trim (substring-no-properties (org-element-interpret-data tag)))))

(defun my/kb--relations-headline-p (headline)
  "Return non-nil if HEADLINE is the top-level Relations heading."
  (and (eq (org-element-type headline) 'headline)
       (= (org-element-property :level headline) 1)
       (equal (org-element-property :raw-value headline)
              my/kb-relations-heading)))

(defun my/kb-relation-at-point ()
  "Return the relation name of the Relations item around point, or nil.
Point is on a link, as in a backlink of the org-roam database: the name
is the tag of the description item containing it, when that item is in
the top-level Relations section."
  (when-let* ((item (org-element-lineage (org-element-at-point) 'item t))
              (headline (org-element-lineage item 'headline))
              ((my/kb--relations-headline-p headline)))
    (my/kb--item-tag item)))

(defun my/kb-relation-items (&optional data)
  "Return the items of the Relations section of the current buffer.
DATA is the buffer parsed by `org-element-parse-buffer', parsed here if
nil.  Each element is (ITEM NAME LINKS): the item element, its tag (the
relation name) or nil, and the id links in the item, nested items
excluded."
  (let (result)
    (org-element-map (or data (org-element-parse-buffer)) 'headline
      (lambda (headline)
        (when (my/kb--relations-headline-p headline)
          (org-element-map (org-element-contents headline) 'item
            (lambda (item)
              (push (list item (my/kb--item-tag item)
                          (org-element-map (org-element-contents item) 'link
                            (lambda (link)
                              (and (equal (org-element-property :type link) "id")
                                   link))
                            nil nil 'item))
                    result))))))
    (nreverse result)))

(provide 'kb-batch)
;;; kb-batch.el ends here
