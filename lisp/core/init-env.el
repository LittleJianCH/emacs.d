;;; init-env.el --- Project-local development environments -*- lexical-binding: t; -*-

;;; Commentary:

;; direnv evaluates approved .envrc files asynchronously.  Keep environments
;; buffer-local and notify language modules once tools become available.

;;; Code:

(defvar envrc-mode)
(defvar envrc--running)
(defvar envrc--status)
(defvar my/environment-ready-hook nil
  "Hook run in a buffer after its project environment has been applied.")
(defvar my/environment--notifying nil)

(declare-function envrc-global-mode "envrc")
(declare-function envrc-mode "envrc")

(defun my/environment-ready-p ()
  "Return non-nil when this buffer's environment is ready for tools."
  (or (not (bound-and-true-p envrc-mode))
      (and (not envrc--running) (memq envrc--status '(on none)))))

(defun my/environment-applied (buffer result)
  "Notify language modules after envrc applies RESULT to BUFFER."
  (when (and (buffer-live-p buffer)
             (or (listp result) (eq result 'none))
             (not my/environment--notifying))
    (with-current-buffer buffer
      (let ((my/environment--notifying t))
        (run-hooks 'my/environment-ready-hook)))))

(defun my/environment-enable ()
  "Enable project environments when direnv is available."
  (when (executable-find "direnv")
    (envrc-global-mode 1)))

(use-package envrc
  :ensure t
  :demand t
  :custom
  (envrc-async t)
  (envrc-show-summary-in-minibuffer nil)
  :bind (:map envrc-mode-map
         ("C-c E" . envrc-command-map))
  :config
  ;; envrc currently has no public environment-change hook.
  (advice-add 'envrc--apply :after #'my/environment-applied)
  (add-hook 'after-init-hook #'my/environment-enable 90)
  (when (and after-init-time (not noninteractive))
    (my/environment-enable)))


(declare-function evil-define-key* "evil-core")
(defvar envrc-mode-map)
(defvar envrc-command-map)

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion visual) envrc-mode-map
    (kbd "<leader>E") envrc-command-map))

(provide 'init-env)
;;; init-env.el ends here
