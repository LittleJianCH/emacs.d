;;; agent-review-test.el --- Tests for agent-review -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds reviews of a throwaway Git repository: coverage checking, plan
;; parts, annotations and the review buffer.  Needs git on PATH.

;;; Code:

(require 'ert)
(require 'agent-review)

(defun agent-review-test--git (dir &rest args)
  "Run git with ARGS in DIR with a fixed identity and no user config."
  (let ((default-directory dir)
        (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@example.com"
                                       "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@example.com"
                                       "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1")
                                     process-environment)))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %S: %s" args (buffer-string))))))

(defun agent-review-test--write (file lines)
  "Write LINES to FILE, one per line."
  (with-temp-file file (insert (mapconcat (lambda (line) (concat line "\n")) lines ""))))

(defun agent-review-test--setup (repo)
  "Make REPO: main has a.txt; feature edits lines 2 and 18 and adds b.el."
  (let ((lines (mapcar (lambda (i) (format "line %d" i)) (number-sequence 1 20))))
    (agent-review-test--git repo "init" "-q" "-b" "main")
    (agent-review-test--write (expand-file-name "a.txt" repo) lines)
    (agent-review-test--git repo "add" ".")
    (agent-review-test--git repo "commit" "-q" "-m" "base")
    (agent-review-test--git repo "checkout" "-q" "-b" "feature")
    (setf (nth 1 lines) "line two" (nth 17 lines) "line eighteen")
    (agent-review-test--write (expand-file-name "a.txt" repo) lines)
    (agent-review-test--write (expand-file-name "b.el" repo)
                              (mapcar (lambda (i) (format "(b %d)" i)) (number-sequence 1 10)))
    (agent-review-test--git repo "add" ".")
    (agent-review-test--git repo "commit" "-q" "-m" "feature")))

(defmacro agent-review-test--with-repo (repo &rest body)
  "Run BODY with REPO bound to a fresh repository and a fresh review store."
  (declare (indent 1))
  `(let* ((,repo (file-name-as-directory (make-temp-file "agent-review-repo" t)))
          (agent-review-directory (file-name-as-directory (make-temp-file "agent-review-store" t))))
     (unwind-protect
         (progn (agent-review-test--setup ,repo) ,@body)
       (delete-directory ,repo t)
       (delete-directory agent-review-directory t))))

(defun agent-review-test--item (title type &rest parts)
  "A planned item as it arrives from JSON."
  (list :title title :intent (concat title "的原因") :type type :parts (vconcat parts)))

(defun agent-review-test--plan (&optional last)
  "A plan covering the repository's changes; LAST replaces its last item."
  (vector (agent-review-test--item "改第二行" 3 (list :file "a.txt" :hunks [0]))
          (agent-review-test--item "改第十八行并加 b" 2 (list :file "a.txt" :hunks [1])
                                   (list :file "b.el" :added_lines [1 5]))
          (or last (agent-review-test--item "b 的后半" 2 (list :file "b.el" :added_lines [6 10])))))

(ert-deftest agent-review-test-build-covers-every-line ()
  (agent-review-test--with-repo repo
    (let* ((snapshot (agent-review-snapshot repo "main" "feature"))
           (review (agent-review-build snapshot "概览" (agent-review-test--plan) "t" "*agent*")))
      (should (equal (plist-get review :stats)
                     '(:files 2 :items 3 :additions 12 :deletions 2)))
      (should (equal (plist-get (nth 1 (plist-get review :items)) :files) '("a.txt" "b.el")))
      (should (string-search "@@ -0,0 +1,5 @@\n+(b 1)\n"
                             (plist-get (nth 1 (plist-get review :items)) :diff)))
      (should (equal (mapcar #'car (plist-get review :sources)) '("a.txt" "b.el")))
      ;; Building the same plan again returns the stored review.
      (should (equal (plist-get (agent-review-build snapshot "概览" (agent-review-test--plan) "t")
                                :id)
                     (plist-get review :id)))
      (should (equal (mapcar (lambda (e) (plist-get e :agent)) (agent-review--index))
                     '("*agent*")))
      ;; Handing the review to another session stores the choice.
      (agent-review--set-agent review "*other*")
      (should (equal (plist-get (agent-review--load (plist-get review :id)) :agent) "*other*"))
      (should (equal (mapcar (lambda (e) (plist-get e :agent)) (agent-review--index))
                     '("*other*"))))))

(ert-deftest agent-review-test-build-rejects-gaps-and-overlaps ()
  (agent-review-test--with-repo repo
    (let ((snapshot (agent-review-snapshot repo "main" "feature")))
      (should (string-match-p
               "5 changed lines missing"
               (cadr (should-error
                      (agent-review-build snapshot "概览"
                                          (seq-take (agent-review-test--plan) 2))))))
      (should (string-match-p
               "1 extra or duplicated"
               (cadr (should-error
                      (agent-review-build
                       snapshot "概览"
                       (agent-review-test--plan
                        (agent-review-test--item "重叠" 2 (list :file "b.el"
                                                                :added_lines [5 10]))))))))
      (should-error (agent-review-build snapshot "" (agent-review-test--plan)))
      (should-error (agent-review-build
                     snapshot "概览"
                     (agent-review-test--plan
                      (agent-review-test--item "两种选法" 2 (list :file "b.el" :whole t
                                                                  :added_lines [6 10]))))))))

(ert-deftest agent-review-test-around-hunk ()
  (let ((source (vconcat (mapcar (lambda (i) (format "l%d" i)) (number-sequence 1 20)))))
    ;; A one-line change at line 2: line 1 before, lines 3-5 after.
    (let ((around (agent-review--around "@@ -2 +2 @@\n-x\n+y\n" source 3 1 most-positive-fixnum)))
      (should (equal (mapcar (lambda (l) (plist-get l :new)) (car around)) '(1)))
      (should (equal (mapcar (lambda (l) (plist-get l :new)) (cdr around)) '(3 4 5)))
      (should (equal (mapcar (lambda (l) (plist-get l :old)) (cdr around)) '(3 4 5))))
    ;; Old lines 5-6 deleted after new line 4: old numbers shift by two after it.
    (let ((around (agent-review--around "@@ -5,2 +4,0 @@\n-a\n-b\n" source 3 1 most-positive-fixnum)))
      (should (equal (mapcar (lambda (l) (plist-get l :new)) (car around)) '(2 3 4)))
      (should (equal (mapcar (lambda (l) (plist-get l :old)) (car around)) '(2 3 4)))
      (should (equal (mapcar (lambda (l) (plist-get l :new)) (cdr around)) '(5 6 7)))
      (should (equal (mapcar (lambda (l) (plist-get l :old)) (cdr around)) '(7 8 9))))
    ;; Context stops at FROM and before LIMIT.
    (let ((around (agent-review--around "@@ -10 +10 @@\n-x\n+y\n" source 3 9 12)))
      (should (equal (mapcar (lambda (l) (plist-get l :new)) (car around)) '(9)))
      (should (equal (mapcar (lambda (l) (plist-get l :new)) (cdr around)) '(11))))))

(defconst agent-review-test--change
  (list (list :item "atomic-1" :file "a.txt" :side 'old :line 2 :kind ?- :code "line 2")
        (list :item "atomic-1" :file "a.txt" :side 'new :line 2 :kind ?+ :code "line two"))
  "The two diff lines of item 1, as selected in the review buffer.")

(ert-deftest agent-review-test-annotate-and-reply ()
  (agent-review-test--with-repo repo
    (let* ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                       "概览" (agent-review-test--plan)))
           (id (plist-get review :id))
           (comment (agent-review-annotate-lines review agent-review-test--change "为什么改")))
      (should (equal (plist-get comment :revision) 1))
      (should (equal (plist-get comment :range) "新 2 · 旧 2"))
      (should (equal (plist-get comment :code) "-line 2\n+line two"))
      (should (equal (plist-get comment :anchor) '("atomic-1" "a.txt" new 2)))
      ;; The message to the agent carries the selection and where it is.
      (let ((message (agent-review--message review comment)))
        (should (string-search "第 1 项「改第二行」" message))
        (should (string-search "a.txt 新 2 · 旧 2" message))
        (should (string-search "```diff\n-line 2\n+line two\n```\n为什么改" message))
        (should (string-search (format "标注 id=%s，revision=1" (plist-get comment :id))
                               message))
        ;; The answer belongs in the review, not in the conversation.
        (should (string-search "请直接调用 review_reply 回答" message)))
      ;; Selecting the same lines again edits the annotation.
      (agent-review-annotate-lines review agent-review-test--change "改成别的")
      (should (string-search "·修改标注" (agent-review--message
                                          review (car (agent-review--comments id)))))
      ;; The answer was written for revision 1, but the user edited it since.
      (should-error (agent-review-reply id (plist-get comment :id) 1 "回答"))
      (agent-review-reply id (plist-get comment :id) 2 "回答")
      (let ((stored (agent-review--comments id)))
        (should (= (length stored) 1))
        (should (equal (plist-get (car stored) :status) "responded"))
        (should (equal (plist-get (car stored) :response) "回答"))))))

(defmacro agent-review-test--with-buffer (review &rest body)
  "Run BODY in a review buffer showing REVIEW, with its sidebar."
  (declare (indent 1))
  `(with-temp-buffer
     (agent-review-mode)
     (setq agent-review--review ,review)
     (agent-review--load-state)
     (let ((inhibit-read-only t)) (agent-review--render))
     (unwind-protect (progn ,@body)
       (agent-review--kill-nav))))

(ert-deftest agent-review-test-render ()
  (agent-review-test--with-repo repo
    (let ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                      "概览" (agent-review-test--plan))))
      (agent-review-annotate-lines review agent-review-test--change "为什么改")
      (agent-review-test--with-buffer review
        (goto-char (point-min))
        (should (search-forward "1. 改第二行   局部修复 " nil t))
        ;; The type tag, and the whole heading bar, have the background of its type.
        (should (memq 'agent-review-type-fix (ensure-list (get-text-property (- (point) 2) 'face))))
        (should (memq 'agent-review-type-fix
                      (ensure-list (get-text-property (line-beginning-position) 'face))))
        (should (memq 'agent-review-type-fix (ensure-list (get-text-property (point) 'face))))
        (should (search-forward "+line two" nil t))
        (should (equal (plist-get (get-text-property (point) 'agent-review-target) :line) 2))
        ;; The annotation is below the last selected line, with its range.
        (forward-line 1)
        (should (looking-at "  ┃ 标注 · 新 2 · 旧 2 · 待回应"))
        (should (search-forward "为什么改" nil t))
        ;; Context after the change, but nothing from the hunk at line 18.
        (should (search-forward " line 5\n" nil t))
        (should-not (search-forward " line 6\n" (save-excursion
                                                   (search-forward "2. 改第十八行并加 b")) t))
        ;; In item 2, b.el's lines 6-10 belong to item 3 and are shown faded.
        ;; They have no old-side number.
        (agent-review-goto "atomic-2")
        (should (re-search-forward "^ +6  (b 6)$" nil t))
        (should (memq 'agent-review-other (ensure-list (get-text-property (1- (point)) 'face))))))))

(ert-deftest agent-review-test-selection ()
  (agent-review-test--with-repo repo
    (let ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                      "概览" (agent-review-test--plan))))
      (agent-review-test--with-buffer review
        (goto-char (point-min))
        (search-forward "-line 2")
        (let ((start (line-beginning-position)))
          (search-forward "+line two")
          ;; A region ending at the start of the next line covers two lines.
          (should (equal (mapcar (lambda (l) (plist-get l :line))
                                 (agent-review--lines-between start (line-beginning-position 2)))
                         '(2 2)))
          (should (equal (mapcar (lambda (l) (plist-get l :kind))
                                 (agent-review--lines-between start (point)))
                         '(?- ?+))))))))

(ert-deftest agent-review-test-view-state ()
  (agent-review-test--with-repo repo
    (let ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                      "概览" (agent-review-test--plan))))
      (agent-review-test--with-buffer review
        ;; Opened for the first time, only the first item is unfolded.
        (should (equal agent-review--folded '("atomic-2" "atomic-3")))
        (should (string-search "已审阅 0/3" (agent-review--header-line)))
        (goto-char (agent-review--find 'agent-review-heading "atomic-1"))
        (agent-review-toggle-reviewed)
        ;; Marking an item reviewed folds it and moves on to the next one
        ;; not reviewed.
        (should (looking-at "○ 2\\. "))
        (should (member "atomic-1" agent-review--folded))
        (save-excursion
          (goto-char (agent-review--find 'agent-review-heading "atomic-1"))
          (should (looking-at "✓ 1\\. ")))
        (should (string-search "已审阅 1/3" (agent-review--header-line)))
        ;; Past the last item it wraps around to the first one left.
        (goto-char (agent-review--find 'agent-review-heading "atomic-3"))
        (agent-review-toggle-reviewed)
        (should (looking-at "○ 2\\. "))
        ;; Unmarking stays on the item and unfolds it.
        (goto-char (agent-review--find 'agent-review-heading "atomic-3"))
        (agent-review-toggle-reviewed)
        (should (looking-at "○ 3\\. "))
        (should-not (member "atomic-3" agent-review--folded))
        ;; Jumping to an item unfolds it.
        (agent-review-goto "atomic-2")
        (should (equal agent-review--folded '("atomic-1")))
        ;; The sidebar lists every item and marks the reviewed one.
        (with-current-buffer (agent-review--nav-buffer)
          (goto-char (point-min))
          (should (search-forward "✓ 1. 改第二行   局部修复 " nil t))
          ;; The entry, its file line included, has the background of its type.
          (forward-line 1)
          (should (looking-at "    a.txt"))
          (should (memq 'agent-review-type-fix (ensure-list (get-text-property (point) 'face))))
          ;; In the sidebar r also moves on to the next item not reviewed,
          ;; and redrawing keeps point on its entry instead of the end.
          (goto-char (agent-review--find 'agent-review-nav "atomic-2"))
          (agent-review-nav-toggle-reviewed)
          (should (equal (get-text-property (point) 'agent-review-nav) "atomic-3"))
          (agent-review--nav-render)
          (should (equal (get-text-property (point) 'agent-review-nav) "atomic-3"))
          (with-current-buffer agent-review-nav--review-buffer
            (agent-review--mark-reviewed "atomic-2"))
          (goto-char (point-min))
          (should (search-forward "3. b 的后半   新功能 " nil t))
          (agent-review-nav-filter "b.el")
          (goto-char (point-min))
          (should-not (search-forward "1. 改第二行" nil t))
          (should (search-forward "2. 改第十八行并加 b" nil t))))
      ;; The state is kept with the review.
      (should (equal (plist-get (agent-review--state (plist-get review :id)) :reviewed)
                     '("atomic-1"))))))

(ert-deftest agent-review-test-file-paths ()
  ;; A rename with edits: the new path at head, the old one at the base.
  (should (equal (agent-review--file-paths
                  "diff --git a/old.el b/new.el\nsimilarity index 90%\nrename from old.el\nrename to new.el\nindex 1..2 100644\n--- a/old.el\n+++ b/new.el\n")
                 '("new.el" . "old.el")))
  ;; Added and deleted files name the path that exists on both sides.
  (should (equal (agent-review--file-paths "diff --git a/x b/x\nnew file mode 100644\n--- /dev/null\n+++ b/x\n")
                 '("x" . "x")))
  (should (equal (agent-review--file-paths "diff --git a/x b/x\ndeleted file mode 100644\n--- a/x\n+++ /dev/null\n")
                 '("x" . "x")))
  ;; A pure rename, and a mode change of a path that contains " b/".
  (should (equal (agent-review--file-paths "diff --git a/p b/q\nsimilarity index 100%\nrename from p\nrename to q\n")
                 '("q" . "p")))
  (should (equal (agent-review--file-paths "diff --git a/dir b/name b/dir b/name\nold mode 100644\nnew mode 100755\n")
                 '("dir b/name" . "dir b/name")))
  ;; Edits that come with a mode change keep the mode lines visible.
  (should (equal (agent-review--extended-header
                  "diff --git a/x b/x\nold mode 100644\nnew mode 100755\nindex 1..2\n--- a/x\n+++ b/x\n")
                 '("old mode 100644" "new mode 100755"))))

(ert-deftest agent-review-test-snapshot-robustness ()
  (agent-review-test--with-repo repo
    ;; A user setting that drops the space of empty context lines.
    (agent-review-test--write (expand-file-name "c.txt" repo) '("one" "" "two" "three"))
    (agent-review-test--git repo "add" ".")
    (agent-review-test--git repo "commit" "-q" "-m" "c")
    (agent-review-test--write (expand-file-name "c.txt" repo) '("one" "" "2" "three"))
    (agent-review-test--git repo "commit" "-q" "-am" "c again")
    (agent-review-test--git repo "config" "diff.suppressBlankEmpty" "true")
    (should (agent-review-snapshot repo "HEAD~1" "HEAD"))
    ;; The same diff on other commits, as after a rebase, is another snapshot.
    (agent-review-test--git repo "checkout" "-q" "-b" "base2" "main")
    (agent-review-test--write (expand-file-name "d.txt" repo) '("d"))
    (agent-review-test--git repo "add" ".")
    (agent-review-test--git repo "commit" "-q" "-m" "d")
    (agent-review-test--git repo "checkout" "-q" "-b" "feature2")
    (agent-review-test--git repo "cherry-pick" "feature~2")
    (let ((one (agent-review-snapshot repo "main" "feature~2"))
          (two (agent-review-snapshot repo "base2" "feature2")))
      (should (equal (plist-get one :full) (plist-get two :full)))
      (should-not (equal (plist-get one :id) (plist-get two :id))))))

(ert-deftest agent-review-test-deleted-annotation-revision ()
  (agent-review-test--with-repo repo
    (let* ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                       "概览" (agent-review-test--plan)))
           (id (plist-get review :id))
           (first (agent-review-annotate-lines review agent-review-test--change "一")))
      (agent-review--delete-comment id first)
      ;; Written again on the same lines, it continues the revisions, so a
      ;; late answer to the deleted one is refused.
      (let ((again (agent-review-annotate-lines review agent-review-test--change "二")))
        (should (equal (plist-get again :id) (plist-get first :id)))
        (should (= (plist-get again :revision) 2))
        (should-error (agent-review-reply id (plist-get first :id) 1 "迟到的回答"))))))

(ert-deftest agent-review-test-hidden-context-and-redraw ()
  (agent-review-test--with-repo repo
    (let ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                      "概览" (agent-review-test--plan))))
      ;; An annotation on a context line the current context doesn't show.
      (agent-review-annotate-lines
       review (list (list :item "atomic-1" :file "a.txt" :side 'new :line 9 :kind ?\s
                          :code "line 9"))
       "远处的一行")
      (agent-review-test--with-buffer review
        (goto-char (point-min))
        (should (search-forward "不在当前上下文里" nil t))
        (should (search-forward "远处的一行" nil t))
        ;; Point stays on its code line when an annotation appears above it.
        (agent-review-goto "atomic-2")
        (search-forward "+line eighteen")
        (let ((key (agent-review--line-key (get-text-property (point) 'agent-review-target))))
          (agent-review-annotate-lines review agent-review-test--change "上面多了一条")
          (agent-review--redraw)
          (should (equal (agent-review--line-key (get-text-property (point) 'agent-review-target))
                         key)))
        ;; Only atomic items can be marked reviewed.
        (should-error (agent-review--mark-reviewed '("full" . "a.txt")))
        (should-error (agent-review--mark-reviewed "full"))))))

(ert-deftest agent-review-test-deferred-items ()
  (agent-review-test--with-repo repo
    (let* ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                       "概览" (agent-review-test--plan)))
           (body (lambda (id)
                   (seq-find (lambda (o) (equal (overlay-get o 'agent-review-body) id))
                             (overlays-in (point-min) (point-max))))))
      (agent-review-test--with-buffer review
        ;; Folded items are drawn when first unfolded, then kept: folding
        ;; again only hides them.
        (goto-char (point-min))
        (should-not (search-forward "+line eighteen" nil t))
        (goto-char (agent-review--find 'agent-review-heading "atomic-2"))
        (agent-review-toggle)
        (should (search-forward "+line eighteen" nil t))
        (should (equal (agent-review--item-at (point)) "atomic-2"))
        (let ((overlay (funcall body "atomic-2"))
              (text (buffer-string)))
          (goto-char (agent-review--find 'agent-review-heading "atomic-2"))
          (agent-review-toggle)
          (should (overlay-get overlay 'invisible))
          (agent-review-toggle)
          (should (eq (funcall body "atomic-2") overlay))
          (should-not (overlay-get overlay 'invisible))
          (should (equal (buffer-string) text)))
        ;; A file of an item not drawn yet can be gone to directly.
        (should-not (funcall body "atomic-3"))
        (agent-review-goto '("atomic-3" . "b.el"))
        (should (looking-at "b\\.el$"))
        (should (funcall body "atomic-3")))
      ;; A folded item with annotations is drawn, so moving between
      ;; annotations finds them.
      (agent-review-annotate-lines review agent-review-test--change "为什么改")
      (agent-review--write (agent-review--path (plist-get review :id) "state.eld")
                           (list :folded '("atomic-1" "atomic-2" "atomic-3")))
      (agent-review-test--with-buffer review
        (should (funcall body "atomic-1"))
        (should-not (funcall body "atomic-2"))
        (goto-char (point-min))
        (agent-review-next-annotation)
        (should (equal (agent-review--item-at (point)) "atomic-1"))
        (should-not (member "atomic-1" agent-review--folded))))))

(ert-deftest agent-review-test-whole-file-highlight ()
  (agent-review-test--with-repo repo
    ;; A change deep inside a docstring: the hunk and its context alone read
    ;; as code, only the whole file says they are documentation.
    (let ((doc (lambda (middle)
                 (list "(defun f ()" "  \"Doc start." "a" "b" "c" middle "d" "e" "f" "end.\""
                       "  nil)"))))
      (agent-review-test--git repo "checkout" "-q" "-b" "doc" "main")
      (agent-review-test--write (expand-file-name "c.el" repo) (funcall doc "old middle"))
      (agent-review-test--git repo "add" ".")
      (agent-review-test--git repo "commit" "-q" "-m" "c")
      (agent-review-test--write (expand-file-name "c.el" repo) (funcall doc "new middle"))
      (agent-review-test--git repo "commit" "-q" "-am" "c again"))
    (let* ((review (agent-review-build (agent-review-snapshot repo "HEAD~1" "HEAD") "概览"
                                       (vector (agent-review-test--item
                                                "改文档" 0 (list :file "c.el" :hunks [0])))))
           (id (plist-get review :id))
           (doc-p (lambda (text)
                    (goto-char (point-min))
                    (search-forward text)
                    (memq 'font-lock-doc-face
                          (ensure-list (get-text-property (1- (point)) 'face))))))
      (should (equal (mapcar #'car (plist-get review :old-sources)) '("c.el")))
      (agent-review-test--with-buffer review
        ;; The removed line comes from the base, the others from head.
        (should (funcall doc-p "-old middle"))
        (should (funcall doc-p "+new middle"))
        (should (funcall doc-p "5  c")))
      ;; A review stored before the base side was kept reads it once.
      (agent-review--write (agent-review--path id "review.eld")
                           (cl-loop for (key value) on review by #'cddr
                                    unless (eq key :old-sources) append (list key value)))
      (let ((old (agent-review--load id)))
        (should-not (plist-member old :old-sources))
        (agent-review-test--with-buffer old
          (should (funcall doc-p "-old middle"))))
      (should (equal (mapcar #'car (plist-get (agent-review--load id) :old-sources))
                     '("c.el"))))))

(provide 'agent-review-test)
;;; agent-review-test.el ends here
