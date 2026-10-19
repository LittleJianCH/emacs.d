;;; lang-agda.el --- Agda interactive development -*- lexical-binding: t; -*-

;;; Commentary:

;; Load the Emacs mode shipped with the project's Agda after envrc has
;; supplied its PATH and AGDA_DIR.  Nix evaluation stays asynchronous.
;; Literate Markdown uses Polymode with the same Agda mode in code blocks.
;;
;; Native Agda keys:
;;   C-c C-l    load / type-check the buffer
;;   C-c C-,    show the goal and context
;;   C-c C-c    split cases
;;   C-c C-SPC  fill the goal
;; The Agda input method provides Unicode input, e.g. \lambda and \to.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'init-env)
(require 'inheritenv)
(require 'eieio)

(declare-function agda2-mode "agda2-mode")
(declare-function poly-markdown-mode "poly-markdown")
(defvar polymode-mode-name-aliases)
(defvar pm/chunkmode)
(defvar markdown-fontify-code-blocks-natively)
(defvar envrc-global-mode)
(defvar-local my/agda-waiting-for-environment nil)

(defconst my/agda-file-pattern
  "\\.\\(?:agda\\|lagda\\(?:\\.\\(?:md\\|rst\\|tex\\|org\\|typ\\|tree\\)\\)?\\)\\'"
  "Pattern for Agda source files, including literate variants.")

(defun my/agda-register-mode ()
  "Keep the environment-aware loader ahead of Agda's own file rules."
  (let ((entry (cons my/agda-file-pattern #'my/agda-mode)))
    (setq auto-mode-alist (cons entry (delete entry auto-mode-alist)))))

(defun my/agda-mode-file ()
  "Locate the Emacs mode belonging to the current environment's Agda.
Try the current command first, then the pre-2.8 helper."
  ;; Preserve buffer-local environment variables in the temporary buffers.
  ;; Lisp loads locally even when the source file is remote.
  (let ((default-directory (expand-file-name "~"))
        (saved-env process-environment)
        (saved-path exec-path))
    (or (seq-some
         (lambda (command)
           (when (executable-find (car command))
             (with-temp-buffer
               (setq-local process-environment saved-env
                           exec-path saved-path)
               (let ((coding-system-for-read 'utf-8))
                 (when (eq 0 (apply #'process-file (car command) nil
                                    (list t nil) nil (cdr command)))
                   (let ((file (string-trim (buffer-string))))
                     (when (and (file-name-absolute-p file)
                                (file-readable-p file))
                       file)))))))
         '(("agda" "--emacs-mode" "locate") ("agda-mode" "locate")))
        (user-error "未找到 Agda Emacs 模式；请检查项目环境和 Agda 安装"))))

(defun my/agda-activate ()
  "Enter Agda's mode without losing the current project environment."
  (let ((saved-env process-environment)
        (saved-path exec-path))
    (unless (fboundp 'agda2-mode)
      (let ((file (my/agda-mode-file)))
        (add-to-list 'load-path (file-name-directory file))
        (load file nil t)
        (my/agda-register-mode)))
    ;; New mode initialization needs the project env, including in temp
    ;; buffers.  Suspend envrc while inheritenv changes global defaults so
    ;; it cannot cache a diff against this temporary baseline.
    (cl-letf (((symbol-function 'envrc-mode) #'ignore))
      (inheritenv
        (if (and buffer-file-name
                 (string-suffix-p ".lagda.md" buffer-file-name)
                 (not (buffer-base-buffer)))
            (poly-markdown-mode)
          (agda2-mode))))
    (setq-local process-environment saved-env)
    (setq-local exec-path saved-path)
    (when (bound-and-true-p envrc-global-mode)
      (envrc-mode 1))))

(defun my/agda-polymode-environment (original mode &optional buffer)
  "Give Polymode's Agda MODE the host environment before ORIGINAL runs.
BUFFER is the optional target buffer passed to Polymode's mode setup."
  (with-current-buffer (or buffer (current-buffer))
    (let ((base (buffer-base-buffer)))
      (if (and (eq mode 'agda2-mode) base)
          (let ((saved-env (buffer-local-value 'process-environment base))
                (saved-path (buffer-local-value 'exec-path base)))
            (setq-local process-environment saved-env exec-path saved-path)
            ;; Agda starts its compiler before mode hooks and highlighting
            ;; setup.  Inherit through major-mode resets and temp buffers.
            (prog1 (cl-letf (((symbol-function 'envrc-mode) #'ignore))
                     (inheritenv (funcall original mode buffer)))
              (setq-local process-environment saved-env exec-path saved-path)))
        (funcall original mode buffer)))))

(defun my/agda-markdown-setup ()
  "Protect Agda annotations and use theme-aware code backgrounds."
  (when (and buffer-file-name
             (string-suffix-p ".lagda.md" buffer-file-name))
    (if (buffer-base-buffer)
        (when (eq major-mode 'agda2-mode)
          ;; Numeric offsets bake the current theme's RGB into the text.
          ;; A named face follows theme changes without refontification.
          (setf (slot-value pm/chunkmode 'adjust-face) 'markdown-code-face))
      (setq-local markdown-fontify-code-blocks-natively nil)
      (setf (slot-value pm/chunkmode 'protect-font-lock) t))))

(use-package poly-markdown
  :ensure t
  :commands poly-markdown-mode
  :config
  (add-to-list 'polymode-mode-name-aliases '(agda . agda2-mode))
  (add-hook 'poly-markdown-mode-hook #'my/agda-markdown-setup)
  (advice-add 'pm--mode-setup :around #'my/agda-polymode-environment))

(defun my/agda-environment-ready ()
  "Activate a waiting Agda buffer when its project environment is ready."
  (when (and my/agda-waiting-for-environment (my/environment-ready-p))
    (setq my/agda-waiting-for-environment nil)
    (condition-case err
        (my/agda-activate)
      (error (message "Agda 模式加载失败：%s" (error-message-string err))))))

(defun my/agda-mode ()
  "Wait for the project's environment, then enter Agda's bundled mode."
  (interactive)
  (prog-mode)
  (setq-local my/agda-waiting-for-environment t)
  (when (bound-and-true-p envrc-global-mode)
    (envrc-mode 1))
  (my/agda-environment-ready)
  (when my/agda-waiting-for-environment
    (message "正在等待 Agda 项目环境；若未授权，请运行 M-x envrc-allow")))

(add-hook 'my/environment-ready-hook #'my/agda-environment-ready)
;; Agda's process buffer also needs the calling buffer's AGDA_DIR and PATH.
(with-eval-after-load 'agda2-mode
  (advice-add 'agda2-go :around #'envrc-propagate-environment))
(my/agda-register-mode)


;;; Evil leader commands

(defvar agda2-mode-map)
(declare-function evil-define-key* "evil-core")
(declare-function my/agda-evil-keys "lang-agda")

(defvar-keymap my/agda-command-map
  :doc "Agda commands under the Evil major-mode leader."
  "l" 'agda2-load
  "c" 'agda2-goal-and-context
  "t" 'agda2-goal-and-context-and-inferred
  "s" 'agda2-make-case
  "g" 'agda2-give
  "r" 'agda2-refine
  "n" 'agda2-next-goal
  "p" 'agda2-previous-goal
  "R" 'agda2-restart
  "q" 'agda2-abort)

(with-eval-after-load 'evil
  (defun my/agda-evil-keys ()
    "Install Agda's major-mode leader in Evil command states."
    (evil-define-key* '(normal motion visual) agda2-mode-map
      (kbd "<leader>m") my/agda-command-map))
  (with-eval-after-load 'agda2-mode
    (my/agda-evil-keys)))

(provide 'lang-agda)
;;; lang-agda.el ends here
