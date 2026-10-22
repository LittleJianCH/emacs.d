;;; lang-c-test.el --- C/C++ integration tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Run after init.el.  All toolchains and grammars are mocked; keep HOME
;; unchanged and use test-helper's isolated daemon state.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory
                            (or load-file-name buffer-file-name
                                (bound-and-true-p byte-compile-current-file)))))
(require 'ert)
(require 'cl-lib)
(require 'eglot)
(require 'init-lazy)
(require 'lang-c)
(require 'c-ts-mode)

(declare-function my/c-evil-keys "lang-c")
(declare-function evil-local-mode "evil-core")
(declare-function evil-change-state "evil-core")
(declare-function evil-insert-state "evil-states")
(declare-function envrc--apply "envrc")
(defvar envrc-mode-hook)
(defvar envrc-global-mode)

(defconst lang-c-test--rules
  '(("\\.c\\'" . my/c-mode)
    ("\\.\\(?:cc\\|cpp\\|cxx\\|c\\+\\+\\|C\\|hh\\|hpp\\|hxx\\|h\\+\\+\\|H\\|ipp\\|inl\\|tpp\\|ixx\\|cppm\\)\\'"
     . my/c++-mode)
    ("\\.h\\'" . my/c-or-c++-mode)))

(defmacro lang-c-test--without-tools (&rest body)
  "Run BODY without real language servers or grammars."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil))
             ((symbol-function 'treesit-ready-p) (lambda (&rest _) nil))
             ((symbol-function 'treesit-install-language-grammar)
              (lambda (&rest _) (ert-fail "Must not install grammars")))
             ((symbol-function 'eglot-ensure)
              (lambda () (ert-fail "Must not start an absent server"))))
     ,@body))

(defun lang-c-test--tree-mode (cpp)
  "Mock the final tree-sitter mode, with CPP selecting C++."
  (kill-all-local-variables)
  (setq major-mode (if cpp 'c++-ts-mode 'c-ts-mode))
  (use-local-map (make-sparse-keymap))
  (run-mode-hooks (if cpp 'c++-ts-mode-hook 'c-ts-mode-hook)))

(ert-deftest lang-c-file-suffixes ()
  "Exact file rules cover C/C++ and leave unrelated C-like modes alone."
  (dolist (rule lang-c-test--rules)
    (should (member rule auto-mode-alist)))
  (lang-c-test--without-tools
    (dolist (suffix '("c" "h" "cc" "cpp" "cxx" "c++" "C" "hh" "hpp"
                      "hxx" "h++" "H" "ipp" "inl" "tpp" "ixx" "cppm"))
      (with-temp-buffer
        (setq buffer-file-name (concat "/tmp/example." suffix))
        (set-auto-mode)
        (should (eq major-mode (if (member suffix '("c" "h"))
                                  'c-mode 'c++-mode)))))
    (dolist (suffix '("m" "mm" "cs" "java"))
      (should-not
       (cl-some (lambda (rule)
                  (string-match-p (car rule) (concat "example." suffix)))
                lang-c-test--rules)))))

(ert-deftest lang-c-case-insensitive-file-dispatch ()
  "Distinguish .c/.C and .h/.H even when Emacs folds filename matching."
  (lang-c-test--without-tools
    (cl-letf (((symbol-function 'file-name-case-insensitive-p)
               (lambda (&rest _) t)))
      (dolist (entry '(("c" . c-mode) ("C" . c++-mode)
                       ("h" . c-mode) ("H" . c++-mode)))
        (with-temp-buffer
          (setq buffer-file-name (concat "/tmp/example." (car entry)))
          (set-auto-mode)
          (should (eq major-mode (cdr entry))))))))

(ert-deftest lang-c-preloaded-cc-mode-lazy-startup ()
  "Preloaded ordinary CC Mode cannot bypass the wrapper's lazy trigger."
  (should (featurep 'cc-mode))
  (let ((auto-mode-alist (copy-sequence auto-mode-alist))
        (load-history load-history)
        (my/lazy--triggers nil)
        (my/lazy-modules
         `((lang-c :files ,lang-c-test--rules
                   :commands (my/c-mode my/c++-mode my/c-or-c++-mode)))))
    ;; Restore function definitions and feature membership after exercising
    ;; the actual lazy loader, without unloading shared built-in packages.
    (cl-letf (((symbol-value 'features) (remq 'lang-c features))
              ((symbol-function 'my/c-mode) nil)
              ((symbol-function 'my/c++-mode) nil)
              ((symbol-function 'my/c-or-c++-mode) nil))
      (my/lazy-require 'lang-c)
      (should-not (featurep 'lang-c))
      (lang-c-test--without-tools
        (with-temp-buffer
          (setq buffer-file-name "/tmp/lazy.c")
          (set-auto-mode)
          (should (featurep 'lang-c))
          (should (eq major-mode 'c-mode))
          (should (memq #'my/c-format-on-save before-save-hook))
          (should (eq (key-binding (kbd "C-c b")) 'project-compile)))))))

(ert-deftest lang-c-tree-grammar-selection ()
  "C and C++ need their own grammar; generic header remaps need both."
  (dolist (available '(nil (c) (cpp) (c cpp)))
    (lang-c-test--without-tools
      (cl-letf (((symbol-function 'treesit-ready-p)
                 (lambda (languages &optional quiet)
                   (should quiet)
                   (cl-every (lambda (language) (memq language available))
                             languages)))
                ((symbol-function 'c-ts-mode)
                 (lambda ()
                   (should-not treesit-auto-install-grammar)
                   (lang-c-test--tree-mode nil)))
                ((symbol-function 'c++-ts-mode)
                 (lambda ()
                   (should-not treesit-auto-install-grammar)
                   (lang-c-test--tree-mode t))))
        (with-temp-buffer
          (my/c-mode)
          (should (eq major-mode (if (memq 'c available)
                                    'c-ts-mode 'c-mode))))
        (with-temp-buffer
          (my/c++-mode)
          (should (eq major-mode (if (memq 'cpp available)
                                    'c++-ts-mode 'c++-mode))))))))

(ert-deftest lang-c-header-heuristics-select-final-mode-once ()
  "The standard header heuristic starts only the chosen mode's tools."
  (dolist (available '(nil (c) (cpp) (c cpp)))
    (dolist (contents '("int function(void);\n"
                        "namespace example { class Item {}; }\n"))
      (let ((starts 0)
            (c-mode-hook c-mode-hook)
            (c++-mode-hook c++-mode-hook)
            (c-ts-mode-hook c-ts-mode-hook)
            (c++-ts-mode-hook c++-ts-mode-hook))
        (dolist (hook '(c-mode-hook c++-mode-hook c-ts-mode-hook c++-ts-mode-hook))
          (add-hook hook (lambda () (setq starts (1+ starts)))))
        (lang-c-test--without-tools
          (cl-letf (((symbol-function 'treesit-ready-p)
                     (lambda (languages &optional _quiet)
                       (cl-every (lambda (language) (memq language available))
                                 languages)))
                    ((symbol-function 'c-ts-mode)
                     (lambda () (lang-c-test--tree-mode nil)))
                    ((symbol-function 'c++-ts-mode)
                     (lambda () (lang-c-test--tree-mode t))))
            (with-temp-buffer
              (setq buffer-file-name "/tmp/example.h")
              (insert contents)
              (set-auto-mode)
              (should (= starts 1))
              (should (eq major-mode
                          (if (string-prefix-p "namespace" contents)
                              (if (memq 'cpp available) 'c++-ts-mode 'c++-mode)
                            (if (memq 'c available) 'c-ts-mode 'c-mode)))))))))))

(ert-deftest lang-c-envrc-real-hook-order ()
  "Globalized envrc runs after mode hooks and before C tooling at depth 90."
  (should (= (alist-get #'my/c-after-major-mode
                       (symbol-value
                        (get 'after-change-major-mode-hook 'hook--depth-alist)))
             90))
  (let ((was-global envrc-global-mode)
        (starts 0)
        (envrc-mode-hook nil))
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (command &rest _) command))
                  ((symbol-function 'treesit-ready-p) (lambda (&rest _) nil))
                  ((symbol-function 'envrc--get-current-env-or-run-direnv)
                   (lambda () (envrc--apply (current-buffer) 'running)))
                  ((symbol-function 'eglot-ensure)
                   (lambda ()
                     (should envrc-mode)
                     (should my/c--mode-ready)
                     (should (equal exec-path '("/fake/project/bin/")))
                     (setq starts (1+ starts)))))
          (envrc-global-mode 1)
          (with-temp-buffer
            (setq buffer-file-name "/tmp/environment.c")
            (let ((c-mode-hook
                   (cons (lambda ()
                           (should-not my/c--mode-ready)
                           (should (= starts 0)))
                         c-mode-hook)))
              (my/c-mode))
            (should envrc-mode)
            (should envrc--running)
            (should my/c--mode-ready)
            (should (= starts 0))
            (envrc--apply (current-buffer) 'denied)
            (should (= starts 0))
            (envrc--apply (current-buffer) '(("PATH" . "/fake/project/bin")))
            (should (= starts 1))))
      (unless was-global (envrc-global-mode -1)))))

(ert-deftest lang-c-deferred-eglot-contact-rechecks-environment ()
  "Real Eglot deferral cannot connect with a newly pending environment."
  (let ((post-command-hook nil)
        (starts 0)
        (available t)
        warnings)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (command &rest _) (and available command)))
              ((symbol-function 'treesit-ready-p) (lambda (&rest _) nil))
              ((symbol-function 'project-current)
               (lambda (&rest _) '(transient . "/tmp/")))
              ((symbol-function 'eglot--connect)
               (lambda (&rest arguments)
                 (should (my/environment-ready-p))
                 (should (equal (nth 3 arguments) '("late-project-clangd")))
                 (setq starts (1+ starts))))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/deferred.c")
        (my/c-mode)
        (should (= starts 0))
        (setq-local envrc-mode t)
        (setq-local envrc--running t)
        (setq-local envrc--status 'on)
        (run-hooks 'post-command-hook)
        (should (= starts 0))
        (should warnings)
        (setq-local envrc--running nil)
        (my/environment-applied (current-buffer) 'none)
        ;; The executable can also disappear between ensure and contact.
        (setq available nil)
        (run-hooks 'post-command-hook)
        (should (= starts 0))
        (should (= (length warnings) 2))
        (setq available t)
        (my/environment-applied (current-buffer) 'none)
        (setq-local my/clangd-command '("late-project-clangd"))
        (run-hooks 'post-command-hook)
        (should (= starts 1))))))

(ert-deftest lang-c-missing-tools-preserve-syntax ()
  "Absent clangd and grammars leave usable syntax editing in CC Mode."
  (lang-c-test--without-tools
    (with-temp-buffer
      (setq buffer-file-name "/tmp/no-tools.c")
      (my/c-mode)
      (insert "/* comment */\nint value;\n")
      (goto-char (point-min))
      (search-forward "comment")
      (should (nth 4 (syntax-ppss)))
      (should-error (my/clangd-contact) :type 'user-error))))

(ert-deftest lang-c-startup-notifications-deduplicate ()
  "Mode completion, project locals and envrc schedule one deferred attempt."
  (let ((starts 0))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (command &rest _) command))
              ((symbol-function 'treesit-ready-p) (lambda (&rest _) nil))
              ((symbol-function 'eglot-ensure)
               (lambda () (setq starts (1+ starts)))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/deduplicate.c")
        (my/c-mode)
        (run-hooks 'hack-local-variables-hook)
        (my/environment-applied (current-buffer) 'none)
        (should (= starts 1))
        (run-hooks 'post-command-hook)
        (my/environment-applied (current-buffer) 'none)
        (should (= starts 2))))))

(ert-deftest lang-c-format-save-is-managed-and-idempotent ()
  "Repeated environment updates keep one named formatter, without a CLI."
  (let ((formats 0)
        managed)
    (lang-c-test--without-tools
      (cl-letf (((symbol-function 'eglot-managed-p) (lambda () managed))
                ((symbol-function 'eglot-format-buffer)
                 (lambda () (setq formats (1+ formats)))))
        (with-temp-buffer
          (my/c-mode)
          (dotimes (_ 3)
            (my/c-setup)
            (my/environment-applied (current-buffer) 'none))
          (should (= (cl-count #'my/c-format-on-save before-save-hook) 1))
          (run-hooks 'before-save-hook)
          (should (= formats 0))
          (setq managed t)
          (run-hooks 'before-save-hook)
          (should (= formats 1)))))))

(ert-deftest lang-c-project-and-user-settings-survive ()
  "Mode startup and late contacts preserve user and project overrides."
  (let ((my/clangd-command '("user-clangd" "--background-index"))
        (c-default-style "linux")
        (c-basic-offset 7)
        (indent-tabs-mode t)
        (eglot-workspace-configuration '(:clangd (:fallbackFlags ["-std=c23"]))))
    (lang-c-test--without-tools
      (with-temp-buffer
        (my/c-mode)
        (should (= c-basic-offset 7))
        (should indent-tabs-mode)
        ;; File and directory locals are applied after major-mode startup.
        (setq-local my/clangd-command '("project-clangd" "--compile-commands-dir=out"))
        (setq-local c-basic-offset 3)
        (setq-local indent-tabs-mode nil)
        (setq-local eglot-workspace-configuration '(:clangd (:custom t)))
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (command &rest _) command))
                  ((symbol-function 'eglot-ensure) #'ignore))
          (my/c-setup)
          (my/c-after-major-mode)
          (should (equal (my/clangd-contact)
                         '("project-clangd" "--compile-commands-dir=out"))))
        (should (= c-basic-offset 3))
        (should-not indent-tabs-mode)
        (should (equal eglot-workspace-configuration '(:clangd (:custom t))))))
    (should (equal my/clangd-command '("user-clangd" "--background-index")))))

(ert-deftest lang-c-real-directory-locals-select-server ()
  "Directory locals can enable a server unavailable during mode startup."
  (let ((directory (make-temp-file "lang-c-project-" t))
        (enable-local-variables :all)
        (enable-local-eval nil)
        (starts 0)
        buffer)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".dir-locals.el" directory)
            (insert "((c-mode . ((my/clangd-command . (\"project-clangd\"))\n"
                    "             (c-basic-offset . 3)\n"
                    "             (indent-tabs-mode . nil)\n"
                    "             (eglot-workspace-configuration . (:clangd (:custom t))))))\n"))
          (with-temp-file (expand-file-name "example.c" directory)
            (insert "int value;\n"))
          (cl-letf (((symbol-function 'treesit-ready-p) (lambda (&rest _) nil))
                    ((symbol-function 'executable-find)
                     (lambda (command &rest _)
                       (and (equal command "project-clangd") command)))
                    ((symbol-function 'eglot-ensure)
                     (lambda ()
                       (should (equal (my/clangd-contact) '("project-clangd")))
                       (setq starts (1+ starts)))))
            (setq buffer (find-file-noselect (expand-file-name "example.c" directory)))
            (with-current-buffer buffer
              (should (= starts 1))
              (should (= c-basic-offset 3))
              (should-not indent-tabs-mode)
              (should (equal eglot-workspace-configuration '(:clangd (:custom t)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest lang-c-remote-server-without-local-installation ()
  "Remote startup and contact look up clangd on the file's owning host."
  (let ((starts 0)
        checks)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (command &optional remote)
                 (push (list command remote default-directory) checks)
                 (when (and remote (string-prefix-p "/ssh:" default-directory))
                   "/remote/bin/clangd")))
              ((symbol-function 'eglot-ensure)
               (lambda () (setq starts (1+ starts)))))
      (with-temp-buffer
        (setq major-mode 'c-mode)
        (setq-local default-directory "/ssh:example:/project/"
                    buffer-file-name "/ssh:example:/project/main.c"
                    my/c--mode-ready t)
        (my/c--ensure-tools)
        (should (= starts 1))
        (should (equal (my/clangd-contact) my/clangd-command))
        (should (= (length checks) 2))
        (dolist (check checks)
          (should (equal check '("clangd" t "/ssh:example:/project/")))))
      (with-temp-buffer
        (setq major-mode 'c-mode)
        (setq-local default-directory "/tmp/"
                    buffer-file-name "/tmp/main.c" my/c--mode-ready t)
        (my/c--ensure-tools)
        (should (= starts 1))
        (should-error (my/clangd-contact) :type 'user-error)))))

(ert-deftest lang-c-mode-cookies-load-module-with-preloaded-cc-mode ()
  "File mode declarations load C tooling before the first native mode hook."
  (dolist (entry '(("main.c" "c" c-mode) ("header.h" "c++" c++-mode)))
    (pcase-let ((`(,file ,cookie ,mode) entry))
      (let ((auto-mode-alist (copy-sequence auto-mode-alist))
            (load-history load-history)
            ;; Exercise native mode cookies independently of Emacs 31's
            ;; optional automatic grammar installation/remapping policy.
            (treesit-enabled-modes nil)
            (major-mode-remap-alist nil)
            (change-major-mode-after-body-hook change-major-mode-after-body-hook)
            (after-load-alist (copy-tree after-load-alist))
            (c-mode-hook (remq #'my/c-setup c-mode-hook))
            (c++-mode-hook (remq #'my/c-setup c++-mode-hook))
            (my/lazy--triggers nil))
        (cl-letf (((symbol-value 'features) (remq 'lang-c features))
                  ((symbol-function 'my/c-mode) nil)
                  ((symbol-function 'my/c++-mode) nil)
                  ((symbol-function 'my/c-or-c++-mode) nil))
          (should (fboundp mode))
          (should-not (autoloadp (symbol-function mode)))
          (my/lazy-require 'lang-c)
          (should-not (featurep 'lang-c))
          (lang-c-test--without-tools
            (with-temp-buffer
              (setq buffer-file-name (concat "/tmp/" file))
              (insert (format "/* -*- mode: %s -*- */\nint value;\n" cookie))
              (set-auto-mode)
              (should (eq major-mode mode))
              (should (featurep 'lang-c))
              (should (memq #'my/c-format-on-save before-save-hook))
              (should (eq (key-binding (kbd "C-c b")) 'project-compile))
              (should my/c--mode-ready))))))))

(ert-deftest lang-c-native-keys-and-scope ()
  "Native commands and Eglot keys survive without affecting Java or ObjC."
  (lang-c-test--without-tools
    (dolist (mode '(my/c-mode my/c++-mode))
      (with-temp-buffer
        (funcall mode)
        (should (eq (key-binding (kbd "C-c b")) 'project-compile))
        (should (eq (key-binding (kbd "C-c k")) 'recompile))
        (should (eq (key-binding (kbd "C-c o")) 'ff-find-other-file))
        (should (eq (key-binding (kbd "C-c C-c")) 'comment-region))
        (should (eq (key-binding (kbd "C-c C-k")) 'c-toggle-comment-style))
        (should (eq (key-binding (kbd "C-c C-o")) 'c-set-offset))
        (should (eq (key-binding (kbd "C-c e")) 'eglot))
        (should (eq (lookup-key eglot-mode-map (kbd "C-c l f"))
                    'eglot-format-buffer))))
    (dolist (mode '(java-mode objc-mode csharp-mode))
      (with-temp-buffer
        (funcall mode)
        (my/c-setup)
        (should-not my/c--mode-ready)
        (should-not (memq #'my/c-format-on-save before-save-hook))
        (should-not (eq (key-binding (kbd "C-c b")) 'project-compile))))))

(ert-deftest lang-c-tree-native-keys-preserved ()
  "Tree-sitter comment commands remain available beside project commands."
  (lang-c-test--without-tools
    (with-temp-buffer
      (c-ts-base-mode)
      (setq major-mode 'c-ts-mode)
      (my/c-setup)
      (should (eq (key-binding (kbd "C-c b")) 'project-compile))
      (should (eq (key-binding (kbd "C-c C-c")) 'comment-region))
      (should (eq (key-binding (kbd "C-c C-k"))
                  'c-ts-mode-toggle-comment-style)))))

(ert-deftest lang-c-optional-evil-keys ()
  "Evil leader commands work in command states and preserve native keys."
  (skip-unless (featurep 'evil))
  (lang-c-test--without-tools
    (with-temp-buffer
      (my/c++-mode)
      (evil-local-mode 1)
      (dolist (state '(normal motion visual))
        (evil-change-state state)
        (dolist (binding '(("c" . project-compile) ("k" . recompile)
                           ("o" . ff-find-other-file) ("f" . eglot-format-buffer)
                           ("a" . eglot-code-actions) ("r" . eglot-rename)))
          (should (eq (key-binding (kbd (concat "SPC m " (car binding))))
                      (cdr binding))))
        (should (eq (key-binding (kbd "C-c b")) 'project-compile)))
      (evil-insert-state)
      (should (eq (key-binding (kbd "SPC")) 'self-insert-command))
      (evil-local-mode -1)
      (should (eq (key-binding (kbd "C-c b")) 'project-compile)))))

(provide 'lang-c-test)
;;; lang-c-test.el ends here
