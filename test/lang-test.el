;;; lang-test.el --- Language integration tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Run after init.el with ERT.  Toolchain calls are mocked; no real language
;; servers or Agda compiler processes are started.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'eglot)
(require 'lang-nix)
(require 'lang-agda)

(defvar agda2-mode-map)

(ert-deftest lang-nix-syntax-without-tools ()
  "Opening Nix files still provides syntax editing without nil or nixfmt."
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil))
            ((symbol-function 'eglot-ensure)
             (lambda () (ert-fail "Must not start a missing server"))))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/flake.nix")
      (set-auto-mode)
      (should (eq major-mode 'nix-mode))
      (should-not indent-tabs-mode)
      (insert "{ # comment\n  answer = 42;\n}\n")
      (font-lock-ensure)
      (goto-char (point-min))
      (search-forward "comment")
      (should (nth 4 (syntax-ppss))))))

(ert-deftest lang-nix-server-and-formatter ()
  "nil starts and nixfmt is configured without mutating global settings."
  (let* ((config '(:other (:enabled t)))
         (eglot-workspace-configuration config)
         (my/nil-command '("custom-nil" "--stdio"))
         started format-hook)
    (cl-letf (((symbol-function 'executable-find) #'identity)
              ((symbol-function 'eglot-ensure) (lambda () (setq started t)))
              ((symbol-function 'my/eglot-format-on-save)
               (lambda () (setq format-hook t))))
      (with-temp-buffer
        (my/nix-setup)
        (should started)
        (should format-hook)
        (should (equal (my/nil-contact) '("custom-nil" "--stdio")))
        (should (equal (plist-get eglot-workspace-configuration :nil)
                       '(:formatting (:command ["nixfmt"]))))
        (should (equal (plist-get eglot-workspace-configuration :other)
                       '(:enabled t)))))
    (should (equal config '(:other (:enabled t))))))

(ert-deftest lang-nix-preserves-project-settings ()
  "Explicit nil settings and function-valued project configuration survive."
  (dolist (config (list '(:nil (:formatting (:command ["alejandra"])))
                       (lambda (&rest _) '(:nil (:diagnostics nil)))))
    (let ((eglot-workspace-configuration config))
      (cl-letf (((symbol-function 'executable-find) #'identity)
                ((symbol-function 'eglot-ensure) #'ignore)
                ((symbol-function 'my/eglot-format-on-save) #'ignore))
        (with-temp-buffer
          (my/nix-setup)
          (should (eq eglot-workspace-configuration config)))))))

(ert-deftest lang-nix-no-formatter-no-save-hook ()
  "A missing formatter must not make saving fail."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (name) (unless (equal name "nixfmt") name)))
            ((symbol-function 'eglot-ensure) #'ignore)
            ((symbol-function 'my/eglot-format-on-save)
             (lambda () (ert-fail "Must not enable missing formatter"))))
    (with-temp-buffer (my/nix-setup))))

(ert-deftest lang-agda-file-associations ()
  "Agda and supported literate extensions dispatch to the lazy loader."
  (cl-letf (((symbol-function 'my/agda-mode)
             (lambda () (setq major-mode 'agda2-mode))))
    (dolist (file '("Proof.agda" "Proof.lagda" "Proof.lagda.md"
                    "Proof.lagda.rst" "Proof.lagda.tex" "Proof.lagda.org"
                    "Proof.lagda.typ" "Proof.lagda.tree"))
      (with-temp-buffer
        (setq buffer-file-name (concat "/tmp/" file))
        (set-auto-mode)
        (should (eq major-mode 'agda2-mode))))))

(ert-deftest lang-agda-locate-current-command ()
  "Use Agda 2.8+ directly and trim the path returned by locate."
  (let (calls)
    (cl-letf (((symbol-function 'executable-find) #'identity)
              ((symbol-function 'file-readable-p) (lambda (_) t))
              ((symbol-function 'process-file)
               (lambda (program _in _out _display &rest args)
                 (push (cons program args) calls)
                 (insert "/tmp/agda mode/agda2.el\n")
                 0)))
      (should (equal (my/agda-mode-file) "/tmp/agda mode/agda2.el"))
      (should (equal calls '(("agda" "--emacs-mode" "locate")))))))

(ert-deftest lang-agda-locate-legacy-command ()
  "Fall back to agda-mode when an older compiler rejects --emacs-mode."
  (let (calls)
    (cl-letf (((symbol-function 'executable-find) #'identity)
              ((symbol-function 'file-readable-p) (lambda (_) t))
              ((symbol-function 'process-file)
               (lambda (program _in _out _display &rest args)
                 (push (cons program args) calls)
                 (if (equal program "agda")
                     1
                   (insert "/tmp/agda2.el\n")
                   0))))
      (should (equal (my/agda-mode-file) "/tmp/agda2.el"))
      (should (equal (reverse calls)
                     '(("agda" "--emacs-mode" "locate")
                       ("agda-mode" "locate")))))))


(ert-deftest lang-agda-missing-installation ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should-error (my/agda-mode-file) :type 'user-error)))

(ert-deftest lang-agda-rejects-invalid-locate-output ()
  "Successful exit alone does not make locate output a usable mode path."
  (cl-letf (((symbol-function 'executable-find) #'identity)
            ((symbol-function 'file-readable-p) (lambda (_) nil))
            ((symbol-function 'process-file)
             (lambda (&rest _) (insert "/missing/agda2.el\n") 0)))
    (should-error (my/agda-mode-file) :type 'user-error)))

(ert-deftest lang-agda-lazy-load ()
  "Load the bundled entry point and activate the mode only on demand."
  (let ((directory (make-temp-file "agda-mode-test-" t))
        (load-path load-path))
    (unwind-protect
        (let ((file (expand-file-name "agda2.el" directory)))
          (with-temp-file file
            (insert ";;; -*- lexical-binding: t; -*-\n(defun agda2-mode () (setq major-mode 'agda2-mode))\n"))
          (cl-letf (((symbol-function 'agda2-mode) nil)
                    ((symbol-function 'my/agda-mode-file) (lambda () file)))
            (with-temp-buffer
              (my/agda-mode)
              (should (eq major-mode 'agda2-mode))
              (should (member directory (mapcar #'directory-file-name load-path))))))
      (delete-directory directory t))))


(ert-deftest lang-nix-profile-paths-idempotent ()
  "GUI startup discovers Nix without adding missing or duplicate paths."
  (cl-letf (((symbol-function 'file-directory-p)
             (lambda (dir)
               (equal dir "/nix/var/nix/profiles/default/bin"))))
    (let ((exec-path '("/usr/bin"))
          (process-environment '("PATH=/usr/bin")))
      (my/nix-profile-paths)
      (my/nix-profile-paths)
      (should (equal exec-path
                     '("/nix/var/nix/profiles/default/bin" "/usr/bin")))
      (should (equal (getenv "PATH")
                     "/nix/var/nix/profiles/default/bin:/usr/bin")))))

(ert-deftest lang-environment-readiness ()
  "Tools wait for running or denied environments, but not unrelated buffers."
  (let ((envrc-mode t) (envrc--running t) (envrc--status 'on))
    (should-not (my/environment-ready-p))
    (setq envrc--running nil)
    (should (my/environment-ready-p))
    (setq envrc--status 'denied)
    (should-not (my/environment-ready-p))
    (setq envrc-mode nil)
    (should (my/environment-ready-p))))

(ert-deftest lang-environment-callback-scope ()
  "Only completed environments notify the target buffer's language hooks."
  (with-temp-buffer
    (let* ((target (current-buffer))
           (called 0)
           (my/environment-ready-hook
            (list (lambda ()
                    (should (eq (current-buffer) target))
                    (setq called (1+ called))))))
      (my/environment-applied target 'running)
      (my/environment-applied target 'denied)
      (should (= called 0))
      (my/environment-applied target '(("AGDA_DIR" . "/project/.agda")))
      (should (= called 1)))))

(ert-deftest lang-agda-waits-for-async-environment ()
  "A cold Nix environment does not block Agda file opening."
  (let ((envrc-global-mode nil)
        (my/environment-ready-hook '(my/agda-environment-ready))
        ready activated)
    (cl-letf (((symbol-function 'my/environment-ready-p) (lambda () ready))
              ((symbol-function 'my/agda-activate)
               (lambda () (setq activated (getenv "AGDA_DIR")))))
      (with-temp-buffer
        (my/agda-mode)
        (should (eq major-mode 'prog-mode))
        (should my/agda-waiting-for-environment)
        (should-not activated)
        (setq-local process-environment '("AGDA_DIR=/project/.agda"))
        (setq ready t)
        (my/environment-applied (current-buffer) '(("AGDA_DIR" . "/project/.agda")))
        (should (equal activated "/project/.agda"))
        (should-not my/agda-waiting-for-environment)))))

(ert-deftest lang-agda-locate-retains-buffer-environment ()
  "Mode discovery subprocesses inherit the project's buffer-local env."
  (with-temp-buffer
    (setq-local process-environment '("AGDA_DIR=/project/.agda"))
    (setq-local exec-path '("/project/bin"))
    (cl-letf (((symbol-function 'executable-find) #'identity)
              ((symbol-function 'file-readable-p) (lambda (_) t))
              ((symbol-function 'process-file)
               (lambda (&rest _)
                 (should (equal (getenv "AGDA_DIR") "/project/.agda"))
                 (should (equal exec-path '("/project/bin")))
                 (insert "/project/agda2.el\n")
                 0)))
      (should (equal (my/agda-mode-file) "/project/agda2.el")))))

(ert-deftest lang-agda-activation-retains-environment ()
  "Changing major mode must preserve project variables for Agda processes."
  (with-temp-buffer
    (setq-local process-environment '("AGDA_DIR=/project/.agda"))
    (setq-local exec-path '("/project/bin"))
    (cl-letf (((symbol-function 'agda2-mode)
               (lambda ()
                 (kill-all-local-variables)
                 (should (equal (getenv "AGDA_DIR") "/project/.agda"))
                 (setq major-mode 'agda2-mode))))
      (my/agda-activate)
      (should (equal (getenv "AGDA_DIR") "/project/.agda"))
      (should (local-variable-p 'process-environment))
      (should (equal exec-path '("/project/bin"))))))

(ert-deftest lang-agda-markdown-activation ()
  "Literate Markdown selects Polymode after the environment is ready."
  (let ((envrc-global-mode nil))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/Proof.lagda.md")
      (setq-local process-environment '("AGDA_DIR=/project/.agda"))
      (setq-local exec-path '("/project/bin"))
      (cl-letf (((symbol-function 'agda2-mode)
                 (lambda () (ert-fail "Must use the Markdown host")))
                ((symbol-function 'poly-markdown-mode)
                 (lambda ()
                   (kill-all-local-variables)
                   (should (equal (getenv "AGDA_DIR") "/project/.agda"))
                   (setq major-mode 'markdown-mode))))
        (my/agda-activate)
        (should (eq major-mode 'markdown-mode))
        (should (equal (getenv "AGDA_DIR") "/project/.agda"))
        (should (equal exec-path '("/project/bin")))))))

(defvar-local lang-test--agda-initialized nil)

(ert-deftest lang-agda-polymode-cold-start ()
  "A fresh code buffer fully initializes with the host's project tools."
  (require 'poly-markdown)
  (let ((base (generate-new-buffer " *lang-agda-polymode-test*"))
        (baseline (default-value 'process-environment))
        (envrc-global-mode nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agda2-mode)
                   (lambda ()
                     (kill-all-local-variables)
                     (setq major-mode 'agda2-mode)
                     ;; Agda checks its compiler from a temp buffer before
                     ;; completing its highlighting and input setup.
                     (with-temp-buffer
                       (should (equal (getenv "AGDA_DIR") "/project/.agda"))
                       (should (equal exec-path '("/project/bin"))))
                     (setq-local lang-test--agda-initialized t))))
          (with-current-buffer base
            (setq buffer-file-name "/tmp/Proof.lagda.md")
            (insert "# Proof\n\n```agda\nmodule Proof where\n```\n")
            (set-buffer-modified-p nil)
            (setq-local process-environment '("AGDA_DIR=/project/.agda"))
            (setq-local exec-path '("/project/bin"))
            (my/agda-activate)
            (poly-lock-fontify-now (point-min) (point-max))
            (should (eq major-mode 'markdown-mode))
            (should-not markdown-fontify-code-blocks-natively)
            (should (slot-value pm/chunkmode 'protect-font-lock))
            (let ((inner (pm-get-buffer-of-mode 'agda2-mode)))
              (should (buffer-live-p inner))
              (with-current-buffer inner
                (should lang-test--agda-initialized)
                (should (eq (slot-value pm/chunkmode 'adjust-face)
                            'markdown-code-face))
                (should (equal (getenv "AGDA_DIR") "/project/.agda"))
                (should (local-variable-p 'process-environment))
                (should (equal exec-path '("/project/bin")))))
            (should (eq (default-value 'process-environment) baseline))))
      (when (buffer-live-p base)
        (dolist (buffer (buffer-list))
          (when (eq (buffer-base-buffer buffer) base)
            (kill-buffer buffer)))
        (kill-buffer base)))))

(ert-deftest lang-nix-environment-refresh-does-not-duplicate-save-hooks ()
  "Repeated async environment updates install the formatter only once."
  (let ((count 0))
    (cl-letf (((symbol-function 'executable-find) #'identity)
              ((symbol-function 'eglot-ensure) #'ignore)
              ((symbol-function 'my/eglot-format-on-save)
               (lambda () (setq count (1+ count)))))
      (with-temp-buffer
        (my/nix-setup)
        (my/nix-setup)
        (should (= count 1))))))

(ert-deftest lang-agda-activation-keeps-envrc-baseline ()
  "Do not let envrc cache a diff against temporary inherited defaults."
  (let ((baseline (default-value 'process-environment))
        (envrc-global-mode t)
        refreshed)
    (with-temp-buffer
      (setq-local process-environment '("AGDA_DIR=/project/.agda"))
      (cl-letf (((symbol-function 'agda2-mode)
                 (lambda ()
                   (kill-all-local-variables)
                   (envrc-mode 1)
                   (should-not refreshed)
                   (should (equal (getenv "AGDA_DIR") "/project/.agda"))))
                ((symbol-function 'envrc-mode)
                 (lambda (&rest _)
                   (should (eq (default-value 'process-environment) baseline))
                   (setq refreshed t))))
        (my/agda-activate)
        (should refreshed)))))



(ert-deftest lang-agda-evil-leader ()
  "Agda's leader works in command states and preserves native bindings."
  (skip-unless (featurep 'init-evil))
  (require 'evil)
  (let ((agda2-mode-map (make-sparse-keymap)))
    (define-key agda2-mode-map (kbd "C-c C-l") 'agda2-load)
    (my/agda-evil-keys)
    (with-temp-buffer
      (use-local-map agda2-mode-map)
      (evil-local-mode 1)
      (dolist (state '(normal motion visual))
        (evil-change-state state)
        (should (eq (key-binding (kbd "SPC m l")) 'agda2-load))
        (should (eq (key-binding (kbd "SPC m c")) 'agda2-goal-and-context))
        (should (eq (key-binding (kbd "SPC m s")) 'agda2-make-case))
        (should (eq (key-binding (kbd "SPC m g")) 'agda2-give))
        (should (eq (key-binding (kbd "C-c C-l")) 'agda2-load)))
      (evil-insert-state)
      (should (eq (key-binding (kbd "SPC")) 'self-insert-command))
      (evil-local-mode -1)
      (should (eq (key-binding (kbd "C-c C-l")) 'agda2-load)))))

(ert-deftest lang-envrc-evil-leader ()
  "The environment leader exposes reload, allow and log commands."
  (skip-unless (featurep 'init-evil))
  (require 'evil)
  (with-temp-buffer
    (setq-local envrc-mode t)
    (evil-local-mode 1)
    (evil-normal-state)
    (should (eq (key-binding (kbd "SPC E r")) 'envrc-reload))
    (should (eq (key-binding (kbd "SPC E a")) 'envrc-allow))
    (should (eq (key-binding (kbd "SPC E l")) 'envrc-show-log))
    (should (eq (key-binding (kbd "C-c E r")) 'envrc-reload))))

(ert-deftest lang-eglot-evil-leader ()
  "SPC l mirrors the native C-c l language server keys."
  (skip-unless (featurep 'init-evil))
  (require 'evil)
  (with-temp-buffer
    (setq-local eglot--managed-mode t)
    (evil-local-mode 1)
    (dolist (state '(normal motion visual))
      (evil-change-state state)
      (dolist (binding '(("a" . eglot-code-actions) ("r" . eglot-rename)
                         ("f" . eglot-format-buffer)))
        (should (eq (key-binding (kbd (concat "SPC l " (car binding))))
                    (cdr binding)))
        (should (eq (key-binding (kbd (concat "C-c l " (car binding))))
                    (cdr binding)))))
    (evil-insert-state)
    (should (eq (key-binding (kbd "SPC")) 'self-insert-command))))

(provide 'lang-test)
;;; lang-test.el ends here
