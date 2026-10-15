;;; init-reload-test.el --- Tests for init-reload -*- lexical-binding: t; -*-

;;; Commentary:

;; Reloads small throwaway modules written to a temporary directory.
;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-reload-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'init-reload)
(require 'agent-ui)

;; Defined by the modules the tests write.
(defvar init-reload-test-map)
(defvar init-reload-test-option)
(defvar init-reload-test-set-option)
(defvar init-reload-test-state)

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
  "Write FORMS to FILE, dated after anything loaded so far."
  (sleep-for 0.01)
  (with-temp-file file
    (insert ";;; -*- lexical-binding: t; -*-\n")
    (dolist (form forms) (prin1 form (current-buffer)) (insert "\n"))))

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

(provide 'init-reload-test)
;;; init-reload-test.el ends here
