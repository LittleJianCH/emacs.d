;;; init-evil.el --- Vim keybindings (evil) -*- lexical-binding: t; -*-

;;; Commentary:

;; evil + evil-collection (Vim keys for common modes like magit, dired, help).
;; The leader key is SPC (in normal / motion state):
;;   SPC f  find file       SPC b  switch buffer    SPC r  recent files
;;   SPC s  search buffer   SPC /  search project   SPC p  project commands
;;   SPC g  magit           SPC a  agent commands (same as C-c a)
;;   SPC w  window commands SPC u  prefix argument (C-u scrolls up)
;; evil is not enabled in the minibuffer, which keeps normal editing.
;;
;; Whether it loads is controlled by `my/use-evil' in init-base.el (off by
;; default); toggle at runtime with M-x my/toggle-evil, and with a C-u prefix
;; argument also save that as the default.

;;; Code:

;; evil isn't loaded by default, so declare its functions for the byte-compiler
;; (they are loaded along with evil at runtime).
(declare-function evil-set-leader "evil-core")
(declare-function evil-define-key* "evil-core")

(use-package evil
  :ensure t
  ;; 1.15.0 from NonGNU signals void-variable evil-mode-buffers on Emacs 31
  ;; (Emacs 31 global minor modes no longer define MODE-buffers); fixed on MELPA.
  :pin melpa
  :demand t
  ;; `evil-want-keybinding' is set to nil in init-base.el, before evil can load.
  :custom
  (evil-want-C-u-scroll t)
  (evil-want-C-i-jump nil)
  (evil-undo-system 'undo-redo)
  (evil-respect-visual-line-mode t)
  (evil-split-window-below t)
  (evil-vsplit-window-right t)
  (evil-symbol-word-search t)
  :config
  (evil-mode 1)
  (evil-set-leader '(normal motion visual) (kbd "SPC"))
  (evil-define-key '(normal motion visual) 'global
    (kbd "<leader>f") #'find-file
    (kbd "<leader>b") #'consult-buffer
    (kbd "<leader>r") #'consult-recent-file
    (kbd "<leader>s") #'consult-line
    (kbd "<leader>/") #'consult-ripgrep
    (kbd "<leader>p") project-prefix-map
    (kbd "<leader>g") #'magit-status
    (kbd "<leader>w") evil-window-map
    (kbd "<leader>u") #'universal-argument
    (kbd "<leader>h") help-map
    (kbd "<leader>i") #'my/open-init-file))

(use-package evil-collection
  :ensure t
  :after evil
  :demand t
  :custom
  (evil-collection-want-unimpaired-p nil)
  :config
  (evil-collection-init))

;; Keep familiar Emacs line editing keys while entering text.
(with-eval-after-load 'evil
  (evil-define-key* 'insert 'global
    (kbd "C-a") #'move-beginning-of-line
    (kbd "C-e") #'move-end-of-line
    (kbd "C-k") #'kill-line))

(provide 'init-evil)
;;; init-evil.el ends here
