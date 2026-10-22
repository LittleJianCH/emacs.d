;;; init-evil.el --- Vim keybindings (evil) -*- lexical-binding: t; -*-

;;; Commentary:

;; evil + evil-collection (Vim keys for common modes like magit, dired, help).
;; The leader key is SPC (in normal / motion state):
;;   SPC f  find file       SPC b  switch buffer    SPC r  recent files
;;   SPC s  search buffer   SPC /  search project   SPC p  project commands
;;   SPC a  agent commands (same as C-c a)
;;   SPC w  window commands SPC u  prefix argument (C-u scrolls up)
;;   SPC t  terminal (same as C-c t, init-term.el)
;;   SPC g g  magit status  SPC g b  toggle per-line blame (magit-blame)
;; C-j / C-k move point and the text together, a line at a time, so point
;; stays where it is on the screen.
;; Insert state uses Emacs editing keys; Escape returns to normal state.
;; evil is not enabled in the minibuffer, which keeps normal editing.
;;
;; Whether it loads is controlled by `my/use-evil' in init-base.el (on by
;; default); toggle at runtime with M-x my/toggle-evil, and with a C-u prefix
;; argument also save that as the default.

;;; Code:

;; evil isn't loaded at compile time, so declare its functions for the
;; byte-compiler (they are loaded along with evil at runtime).
(declare-function evil-set-leader "evil-core")
(declare-function evil-define-key* "evil-core")
(declare-function global-evil-pinyin-mode "evil-pinyin")
(declare-function evil-pinyin--get-char-table "evil-pinyin")
(defvar evil-pinyin-scheme)
(defvar magit-mode-map)
(defvar magit-blame-read-only-mode-map)

(defun my/evil-pinyin--microsoft-char-table ()
  "Copy upstream's Microsoft table, grouping zero initials under o."
  (let* ((evil-pinyin-scheme 'simplified-weiruan-all)
         (table (copy-sequence (evil-pinyin--get-char-table))))
    (setf (nth (- ?o ?a) table)
          (concat (nth 0 table) (nth (- ?e ?a) table)
                  (nth (- ?o ?a) table))
          (nth 0 table) ""
          (nth (- ?e ?a) table) "")
    table))

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
  ;; Apply after Evil initializes its keymaps, including during hot reload.
  (customize-set-variable 'evil-disable-insert-state-bindings t)
  (evil-mode 1)
  (evil-set-leader '(normal motion visual) (kbd "SPC"))
  (evil-define-key '(normal motion visual) 'global
    (kbd "<leader>f") #'find-file
    (kbd "<leader>b") #'consult-buffer
    (kbd "<leader>r") #'consult-recent-file
    (kbd "<leader>s") #'consult-line
    (kbd "<leader>/") #'consult-ripgrep
    (kbd "<leader>p") project-prefix-map
    (kbd "<leader>gg") #'magit-status
    (kbd "<leader>gb") #'my/magit-blame-toggle
    (kbd "<leader>w") evil-window-map
    (kbd "<leader>u") #'universal-argument
    (kbd "<leader>h") help-map
    (kbd "<leader>i") #'my/open-init-file
    (kbd "C-j") #'my/scroll-down-with-point
    (kbd "C-k") #'my/scroll-up-with-point))

(with-eval-after-load 'evil
  (use-package evil-pinyin
    :ensure t
    :demand t
    :init
    (setq-default evil-pinyin-scheme nil
                  evil-pinyin-with-search-rule 'never
                  evil-pinyin-with-punctuation nil)
    :config
    (setq-default evil-pinyin-char-table
                  (my/evil-pinyin--microsoft-char-table))
    (global-evil-pinyin-mode 1))
  ;; SPC w and C-w share the window map.
  (define-key evil-window-map (kbd "u") #'winner-undo)
  (define-key evil-window-map (kbd "U") #'winner-redo))

(use-package evil-collection
  :ensure t
  :after evil
  :demand t
  :custom
  (evil-collection-want-unimpaired-p nil)
  :config
  (evil-collection-init))

;; evil-collection makes magit's maps override normal state, so their SPC
;; (show the commit, scroll) shadows the leader, also in blamed file buffers.
;; Give SPC back to the leader there; RET and S-SPC still show the commit.
(with-eval-after-load 'evil-collection-magit
  (dolist (map (list magit-mode-map magit-blame-read-only-mode-map))
    (evil-define-key* '(normal visual) map (kbd "SPC")
                      `(menu-item "" nil :filter
                                  ,(lambda (_) (key-binding [leader]))))))

(provide 'init-evil)
;;; init-evil.el ends here
