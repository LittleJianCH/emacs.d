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

(ert-deftest agent-review-test-annotate-and-reply ()
  (agent-review-test--with-repo repo
    (let* ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                       "概览" (agent-review-test--plan)))
           (id (plist-get review :id))
           (target (list :item "atomic-1" :file "a.txt" :side 'new :line 2 :code "line two"))
           (comment (agent-review-annotate-line review target "为什么改")))
      (should (equal (plist-get comment :revision) 1))
      (should (equal (plist-get comment :context) "-line 2\n+line two"))
      (agent-review-annotate-line review target "改成别的")
      ;; The answer was written for revision 1, but the user edited it since.
      (should-error (agent-review-reply id (plist-get comment :id) 1 "回答"))
      (agent-review-reply id (plist-get comment :id) 2 "回答")
      (let ((stored (agent-review--comments id)))
        (should (= (length stored) 1))
        (should (equal (plist-get (car stored) :status) "responded"))
        (should (equal (plist-get (car stored) :response) "回答")))
      ;; A context line of the item takes its context from the file.
      (let ((context (agent-review-annotate-line
                      review (list :item "atomic-1" :file "a.txt" :side 'new :line 5
                                   :code "line 5")
                      "上下文")))
        (should (string-search " line 5" (plist-get context :context)))))))

(ert-deftest agent-review-test-render ()
  (agent-review-test--with-repo repo
    (let ((review (agent-review-build (agent-review-snapshot repo "main" "feature")
                                      "概览" (agent-review-test--plan))))
      (agent-review-annotate-line review (list :item "atomic-1" :file "a.txt" :side 'new
                                               :line 2 :code "line two")
                                  "为什么改")
      (with-temp-buffer
        (agent-review-mode)
        (setq agent-review--review review)
        (let ((inhibit-read-only t)) (agent-review--render))
        (goto-char (point-min))
        (should (search-forward "1. [局部修复] 改第二行" nil t))
        (should (search-forward "+line two" nil t))
        (should (equal (plist-get (get-text-property (point) 'agent-review-target) :line) 2))
        (should (search-forward "为什么改" nil t))
        ;; Context after the change, but nothing from the hunk at line 18.
        (should (search-forward " line 5\n" nil t))
        (should-not (search-forward " line 6\n" (save-excursion
                                                   (search-forward "2. [新功能]")) t))
        ;; In item 2, b.el's lines 6-10 belong to item 3 and are shown faded.
        ;; They have no old-side number.
        (should (re-search-forward "^ +6  (b 6)$" nil t))
        (should (memq 'agent-review-other (ensure-list (get-text-property (1- (point)) 'face))))))))

(provide 'agent-review-test)
;;; agent-review-test.el ends here
