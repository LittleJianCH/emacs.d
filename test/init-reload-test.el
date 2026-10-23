;;; init-reload-test.el --- Tests for init-reload -*- lexical-binding: t; -*-

;;; Commentary:

;; Reloads small throwaway modules written to a temporary directory.
;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-reload-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'init-reload)
(require 'agent-ui)

;; Defined by the modules the tests write.
(defvar init-reload-test-map)
(defvar init-reload-test-option)
(defvar init-reload-test-set-option)
(defvar init-reload-test-state)
(defvar init-reload-test-compiled-map)
(defvar init-reload-test-file)

(defmacro init-reload-test--with-module (var &rest body)
  "Run BODY with VAR bound to a module file in a fresh `my/reload-directory'."
  (declare (indent 1))
  `(let* ((dir (file-name-as-directory (make-temp-file "init-reload-test-" t)))
          (my/reload-directory dir)
          (my/reload--times (make-hash-table :test #'equal))
          (my/reload--keymaps (make-hash-table :test #'eq))
          (,var (file-truename (expand-file-name "init-reload-test-mod.el" dir))))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun init-reload-test--write (file &rest forms)
  "Write FORMS to FILE, dated after anything loaded so far.
A string in FORMS is inserted as is."
  (sleep-for 0.01)
  (with-temp-file file
    (insert ";;; -*- lexical-binding: t; -*-\n")
    (dolist (form forms)
      (if (stringp form) (insert form) (prin1 form (current-buffer)))
      (insert "\n"))))

(ert-deftest init-reload-test-applies-definitions ()
  "Keymaps merge, untouched options and faces update, state stays."
  (init-reload-test--with-module file
    (init-reload-test--write
     file
     '(defvar-keymap init-reload-test-map "C-c a" #'ignore "C-c b" #'ignore)
     '(defcustom init-reload-test-option 1 "Option." :type 'integer :group 'emacs)
     '(defcustom init-reload-test-set-option 1 "Option." :type 'integer :group 'emacs)
     '(defface init-reload-test-face '((t :weight bold)) "Face." :group 'emacs)
     '(defvar init-reload-test-state 'initial)
     '(provide 'init-reload-test-mod))
    (load file nil t t)
    ;; A plain `load' counts too: nothing changed since.
    (should-not (my/reload-config))
    ;; Other code adds a binding and changes state.
    (keymap-set init-reload-test-map "C-c o" #'forward-char)
    (setq init-reload-test-state 'running
          init-reload-test-set-option 5)
    (init-reload-test--write
     file
     '(defvar-keymap init-reload-test-map "C-c a" #'backward-char "C-c c" #'ignore)
     '(defcustom init-reload-test-option 2 "Option." :type 'integer :group 'emacs)
     '(defcustom init-reload-test-set-option 2 "Option." :type 'integer :group 'emacs)
     '(defface init-reload-test-face '((t :slant italic)) "Face." :group 'emacs)
     '(defvar init-reload-test-state 'changed-initial)
     '(provide 'init-reload-test-mod))
    (let ((report (my/reload-config)))
      (should (equal (mapcar (lambda (entry) (plist-get entry :file)) report)
                     (list file)))
      (should (eq (plist-get (car report) :status) 'reloaded))
      (should (equal (plist-get (car report) :keymaps) '(init-reload-test-map)))
      (should (equal (plist-get (car report) :options) '(init-reload-test-option)))
      (should (equal (plist-get (car report) :faces) '(init-reload-test-face))))
    (should (eq (keymap-lookup init-reload-test-map "C-c a") #'backward-char))
    (should (eq (keymap-lookup init-reload-test-map "C-c c") #'ignore))
    (should (eq (keymap-lookup init-reload-test-map "C-c o") #'forward-char))
    ;; Without a previous version to compare with, a dropped binding stays.
    (should (eq (keymap-lookup init-reload-test-map "C-c b") #'ignore))
    (should (= init-reload-test-option 2))
    (should (= init-reload-test-set-option 5))
    (should (equal (get 'init-reload-test-face 'face-defface-spec)
                   '((t :slant italic))))
    (should (eq init-reload-test-state 'running))
    ;; Unchanged files are not reloaded again.
    (should-not (my/reload-config))
    ;; Now the previous version is known: dropping C-c c removes it.
    (init-reload-test--write
     file
     '(defvar-keymap init-reload-test-map "C-c a" #'backward-char)
     '(provide 'init-reload-test-mod))
    (should (equal (plist-get (car (my/reload-config)) :keymaps)
                   '(init-reload-test-map)))
    (should-not (keymap-lookup init-reload-test-map "C-c c"))
    (should (eq (keymap-lookup init-reload-test-map "C-c o") #'forward-char))))

(ert-deftest init-reload-test-compiles ()
  "Reloaded functions run compiled and still look like FILE's definitions."
  (init-reload-test--with-module file
    (init-reload-test--write
     file
     '(defun init-reload-test-fn () "Old." 1)
     '(defvar-keymap init-reload-test-compiled-map
        "C-c l" (lambda () (interactive) 'old))
     '(provide 'init-reload-test-mod))
    (load file nil t t)
    ;; A plain load of the source leaves the function interpreted.
    (should-not (compiled-function-p (symbol-function 'init-reload-test-fn)))
    (init-reload-test--write
     file
     '(defun init-reload-test-fn () "New, with 中文." 2)
     '(defconst init-reload-test-file load-file-name)
     '(defvar-keymap init-reload-test-compiled-map
        "C-c l" (let ((value 'new)) (lambda () (interactive) value)))
     '(provide 'init-reload-test-mod))
    ;; From a buffer without lexical binding, as emacsclient may be.
    (let ((report (with-temp-buffer
                    (setq-local lexical-binding nil)
                    (my/reload-config))))
      (should (equal (mapcar (lambda (entry) (plist-get entry :file)) report)
                     (list file)))
      (should (eq (plist-get (car report) :status) 'reloaded))
      (should (equal (plist-get (car report) :keymaps)
                     '(init-reload-test-compiled-map)))
      (should-not (plist-get (car report) :warnings)))
    (should (compiled-function-p (symbol-function 'init-reload-test-fn)))
    (should (= (init-reload-test-fn) 2))
    ;; A command defined inline in a merged keymap is compiled too.
    (let ((command (keymap-lookup init-reload-test-compiled-map "C-c l")))
      (should (compiled-function-p command))
      (should (eq (funcall command) 'new)))
    ;; The temporary compiled file is gone; the docstring was kept in the code.
    (should (equal (documentation 'init-reload-test-fn) "New, with 中文."))
    (should (equal (symbol-file 'init-reload-test-fn 'defun) file))
    (should (equal init-reload-test-file file))
    (should (member '(provide . init-reload-test-mod) (cdr (assoc file load-history))))
    ;; Its load was noted: nothing to reload any more.
    (should-not (my/reload-config))))

(ert-deftest init-reload-test-compiles-newly-loaded-dependencies ()
  "Files pulled in during reload, including transitive dependencies, compile."
  (init-reload-test--with-module file
    (let* ((dir (file-name-directory file))
           (child (expand-file-name "init-reload-test-child.el" dir))
           (grandchild (expand-file-name "init-reload-test-grandchild.el" dir))
           (load-path (cons dir load-path)))
      (init-reload-test--write
       file '(provide 'init-reload-test-mod))
      (load file nil t t)
      (init-reload-test--write
       grandchild
       '(defun init-reload-test-grandchild-fn () 'grandchild)
       '(provide 'init-reload-test-grandchild))
      (init-reload-test--write
       child
       '(require 'init-reload-test-grandchild)
       '(defun init-reload-test-child-fn () 'child)
       '(provide 'init-reload-test-child))
      ;; The changed parent introduces a require.  Compiling it source-loads
      ;; CHILD, whose own require source-loads GRANDCHILD.
      (init-reload-test--write
       file
       '(require 'init-reload-test-child)
       '(provide 'init-reload-test-mod))
      (let* ((report (my/reload-config (list file)))
             (reported (mapcar (lambda (entry) (plist-get entry :file)) report)))
        (should (equal (length reported) 3))
        (should (member file reported))
        (should (member child reported))
        (should (member grandchild reported))
        (dolist (entry report)
          (should (eq (plist-get entry :status) 'reloaded)))
        (should (compiled-function-p
                 (symbol-function 'init-reload-test-child-fn)))
        (should (compiled-function-p
                 (symbol-function 'init-reload-test-grandchild-fn)))
        (should (eq (init-reload-test-child-fn) 'child))
        (should (eq (init-reload-test-grandchild-fn) 'grandchild))))))

(ert-deftest init-reload-test-compile-problems ()
  "Compiler warnings are reported; a file that does not compile loads nothing."
  (init-reload-test--with-module file
    (init-reload-test--write
     file '(defun init-reload-test-fn () 1) '(provide 'init-reload-test-mod))
    (load file nil t t)
    (init-reload-test--write
     file
     '(defun init-reload-test-fn () init-reload-test-free-variable)
     '(provide 'init-reload-test-mod))
    (let ((entry (car (my/reload-config))))
      (should (eq (plist-get entry :status) 'reloaded))
      (should (= (length (plist-get entry :warnings)) 1))
      (should (string-match-p "\\`line 2: .*free variable"
                              (car (plist-get entry :warnings)))))
    (let ((compiled (symbol-function 'init-reload-test-fn)))
      (init-reload-test--write
       file
       '(defun init-reload-test-fn () 3)
       '(defun init-reload-test-unloaded ())
       "(defun init-reload-test-broken (")
      (let ((entry (car (my/reload-config))))
        (should (eq (plist-get entry :status) 'failed))
        (should (string-match-p "End of file" (plist-get entry :error))))
      (should-not (fboundp 'init-reload-test-unloaded))
      (should (eq (symbol-function 'init-reload-test-fn) compiled)))))

(ert-deftest init-reload-test-struct-layout ()
  "A changed struct layout is not loaded; appended slots load with a warning."
  (init-reload-test--with-module file
    (init-reload-test--write
     file '(cl-defstruct init-reload-test-struct a b) '(provide 'init-reload-test-mod))
    (load file nil t t)
    (init-reload-test--write
     file '(cl-defstruct init-reload-test-struct b a)
     '(defun init-reload-test-new-function ())
     '(provide 'init-reload-test-mod))
    (let ((entry (car (my/reload-config))))
      (should (eq (plist-get entry :status) 'restart_required))
      (should (string-match-p "init-reload-test-struct" (plist-get entry :error))))
    (should-not (fboundp 'init-reload-test-new-function))
    ;; Not even compiled: the compiler would have redefined the struct.
    (should (equal (mapcar #'car (cl-struct-slot-info 'init-reload-test-struct))
                   '(cl-tag-slot a b)))
    (init-reload-test--write
     file '(cl-defstruct init-reload-test-struct a b c)
     '(provide 'init-reload-test-mod))
    (let ((entry (car (my/reload-config))))
      (should (eq (plist-get entry :status) 'reloaded))
      (should (plist-get entry :warnings)))))

(ert-deftest init-reload-test-order ()
  "Files load after the files whose features they require."
  (let ((loaded '(("/c.el" (require . a) (provide . c))
                  ("/a.el" (provide . a))
                  ("/b.el" (require . c) (require . a) (provide . b)))))
    (should (equal (my/reload--order '("/b.el" "/c.el" "/a.el") loaded)
                   '("/a.el" "/c.el" "/b.el")))
    ;; Requirements outside the set do not pull files in.
    (should (equal (my/reload--order '("/b.el" "/c.el") loaded)
                   '("/c.el" "/b.el")))))

(ert-deftest init-reload-test-method ()
  "The reload method reports JSON-ready entries and tells the agent what next."
  (init-reload-test--with-module file
    (init-reload-test--write file '(provide 'init-reload-test-mod))
    (load file nil t t)
    (init-reload-test--write file '(provide 'init-reload-test-mod))
    (let ((result (agent-ui--method-reload nil)))
      (should (equal (plist-get result :files)
                     (vector (list :file file :status "reloaded"))))
      (should (eq (plist-get result :next_step) :null))
      (should (json-serialize result)))
    (should (string-match-p "Nothing to reload"
                            (plist-get (agent-ui--method-reload nil) :next_step)))
    (init-reload-test--write file '(error "Boom"))
    (let ((result (agent-ui--method-reload nil)))
      (should (equal (plist-get result :files)
                     (vector (list :file file :status "failed" :error "Boom"))))
      (should (string-prefix-p "Fix" (plist-get result :next_step))))))

(ert-deftest init-reload-test-emx-report ()
  "All entry points share the daemon report without treating it as a file."
  (let ((my/reload-emx-function
         (lambda () '((:place "local" :status "restart_scheduled"
                       :waiting [(:session "s" :reason "approval or question pending")])))))
    (cl-letf (((symbol-function 'my/reload--loaded) (lambda () nil))
              ((symbol-function 'my/reload--changed-p) (lambda (_) nil)))
      (let* ((report (my/reload-config))
             (emx (plist-get (car report) :emx))
             (result (agent-ui--method-reload nil)))
        (should (equal (plist-get result :emx) emx))
        (should (equal (plist-get result :files) []))
        (should (string-match-p "空闲后重启" (my/reload--summary report)))
        (should (string-match-p "approval" (plist-get (aref (plist-get (aref emx 0) :waiting) 0) :reason)))))))

(provide 'init-reload-test)
;;; init-reload-test.el ends here
