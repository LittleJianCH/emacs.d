;;; init-ui.el --- Theme, fonts, windows -*- lexical-binding: t; -*-

;; Built-in light Leuven theme; the Modus options apply if switching back to
;; modus-operandi / modus-vivendi.
(setq modus-themes-mixed-fonts t
      modus-themes-bold-constructs t)
(load-theme 'leuven t)

;;; Fonts: pick the first installed candidate

(defun my/first-font (fonts)
  "Return the first font family in FONTS that is installed."
  (seq-find (lambda (f) (find-font (font-spec :family f))) fonts))

(defun my/setup-fonts (&optional frame)
  "Set up the monospace and CJK fonts for FRAME."
  (with-selected-frame (or frame (selected-frame))
    (when (display-graphic-p)
      (when-let* ((mono (my/first-font '("JetBrains Mono" "Iosevka" "Fira Code"
                                         "SF Mono" "Menlo"))))
        (set-face-attribute 'default nil :family mono :height 140)
        (set-face-attribute 'fixed-pitch nil :family mono))
      (when-let* ((cjk (my/first-font '("Sarasa Mono SC" "LXGW WenKai Mono"
                                        "PingFang SC" "Hiragino Sans GB"))))
        (dolist (charset '(han cjk-misc bopomofo kana))
          (set-fontset-font t charset (font-spec :family cjk))))
      (set-fontset-font t 'emoji (font-spec :family "Apple Color Emoji") nil 'prepend))))

(if (daemonp)
    (add-hook 'after-make-frame-functions #'my/setup-fonts)
  (my/setup-fonts))

;;; Interaction details

(when (display-graphic-p)
  (pixel-scroll-precision-mode 1))
(blink-cursor-mode -1)
(setq-default cursor-in-non-selected-windows nil)

;; Side-by-side splits suit a "code | agent" layout better than stacked ones.
(setq split-width-threshold 140
      split-height-threshold nil
      window-combination-resize t)

;; C-c <left> / C-c <right> undo / redo window layout changes.
(winner-mode 1)
(keymap-global-set "M-o" #'other-window)

(use-package which-key
  :demand t
  :custom (which-key-idle-delay 0.4)
  :config (which-key-mode 1))

(provide 'init-ui)
;;; init-ui.el ends here
