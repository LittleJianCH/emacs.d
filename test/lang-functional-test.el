;;; lang-functional-test.el --- Haskell and Lean tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise optional language configuration without installing packages or
;; launching compilers.  Run after init.el alongside init-lazy-test.el.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'eglot)
(require 'use-package)
(require 'init-env)

(declare-function my/haskell-setup "lang-haskell")
(declare-function my/haskell-start-eglot "lang-haskell")
(declare-function my/haskell-contact "lang-haskell")
(declare-function my/haskell-environment-ready "lang-haskell")
(declare-function my/lean-setup "lang-lean")
(declare-function my/lean-start-lsp "lang-lean")
(declare-function my/lean-environment-ready "lang-lean")
(declare-function my/lean-uncached-rootdir "lang-lean")
(declare-function evil-local-mode "evil-core")
(declare-function evil-change-state "evil-core")
(declare-function evil-insert-state "evil-states")
(defvar my/haskell-server-command)
(defvar my/lazy-modules)

;; Module declarations must be testable on a machine without these packages.
(let ((use-package-ensure-function #'ignore))
  (cl-letf (((symbol-function 'use-package-vc-install) #'ignore))
    (require 'lang-haskell)
    (require 'lang-lean)))

(defvar lean4-executable-name)
(defvar lsp-completion-provider)
(defvar lsp-diagnostics-provider)
(defvar lsp-enable-snippet)
(defvar lsp-mode)
(defvar haskell-mode-map)
(defvar lean4-mode-map)
(defvar lean4-mode-hook)
(defvar lean4-rootdir)
(defvar envrc-mode)
(defvar envrc--running)
(defvar envrc--status)

(ert-deftest lang-lean-replaces-unconditional-lsp-hook ()
  "Loading Lean removes eager LSP startup and preserves other mode hooks."
  (let ((saved-features (copy-sequence features))
        (after-load-alist (copy-tree after-load-alist))
        (lean4-mode-map (make-sparse-keymap))
        (lean4-mode-hook '(lsp my/lean-setup custom-lean-hook)))
    (unwind-protect
        (progn
          (provide 'lean4-mode)
          (should-not (memq 'lsp lean4-mode-hook))
          (should (memq 'my/lean-setup lean4-mode-hook))
          (should (memq 'custom-lean-hook lean4-mode-hook)))
      (setq features saved-features))))

(ert-deftest lang-functional-file-rules ()
  "Lazy rules and module rules select source, literate, Cabal and Lean modes."
  (dolist (entry '(("Example.hs" haskell-mode lang-haskell)
                   ("Example.lhs" haskell-literate-mode lang-haskell)
                   ("example.cabal" haskell-cabal-mode lang-haskell)
                   ("Example.lean" lean4-select-mode lang-lean)))
    (pcase-let ((`(,file ,mode ,feature) entry))
      (let ((rules (plist-get (cdr (assq feature my/lazy-modules)) :files)))
        (should (eq (assoc-default file rules #'string-match) mode))
        (should (member (seq-find
                         (lambda (rule) (string-match-p (car rule) file))
                         rules)
                        auto-mode-alist))))))

(ert-deftest lang-haskell-without-server ()
  "Editing and GHCi commands remain available when HLS is absent."
  (let (indent interaction)
    (cl-letf (((symbol-function 'my/environment-ready-p) (lambda () t))
              ((symbol-function 'executable-find) (lambda (_) nil))
              ((symbol-function 'eglot-ensure)
               (lambda () (ert-fail "Missing HLS must not start")))
              ((symbol-function 'haskell-indentation-mode)
               (lambda (arg) (setq indent arg)))
              ((symbol-function 'interactive-haskell-mode)
               (lambda (arg) (setq interaction arg))))
      (with-temp-buffer
        (my/haskell-setup)
        (my/haskell-start-eglot)
        (should (= indent 1))
        (should (= interaction 1))
        (should-not indent-tabs-mode)))))

(ert-deftest lang-haskell-server-command-and-environment ()
  "HLS waits for direnv, then uses the buffer environment and custom command."
  (let ((my/haskell-server-command '("project-hls" "--lsp" "--debug"))
        ready calls)
    (cl-letf (((symbol-function 'my/environment-ready-p) (lambda () ready))
              ((symbol-function 'executable-find)
               (lambda (command)
                 (should ready)
                 (should (equal command "project-hls"))
                 (should (equal exec-path '("/project/bin")))
                 command))
              ((symbol-function 'eglot-ensure)
               (lambda ()
                 (push (getenv "GHC_ENVIRONMENT") calls))))
      (with-temp-buffer
        (setq major-mode 'haskell-mode)
        (setq-local exec-path '("/project/bin")
                    process-environment '("GHC_ENVIRONMENT=/project/.ghc.env"))
        (my/haskell-start-eglot)
        (should-not calls)
        (setq ready t)
        (my/haskell-environment-ready)
        (should (equal calls '("/project/.ghc.env")))
        (should (equal (my/haskell-contact) my/haskell-server-command))
        (should (equal (cdr (assoc '(haskell-mode haskell-literate-mode)
                                  eglot-server-programs))
                       'my/haskell-contact))))))

(ert-deftest lang-haskell-format-only-when-connected ()
  "Environment retries add one save hook, which formats only through HLS."
  (let (managed (formatted 0))
    (cl-letf (((symbol-function 'my/haskell-start-eglot) #'ignore)
              ((symbol-function 'haskell-indentation-mode) #'ignore)
              ((symbol-function 'interactive-haskell-mode) #'ignore)
              ((symbol-function 'eglot-managed-p) (lambda () managed))
              ((symbol-function 'eglot-format-buffer)
               (lambda () (setq formatted (1+ formatted)))))
      (with-temp-buffer
        (my/haskell-setup)
        (let ((hooks before-save-hook))
          (my/haskell-setup)
          (should (equal before-save-hook hooks)))
        (run-hooks 'before-save-hook)
        (should (= formatted 0))
        (setq managed t)
        (run-hooks 'before-save-hook)
        (should (= formatted 1))))))

(ert-deftest lang-lean-waits-for-environment ()
  "Lean does not search for or start tools before direnv finishes."
  (cl-letf (((symbol-function 'my/environment-ready-p) (lambda () nil))
            ((symbol-function 'executable-find)
             (lambda (_) (ert-fail "Environment is not ready")))
            ((symbol-function 'lean4-get-executable)
             (lambda (_) (ert-fail "Environment is not ready")))
            ((symbol-function 'lsp)
             (lambda () (ert-fail "Must wait for direnv"))))
    (with-temp-buffer (my/lean-setup) (my/lean-start-lsp))))

(ert-deftest lang-lean-no-toolchain ()
  "Lean syntax editing does not require an installed compiler."
  (let ((lean4-executable-name "lean"))
    (cl-letf (((symbol-function 'my/environment-ready-p) (lambda () t))
              ((symbol-function 'lean4-get-executable)
               (lambda (_) (error "No Lean toolchain")))
              ((symbol-function 'lsp)
               (lambda () (ert-fail "Missing Lean must not start"))))
      (with-temp-buffer (my/lean-setup) (my/lean-start-lsp)))))

(ert-deftest lang-lean-server-and-local-ui ()
  "Lean starts after environment updates and uses Corfu/Flymake locally."
  (let ((lean4-executable-name "project-lean")
        (lsp-completion-provider :none)
        (lsp-diagnostics-provider :auto)
        (lsp-enable-snippet t)
        calls)
    (cl-letf (((symbol-function 'my/environment-ready-p) (lambda () t))
              ((symbol-function 'lean4-get-executable)
               (lambda (command)
                 (should (equal command "project-lean"))
                 "/project/bin/lean"))
              ((symbol-function 'file-executable-p)
               (lambda (file) (equal file "/project/bin/lean")))
              ((symbol-function 'lsp)
               (lambda () (push (getenv "LEAN_PATH") calls))))
      (with-temp-buffer
        (setq major-mode 'lean4-mode)
        (setq-local process-environment '("LEAN_PATH=/project/.lake"))
        (my/lean-setup)
        (my/lean-environment-ready)
        (should (equal calls '("/project/.lake")))
        (should (eq lsp-completion-provider :capf))
        (should (eq lsp-diagnostics-provider :flymake))
        (should-not lsp-enable-snippet)
        (setq-local lsp-mode t)
        (my/lean-environment-ready)
        (should (= (length calls) 1)))
      (should (eq lsp-completion-provider :none))
      (should (eq lsp-diagnostics-provider :auto))
      (should lsp-enable-snippet))))

(ert-deftest lang-functional-starts-after-envrc-mode ()
  "Mode hooks cannot launch global tools before envrc enables itself."
  (dolist (entry '((haskell-mode my/haskell-setup my/haskell-environment-ready
                                eglot-ensure)
                   (lean4-mode my/lean-setup my/lean-environment-ready lsp)))
    (pcase-let ((`(,mode ,setup ,callback ,start) entry))
      (should (memq callback (default-value 'after-change-major-mode-hook)))
      (let ((lean4-executable-name "lean")
            (envrc-mode nil)
            (envrc--running nil)
            (envrc--status 'none)
            (started 0)
            (after-change-major-mode-hook nil))
        (cl-letf (((symbol-function 'executable-find) #'identity)
                  ((symbol-function 'lean4-get-executable)
                   (lambda (_) "/project/bin/lean"))
                  ((symbol-function 'file-executable-p) (lambda (_) t))
                  ((symbol-function 'haskell-indentation-mode) #'ignore)
                  ((symbol-function 'interactive-haskell-mode) #'ignore)
                  ((symbol-function start)
                   (lambda ()
                     (should envrc-mode)
                     (should-not envrc--running)
                     (should (equal (getenv "PROJECT_TOOLCHAIN") "ready"))
                     (setq started (1+ started)))))
          (with-temp-buffer
            (setq major-mode mode)
            ;; Use the real mode-hook ordering: envrc's globalized mode
            ;; activates only after the language setup hook has completed.
            (add-hook 'after-change-major-mode-hook callback 90)
            (add-hook 'after-change-major-mode-hook
                      (lambda ()
                        (should (= started 0))
                        (setq-local envrc-mode t envrc--running t)))
            (funcall setup)
            (run-mode-hooks)
            (should (= started 0))
            (setq-local envrc--running nil envrc--status 'on
                        process-environment '("PROJECT_TOOLCHAIN=ready"))
            (my/environment-applied (current-buffer)
                                    '(("PROJECT_TOOLCHAIN" . "ready")))
            (should (= started 1))))))))

(ert-deftest lang-haskell-rechecks-environment-at-contact ()
  "An environment change between Eglot scheduling and connection blocks HLS."
  (let ((envrc-mode t) (envrc--running t) (envrc--status 'on))
    (should-error (my/haskell-contact) :type 'user-error)
    (setq envrc--running nil envrc--status 'denied)
    (should-error (my/haskell-contact) :type 'user-error)
    (setq envrc--status 'on)
    (should (equal (my/haskell-contact) my/haskell-server-command))))

(ert-deftest lang-lean-project-toolchains-do-not-share-cache ()
  "Upstream discovery returns each project's path without a global cache."
  (let ((lean4-rootdir nil)
        (detect (lambda ()
                  (setq lean4-rootdir (car exec-path)))))
    (dolist (root '("/project-a/toolchain" "/project-b/toolchain"))
      (with-temp-buffer
        (setq-local exec-path (list root))
        (should (equal (my/lean-uncached-rootdir detect) root))
        (should-not lean4-rootdir)))
    ;; Explicit user or project roots remain available to upstream lookup.
    (setq lean4-rootdir "/custom/toolchain")
    (let ((exec-path '("/refreshed/toolchain")))
      (should (equal (my/lean-uncached-rootdir detect) "/refreshed/toolchain")))
    (should (equal lean4-rootdir "/custom/toolchain"))))

(ert-deftest lang-lean-explicit-root-without-path ()
  "A configured Lean root starts LSP even when PATH has no Lean executable."
  (let* ((root (make-temp-file "lean-root-" t))
         (lean4-rootdir root)
         (lean4-executable-name "lean")
         started)
    (unwind-protect
        (progn
          (make-directory (expand-file-name "bin" root))
          (let ((program (expand-file-name "bin/lean" root)))
            (with-temp-file program (insert "#!/bin/sh\nexit 99\n"))
            (set-file-modes program #o755))
          (cl-letf (((symbol-function 'my/environment-ready-p) (lambda () t))
                    ((symbol-function 'executable-find) (lambda (_) nil))
                    ((symbol-function 'lean4-get-executable)
                     (lambda (name)
                       (expand-file-name name (expand-file-name "bin" lean4-rootdir))))
                    ((symbol-function 'lsp) (lambda () (setq started t))))
            (with-temp-buffer
              (my/lean-start-lsp)
              (should started))))
      (delete-directory root t))))

(ert-deftest lang-functional-environment-hooks-are-scoped ()
  "Changes in unrelated buffers cannot start HLS or Lean."
  (cl-letf (((symbol-function 'my/haskell-start-eglot)
             (lambda () (ert-fail "Unrelated Haskell callback")))
            ((symbol-function 'my/lean-start-lsp)
             (lambda () (ert-fail "Unrelated Lean callback"))))
    (with-temp-buffer
      (emacs-lisp-mode)
      (my/haskell-environment-ready)
      (my/lean-environment-ready))))

(ert-deftest lang-functional-evil-leaders ()
  "Language leaders work in command states and preserve native keys."
  (skip-unless (featurep 'init-evil))
  (dolist (entry '((haskell-mode-map my/haskell-evil-keys
                    "l" haskell-process-load-file "C-c C-l")
                   (lean4-mode-map my/lean-evil-keys
                    "i" lean4-toggle-info "C-c C-i")))
    (pcase-let* ((`(,map-symbol ,setup ,key ,command ,native) entry)
                 (map (make-sparse-keymap)))
      (cl-progv (list map-symbol) (list map)
        (define-key map (kbd native) command)
        (funcall setup)
        (with-temp-buffer
          (use-local-map map)
          (evil-local-mode 1)
          (dolist (state '(normal motion visual))
            (evil-change-state state)
            (should (eq (key-binding (kbd (concat "SPC l " key))) command))
            (should (eq (key-binding (kbd native)) command)))
          (evil-insert-state)
          (should (eq (key-binding (kbd "SPC")) 'self-insert-command))
          (evil-local-mode -1)
          (should (eq (key-binding (kbd native)) command)))))))

(ert-deftest lang-functional-haskell-leader-with-eglot ()
  "Haskell's SPC l commands sit beside Eglot's without shadowing them."
  (skip-unless (featurep 'init-evil))
  (require 'eglot)
  (let ((haskell-mode-map (make-sparse-keymap)))
    (my/haskell-evil-keys)
    (with-temp-buffer
      (use-local-map haskell-mode-map)
      (setq-local eglot--managed-mode t)
      (evil-local-mode 1)
      (evil-normal-state)
      (dolist (binding '(("l" . haskell-process-load-file)
                         ("R" . haskell-process-reload)
                         ("a" . eglot-code-actions)
                         ("r" . eglot-rename)
                         ("f" . eglot-format-buffer)))
        (should (eq (key-binding (kbd (concat "SPC l " (car binding))))
                    (cdr binding)))))))

(provide 'lang-functional-test)
;;; lang-functional-test.el ends here
