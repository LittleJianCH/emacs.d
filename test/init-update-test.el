;;; init-update-test.el --- Repository update tests -*- lexical-binding: t; -*-

;;; Commentary:
;; All Git operations and applied markers use disposable repositories/state.

;;; Code:
(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'init-update)
(require 'init-lazy)
(require 'agent-ui)

(defvar init-update-test--effect nil)
;; This built-in variable needs a special declaration for fixture bindings.
(with-suppressed-warnings ((lexical features))
  (defvar features))

(defconst init-update-test--revision-steps my/update-steps
  "Real revision-owned steps, before fixtures bind them.")

(defconst init-update-test--updater-source
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/core/init-update.el" emx-test--checkout))
    (buffer-string))
  "Updater source used to exercise the old bootstrap entry point.")

(defun init-update-test--git (dir &rest args)
  "Run Git ARGS in DIR and return trimmed output."
  (let ((default-directory dir))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun init-update-test--write (dir path text)
  "Write TEXT to PATH under DIR."
  (let ((file (expand-file-name path dir)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun init-update-test--commit (dir path text)
  "Commit TEXT at PATH in DIR and return HEAD."
  (init-update-test--write dir path text)
  (init-update-test--git dir "add" "--" path)
  (init-update-test--git dir "commit" "-qm" "fixture change")
  (init-update-test--git dir "rev-parse" "HEAD"))

(defmacro init-update-test--fixture (&rest body)
  "Run BODY with an isolated remote, publisher, clone and update state."
  (declare (indent 0))
  `(let* ((base (file-name-as-directory (make-temp-file "update-test-" t)))
          (remote (expand-file-name "remote.git" base))
          (publisher (expand-file-name "publisher/" base))
          (repo (expand-file-name "clone/" base))
          (process-environment
           (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@example.com"
                     "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@example.com"
                     "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1")
                   process-environment))
          (user-emacs-directory repo)
          (my/var-dir (expand-file-name "state/" base))
          (my/reload-directory (expand-file-name "lisp/" repo))
          (my/reload--times (make-hash-table :test #'equal))
          (my/reload-emx-function nil)
          (my/update--state nil)
          (my/update-last-report nil)
          (my/update-steps nil)
          (load-history (copy-tree load-history)))
     (unwind-protect
         (progn
           (make-directory publisher t)
           (init-update-test--git base "init" "-q" "--bare" "--initial-branch=main" remote)
           (init-update-test--git publisher "init" "-q" "-b" "main")
           (init-update-test--commit publisher "note" "base\n")
           (init-update-test--commit publisher "lisp/core/init-update.el"
                                     ";;; -*- lexical-binding: t; -*-\n")
           (init-update-test--git publisher "remote" "add" "origin" remote)
           (init-update-test--git publisher "push" "-qu" "origin" "main")
           (init-update-test--git base "clone" "-q" remote repo)
           (cl-letf (((symbol-function 'my/reload--changed-p) (lambda (_file) nil)))
             ,@body))
       (when-let* ((process (plist-get my/update--state :process)))
         (when (process-live-p process) (delete-process process)))
       (setq my/update--state nil)
       (delete-directory base t))))

(defun init-update-test--wait ()
  "Wait for the fixture's update and return its final report."
  (let ((deadline (+ (float-time) 15)))
    (while (and my/update--state (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should-not my/update--state)
    (should my/update-last-report)
    my/update-last-report))

(defun init-update-test--marker ()
  "Read the fixture's applied marker."
  (when (file-exists-p (my/var "update/applied"))
    (with-temp-buffer
      (insert-file-contents (my/var "update/applied"))
      (string-trim (buffer-string)))))

(defun init-update-test--mark (revision)
  "Set the fixture's applied marker to REVISION."
  (init-update-test--write my/var-dir "update/applied" revision))

(defconst init-update-test--language-table
  '((lang-update-old
     :files (("\\.uold\\'" . init-update-test-old-mode))
     :commands (init-update-test-old-mode init-update-test-extra-command))
    (lang-update-new :files (("\\.unew\\'" . init-update-test-new-mode))
                     :commands (init-update-test-new-mode))
    (lang-update-loaded :commands (init-update-test-loaded-command))
    (lang-update-disabled :commands (init-update-test-disabled-command)))
  "Fake lazy declarations, including loaded and disabled languages.")

(defmacro init-update-test--languages (&rest body)
  "Run BODY with old/new language revisions and isolated lazy state."
  (declare (indent 0))
  `(init-update-test--fixture
     (let* ((my/update-steps init-update-test--revision-steps)
            (my/languages '(update-old update-eager update-loaded))
            (my/lazy-modules nil)
            (my/lazy--triggers nil)
            (features (cons 'lang-update-loaded (copy-sequence features)))
            (after-load-alist (copy-tree after-load-alist))
            (auto-mode-alist (copy-tree auto-mode-alist))
            before to)
       (unwind-protect
           (cl-letf (((symbol-function 'package-install)
                      (lambda (&rest _) (ert-fail "No package installation")))
                     ((symbol-function 'package-refresh-contents)
                      (lambda (&rest _) (ert-fail "No archive refresh"))))
             (make-directory (expand-file-name "emx/node_modules" repo) t)
             (init-update-test--commit
              repo "init.el"
              (concat "(defvar my/languages '(update-old update-eager update-loaded))\n"
                      "(error \"Never evaluate init.el\")\n"))
             (init-update-test--commit
              repo "lisp/core/init-lazy.el"
              (format (concat ";;; -*- lexical-binding: t; -*-\n"
                              "(defconst my/lazy-modules '%S)\n(provide 'init-lazy)\n")
                      '((lang-update-old :commands (init-update-test-old-mode)))))
             (load (expand-file-name "lisp/core/init-lazy.el" repo) nil t)
             (my/lazy-require 'lang-update-old)
             (setq before (init-update-test--git repo "rev-parse" "HEAD"))
             (init-update-test--mark before)
             (init-update-test--commit
              repo "init.el"
              (concat "(defvar my/languages\n"
                      "  '(update-old update-eager update-loaded update-new))\n"
                      "(error \"Never evaluate init.el\")\n"))
             (init-update-test--commit
              repo "lisp/core/init-lazy.el"
              (format (concat ";;; -*- lexical-binding: t; -*-\n"
                              "(defconst my/lazy-modules '%S)\n(provide 'init-lazy)\n")
                      init-update-test--language-table))
             (dolist (language '(old eager loaded new disabled))
               (init-update-test--commit
                repo (format "lisp/lang/lang-update-%s.el" language)
                "(error \"Never eagerly load a language module\")\n"))
             (setq to (init-update-test--git repo "rev-parse" "HEAD"))
             (ignore to)                ; Some bodies only inspect the report.
             (let ((load-path (cons (expand-file-name "lisp/lang/" repo) load-path)))
               ,@body))
         (dolist (entry (copy-sequence my/lazy--triggers))
           (my/lazy--remove-triggers (car entry)))))))

(ert-deftest init-update-test-language-default-adoption-and-idempotence ()
  (init-update-test--languages
    (let ((reload (symbol-function 'my/reload-config)) (calls 0)
          (my/reload-emx-function
           (lambda () (ert-fail "Language update must not restart daemons"))))
      (cl-letf (((symbol-function 'my/reload-config)
                 (lambda (&optional files)
                   (should-not my/reload-emx-function)
                   (cl-incf calls)
                   (funcall reload files))))
        (with-temp-buffer
          (setq buffer-file-name (expand-file-name "edited.unew" repo))
          (insert "unsaved text")
          (setq-local init-update-test--effect 'buffer-state)
          (my/update-config)
          (let ((report (init-update-test--wait)))
            (should (equal (plist-get report :status) "applied"))
            (should (equal (mapcar (lambda (step) (plist-get step :name))
                                  (append (plist-get report :steps) nil))
                           '("emx-deps" "lisp" "languages" "emx")))
            (should (equal (plist-get report :restart_required)
                           (vector (expand-file-name "init.el" (file-truename repo))))))
          (should (eq major-mode 'fundamental-mode))
          (should (buffer-modified-p))
          (should (eq init-update-test--effect 'buffer-state)))
        ;; The Lisp step loaded the new table once; languages must reuse it.
        (should (= calls 1))
        (should (equal my/languages '(update-old update-eager update-loaded update-new)))
        (should (equal my/lazy-modules init-update-test--language-table))
        (should (equal (sort (mapcar #'car my/lazy--triggers) #'string<)
                       '(lang-update-new lang-update-old)))
        (should (commandp 'init-update-test-extra-command))
        (should (commandp 'init-update-test-new-mode))
        (should-not (fboundp 'init-update-test-loaded-command))
        (should-not (fboundp 'init-update-test-disabled-command))
        (should-not (featurep 'lang-update-new))
        (should-not (featurep 'lang-update-eager))
        (let ((rules (copy-tree auto-mode-alist)))
          ;; Reapply the same range, including the same changed declarations.
          (setq my/update--state
                (list :root (file-truename repo) :from before :to to
                      :marker (my/var "update/applied")))
          (my/update--apply before to)
          (should (equal (plist-get (init-update-test--wait) :status) "applied"))
          (should (equal auto-mode-alist rules))
          (should (= (length my/lazy--triggers) 2))
          (should (= calls 2))
          ;; Updating at the applied revision skips the step altogether.
          (my/update-config)
          (should (equal (plist-get (init-update-test--wait) :status) "applied"))
          (should (= calls 2))
          (should (equal auto-mode-alist rules))
          (should (equal (init-update-test--marker) to)))))))

(ert-deftest init-update-test-language-custom-selection-preserved ()
  (init-update-test--languages
    (let ((properties (copy-sequence (symbol-plist 'my/languages))))
      (unwind-protect
          (progn
            (setq my/languages '(update-old))
            (put 'my/languages 'saved-value '((quote (update-old))))
            (my/update-config)
            (should (equal (plist-get (init-update-test--wait) :status) "applied"))
            (should (equal my/languages '(update-old)))
            (should (equal (get 'my/languages 'saved-value) '((quote (update-old)))))
            (should (commandp 'init-update-test-extra-command))
            (should-not (fboundp 'init-update-test-new-mode))
            (should-not (assoc "\\.unew\\'" auto-mode-alist)))
        (setplist 'my/languages properties)))))

(ert-deftest init-update-test-language-bootstrap-owns-new-step ()
  (init-update-test--languages
    ;; The running bootstrap has no language step.  Reload the new updater
    ;; through its unchanged two-argument apply entry point.
    (setq my/update-steps nil)
    (init-update-test--commit repo "lisp/core/init-update.el"
                              init-update-test--updater-source)
    (my/update-config)
    (should (equal (plist-get (init-update-test--wait) :status) "applied"))
    (should (compiled-function-p (symbol-function 'my/update--language-default)))
    (should (memq 'update-new my/languages))
    (should (commandp 'init-update-test-new-mode))))

(ert-deftest init-update-test-language-helper-compiles-table-only-as-needed ()
  (dolist (unloaded '(nil t))
    (init-update-test--languages
      (when unloaded (setq features (delq 'init-lazy features)))
      (setq my/update--state (list :root (file-truename repo) :from before :to to))
      (let ((reload (symbol-function 'my/reload-config))
            (dirty (not unloaded)) (calls 0)
            (my/reload-emx-function (lambda () (ert-fail "Daemon called"))))
        (cl-letf (((symbol-function 'my/reload--changed-p) (lambda (_file) dirty))
                  ((symbol-function 'my/reload-config)
                   (lambda (&optional files)
                     (should-not my/reload-emx-function)
                     (cl-incf calls)
                     (prog1 (funcall reload files) (setq dirty nil)))))
          (let ((report (plist-get (my/update--languages) :reload)))
            (should (= (length report) 1))
            (should (eq (plist-get (car report) :status) 'reloaded)))
          (should (featurep 'init-lazy))
          (should (equal my/lazy-modules init-update-test--language-table))
          (should (memq 'update-new my/languages))
          (should (commandp 'init-update-test-new-mode))
          (should-not (plist-get (my/update--languages) :reload))
          (should (= calls 1))
          (should (= (length my/lazy--triggers) 2))))
      (setq my/update--state nil))))

(ert-deftest init-update-test-language-table-compile-failure ()
  (init-update-test--languages
    ;; No loaded table in this repo: the languages step must compile it itself.
    (setq features (delq 'init-lazy features))
    (setq load-history
          (seq-remove (lambda (entry)
                        (and (stringp (car entry))
                             (equal (file-truename (car entry))
                                    (file-truename
                                     (expand-file-name "lisp/core/init-lazy.el" repo)))))
                      load-history))
    (init-update-test--commit repo "lisp/core/init-lazy.el" "(defun broken (")
    (my/update-config)
    (let* ((report (init-update-test--wait))
           (step (aref (plist-get report :steps) 2)))
      (should (equal (plist-get report :status) "failed"))
      (should (equal (plist-get step :name) "languages"))
      (should (equal (plist-get step :status) "failed"))
      (should (seq-some (lambda (entry) (eq (plist-get entry :status) 'failed))
                        (plist-get report :reload))))
    (should (equal my/languages '(update-old update-eager update-loaded)))
    (should-not (fboundp 'init-update-test-new-mode))
    (should (equal (init-update-test--marker) before))))

(ert-deftest init-update-test-language-declaration-is-only-data ()
  (dolist (source '("(defvar my/languages (progn (error \"Must not evaluate\") '(x)))"
                    "(defvar my/languages '(x . y))"
                    "(defvar my/languages '(x \"not a symbol\"))"
                    "(defvar my/languages '#1=(x . #1#))"
                    "(defvar my/languages '(x)) (defvar my/languages '(y))"
                    "(defvar my/apps '(x))"
                    "(defvar my/languages)"
                    "(defvar my/languages '(x)"))
    (init-update-test--fixture
      (let ((revision (init-update-test--commit repo "init.el" source)))
        (setq my/update--state (list :root repo))
        (should-error (my/update--language-default revision))
        (setq my/update--state nil)))))

(ert-deftest init-update-test-language-nonliteral-failure-keeps-marker ()
  (init-update-test--languages
    (init-update-test--commit
     repo "init.el" "(defvar my/languages (error \"Must never evaluate\"))\n")
    (my/update-config)
    (let ((report (init-update-test--wait)))
      (should (equal (plist-get report :status) "failed"))
      (should (equal (plist-get (aref (plist-get report :steps) 2) :status) "failed"))
      (should (string-match-p "Nonliteral" (plist-get report :error))))
    (should (equal my/languages '(update-old update-eager update-loaded)))
    (should (equal (init-update-test--marker) before))))

(ert-deftest init-update-test-fast-forward ()
  (init-update-test--fixture
    (let* ((before (init-update-test--git repo "rev-parse" "HEAD"))
           (to (init-update-test--commit publisher "note" "remote\n")))
      (init-update-test--git publisher "push" "-q")
      (my/update-config)
      (let ((report (init-update-test--wait)))
        (should (equal (plist-get report :status) "applied"))
        (should (equal (plist-get report :from) before))
        (should (equal (plist-get report :to) to))
        (should (equal (init-update-test--marker) to))))))

(ert-deftest init-update-test-step-failure-keeps-marker ()
  (init-update-test--fixture
    (let ((before (init-update-test--git repo "rev-parse" "HEAD")))
      (init-update-test--mark before)
      (init-update-test--commit publisher "note" "remote\n")
      (init-update-test--git publisher "push" "-q")
      (let ((my/update-steps
             '((:name "broken" :when always :run ("sh" "-c" "exit 3")))))
        (my/update-config)
        (should (equal (plist-get (init-update-test--wait) :status) "failed"))
        (should (equal (plist-get (aref (plist-get my/update-last-report :steps) 0)
                                  :status) "failed"))
        (should (equal (init-update-test--marker) before))))))

(ert-deftest init-update-test-divergence-refuses ()
  (init-update-test--fixture
    (progn
      (init-update-test--commit repo "local" "local")
      (init-update-test--commit publisher "remote" "remote")
      (init-update-test--git publisher "push" "-q")
      (my/update-config)
      (should (equal (plist-get (init-update-test--wait) :status) "failed"))
      (should (string-match-p "分叉" (plist-get my/update-last-report :error)))
      (should-not (init-update-test--marker)))))

(ert-deftest init-update-test-conflicting-dirty-refuses ()
  (init-update-test--fixture
    ;; A user Git setting must not silently repair the dirty checkout.
    (init-update-test--git repo "config" "merge.autoStash" "true")
    (init-update-test--write repo "note" "dirty\n")
    (init-update-test--commit publisher "note" "remote\n")
    (init-update-test--git publisher "push" "-q")
    (my/update-config)
    (should (equal (plist-get (init-update-test--wait) :status) "failed"))
    (should-not (init-update-test--marker))
    (should (equal (with-temp-buffer
                     (insert-file-contents (expand-file-name "note" repo))
                     (buffer-string)) "dirty\n"))))

(ert-deftest init-update-test-path-selection-and-ahead-only ()
  (init-update-test--fixture
    (let ((ran nil)
          (before (init-update-test--git repo "rev-parse" "HEAD")))
      (init-update-test--mark before)
      (let ((to (init-update-test--commit repo "local" "local"))
            (my/update-steps
             (list (list :name "match" :when (lambda (paths) (member "local" paths))
                         :run (lambda () (push 'match ran)))
                   (list :name "skip" :when (lambda (paths) (member "other" paths))
                         :run (lambda () (push 'skip ran))))))
        (my/update-config)
        (should (equal (plist-get (init-update-test--wait) :status) "applied"))
        (should (equal ran '(match)))
        (should (equal (init-update-test--marker) to))
        (should (equal (mapcar (lambda (step) (plist-get step :status))
                              (append (plist-get my/update-last-report :steps) nil))
                       '("applied" "skipped")))))))

(ert-deftest init-update-test-bootstrap-uses-new-apply ()
  (init-update-test--fixture
    (let ((old-apply (symbol-function 'my/update--apply))
          (init-update-test--effect nil))
      (unwind-protect
          (progn
            (init-update-test--commit
             publisher "lisp/core/init-update.el"
             (concat ";;; -*- lexical-binding: t; -*-\n"
                     "(defvar init-update-test--effect)\n"
                     "(defun my/update--apply (_from _to)\n"
                     "  (setq init-update-test--effect 'new-revision)\n"
                     "  (my/update--put :remaining nil)\n"
                     "  (my/update--next-step))\n"))
            (init-update-test--git publisher "push" "-q")
            (my/update-config)
            (should (equal (plist-get (init-update-test--wait) :status) "applied"))
            (should (eq init-update-test--effect 'new-revision))
            (should (compiled-function-p (symbol-function 'my/update--apply)))
            (should (init-update-test--marker)))
        (fset 'my/update--apply old-apply)))))

(ert-deftest init-update-test-bootstrap-reloads-reloader ()
  "The new updater runs on the new reloader, not the one loaded before."
  (init-update-test--fixture
    (let ((old-apply (symbol-function 'my/update--apply))
          (init-update-test--effect nil))
      (unwind-protect
          (progn
            (init-update-test--commit
             publisher "lisp/core/init-reload.el"
             (concat ";;; -*- lexical-binding: t; -*-\n"
                     "(defun init-update-test--new-reload-api () 'new-reloader)\n"))
            (init-update-test--commit
             publisher "lisp/core/init-update.el"
             (concat ";;; -*- lexical-binding: t; -*-\n"
                     "(defvar init-update-test--effect)\n"
                     "(declare-function init-update-test--new-reload-api nil)\n"
                     "(defun my/update--apply (_from _to)\n"
                     "  (setq init-update-test--effect\n"
                     "        (init-update-test--new-reload-api))\n"
                     "  (my/update--put :remaining nil)\n"
                     "  (my/update--next-step))\n"))
            (init-update-test--git publisher "push" "-q")
            (my/update-config)
            (should (equal (plist-get (init-update-test--wait) :status) "applied"))
            (should (eq init-update-test--effect 'new-reloader)))
        (fset 'my/update--apply old-apply)
        (fmakunbound 'init-update-test--new-reload-api)))))

(ert-deftest init-update-test-bootstrap-compile-failure ()
  (init-update-test--fixture
    (init-update-test--commit publisher "lisp/core/init-update.el" "(defun broken (")
    (init-update-test--git publisher "push" "-q")
    (my/update-config)
    (should (equal (plist-get (init-update-test--wait) :status) "failed"))
    (should-not (init-update-test--marker))))

(ert-deftest init-update-test-refuses-detached-or-no-upstream ()
  (dolist (mode '(detached no-upstream))
    (init-update-test--fixture
      (if (eq mode 'detached)
          (init-update-test--git repo "checkout" "-q" "--detach")
        (init-update-test--git repo "branch" "--unset-upstream"))
      (my/update-config)
      (should (equal (plist-get (init-update-test--wait) :status) "failed"))
      (should-not (init-update-test--marker)))))

(ert-deftest init-update-test-prevents-concurrent-runs ()
  (init-update-test--fixture
    (my/update-config)
    (should-error (my/update-config) :type 'user-error)
    (should (equal (plist-get (init-update-test--wait) :status) "applied"))))

(ert-deftest init-update-test-lisp-only-loaded-and-no-emx ()
  (init-update-test--fixture
    (let* ((loaded (expand-file-name "lisp/loaded.el" repo))
           (unloaded (expand-file-name "lisp/unloaded.el" repo))
           (my/reload-emx-function (lambda () (ert-fail "Daemon called by Lisp step")))
           seen)
      (setq my/update--state
            (list :root repo :paths '("lisp/loaded.el" "lisp/unloaded.el" "init.el")))
      (cl-letf (((symbol-function 'my/reload--loaded) (lambda () (list (list loaded))))
                ((symbol-function 'my/reload-config)
                 (lambda (files)
                   (should-not my/reload-emx-function)
                   (setq seen files)
                   (list (list :file loaded :status 'reloaded)))))
        (let ((report (plist-get (my/update--lisp) :reload)))
          (should (equal seen (list loaded)))
          (should-not (member unloaded seen))
          (should (eq (plist-get (cadr report) :status) 'restart_required))))
      (setq my/update--state nil))))

(ert-deftest init-update-test-reload-failure-and-restart-report ()
  (dolist (status '(failed restart_required))
    (init-update-test--fixture
      (let ((my/update-steps
             (list (list :name "lisp" :when #'always
                         :run (lambda () (list :reload
                                              (list (list :file "test.el" :status status))))))))
        (my/update-config)
        (let ((report (init-update-test--wait)))
          (if (eq status 'failed)
              (progn (should (equal (plist-get report :status) "failed"))
                     (should-not (init-update-test--marker)))
            (should (equal (plist-get report :restart_required) ["test.el"]))
            (should (init-update-test--marker))))))))

(ert-deftest init-update-test-default-step-predicates ()
  (init-update-test--fixture
    (setq my/update--state (list :root repo))
    (should (my/update--deps-p nil))
    (make-directory (expand-file-name "emx/node_modules" repo) t)
    (should-not (my/update--deps-p '("emx/source.ts")))
    (should (my/update--deps-p '("emx/package.json")))
    (should (my/update--deps-p '("emx/package-lock.json")))
    (should (my/update--emx-p '("emx/source.ts")))
    (should (my/update--emx-p '("bin/emx")))
    (should (my/update--emx-p '("lisp/agent/backend/pi/extension.js")))
    (should (my/update--emx-p '("lisp/agent/backend/dsh/plugin.mjs")))
    (should-not (my/update--emx-p '("doc/emx.md")))
    (setq my/update--state nil)))

(ert-deftest init-update-test-agent-deferred ()
  (let (callback)
    (cl-letf (((symbol-function 'my/update-config) (lambda (done) (setq callback done))))
      (let* ((response (agent-ui-call "update" nil nil))
             (id (plist-get response :pending)))
        (should id)
        (should (plist-get (agent-ui--poll id nil) :agent-ui-pending))
        (funcall callback '(:status "applied" :restart_required ["init.el"]
                            :reload [(:file "init.el" :status restart_required)]))
        (let ((report (agent-ui--poll id nil)))
          (should (equal (plist-get report :status) "applied"))
          (should (stringp (json-serialize report))))))))

(ert-deftest init-update-test-new-revision-owns-steps ()
  (init-update-test--fixture
    (let ((init-update-test--effect nil))
      (init-update-test--commit
       publisher "lisp/core/init-update.el"
       (concat ";;; -*- lexical-binding: t; -*-\n"
               "(defvar init-update-test--effect)\n"
               "(defconst my/update-steps\n"
               "  (list (list :name \"new-step\" :when #'always\n"
               "              :run (lambda () (setq init-update-test--effect 'new-step)))))\n"))
      (init-update-test--git publisher "push" "-q")
      (my/update-config)
      (should (equal (plist-get (init-update-test--wait) :status) "applied"))
      (should (eq init-update-test--effect 'new-step))
      (should (equal (plist-get (aref (plist-get my/update-last-report :steps) 0)
                                :name) "new-step")))))

(ert-deftest init-update-test-interactive-restart-only ()
  (dolist (interactivep '(nil t))
    (init-update-test--fixture
      (let ((prompted nil) (restarted nil)
            (my/update-steps
             (list (list :name "startup" :when #'always
                         :run (lambda ()
                                '(:reload ((:file "init.el" :status restart_required))))))))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (_prompt) (setq prompted t)))
                  ((symbol-function 'restart-emacs) (lambda (&rest _) (setq restarted t))))
          (if interactivep (call-interactively #'my/update-config) (my/update-config))
          (init-update-test--wait)
          (should (eq prompted interactivep))
          (should (eq restarted interactivep)))))))

(ert-deftest init-update-test-emx-once-and-failure ()
  (init-update-test--fixture
    (let ((calls 0))
      (init-update-test--commit publisher "emx/source.ts" "// fixture")
      (init-update-test--git publisher "push" "-q")
      (let ((my/update-steps
             (list (list :name "emx" :when #'my/update--emx-p :run #'my/update--emx)))
            (my/reload-emx-function
             (lambda () (cl-incf calls) '((:place "local" :status "failed" :error "fixture")))))
        (my/update-config)
        (should (equal (plist-get (init-update-test--wait) :status) "failed"))
        (should (= calls 1))
        (should-not (init-update-test--marker))))))

(provide 'init-update-test)
;;; init-update-test.el ends here
