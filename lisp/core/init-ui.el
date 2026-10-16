;;; init-ui.el --- Theme, fonts, windows -*- lexical-binding: t; -*-

;; Nano-style light / dark themes, following the macOS appearance.
(require 'init-theme)

;;; Fonts: pick the first installed candidate

(defun my/first-font (fonts)
  "Return the first font family in FONTS that is installed."
  (seq-find (lambda (f) (find-font (font-spec :family f))) fonts))

(defun my/setup-fonts (&optional frame)
  "Set up the monospace and CJK fonts for FRAME."
  (with-selected-frame (or frame (selected-frame))
    (when (display-graphic-p)
      (when-let* ((mono (my/first-font '("JetBrains Mono" "Roboto Mono" "SF Mono"
                                         "Iosevka" "Fira Code" "Menlo"))))
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

;;; Layout: wide margins, windows separated by space (nano)

;; The frame margin itself is set in early-init.el, before the first frame;
;; this keeps reloads and frames made later in line.
(defconst my/frame-margin 24 "Pixels between the frame edge and its windows.")
(dolist (frame (frame-list))
  (unless (frame-parent frame)
    (set-frame-parameter frame 'internal-border-width my/frame-margin)))

;; Side-by-side windows get a gap as wide as the margin; the theme draws the
;; dividers in the background color.  Stacked windows are separated by their
;; mode lines.
(setq window-divider-default-right-width my/frame-margin
      window-divider-default-places 'right-only)
(window-divider-mode 1)

;; The title bar is transparent; show just the buffer name, without the icon.
(setq frame-title-format '("%b")
      ns-use-proxy-icon nil)

;; Underlines sit at the descent line instead of crossing descenders.
(setq x-underline-at-descent-line t)

;;; Status line: nano's header line, kept at the bottom
;;
;;   [N] init-ui.el  Elisp · main                       eglot  12:4
;;
;; The tag shows the evil state (or RW / RO without evil); its color is the
;; buffer state: accent when clean, popout when modified, faded when read-only.
;; Buffers with their own mode line (agent sessions) keep it.

(defvar flymake-mode-line-counters)
(defvar evil-mode-line-format)

(defun my/mode-line-tag ()
  "Status tag of the current buffer for the mode line."
  (let ((label (if (bound-and-true-p evil-local-mode)
                   (pcase (bound-and-true-p evil-state)
                     ('normal "N") ('insert "I") ('visual "V") ('replace "R")
                     ('operator "O") ('motion "M") ('emacs "E") (_ "·"))
                 (cond (buffer-read-only "RO")
                       ((and (buffer-file-name) (buffer-modified-p)) "**")
                       (t "RW")))))
    (propertize label 'face
                (cond ((not (mode-line-window-selected-p)) 'my/nano-tag-inactive)
                      (buffer-read-only 'my/nano-tag-read-only)
                      ((and (buffer-file-name) (buffer-modified-p))
                       'my/nano-tag-modified)
                      (t 'my/nano-tag)))))

(defun my/mode-line-info ()
  "Secondary mode-line text: major mode, VC branch, diagnostics."
  (let ((parts (list (format-mode-line mode-name))))
    (when (and vc-mode (stringp vc-mode))
      (push (replace-regexp-in-string "\\` *[A-Za-z]+[-:@!?]" ""
                                      (substring-no-properties vc-mode))
            parts))
    (when (bound-and-true-p flymake-mode)
      ;; Only when there is something to report: "[0 0]" is noise.
      (let ((counters (string-trim (format-mode-line flymake-mode-line-counters))))
        (when (string-match-p "[1-9]" counters) (push counters parts))))
    (propertize (string-join (nreverse parts) " · ") 'face 'shadow)))

(setq-default
 mode-line-format
 '("%e" " "
   (:eval (my/mode-line-tag))
   " "
   (:eval (propertize (buffer-name) 'face
                      (if (mode-line-window-selected-p) 'mode-line-buffer-id 'bold)))
   "  "
   (:eval (my/mode-line-info))
   mode-line-process
   mode-line-format-right-align
   (:eval (propertize (string-trim (format-mode-line mode-line-misc-info))
                      'face 'shadow))
   "  "
   (:eval (propertize (format-mode-line "%l:%c") 'face 'shadow))
   "  "))

;; evil's own <N> tag is replaced by the status tag.
(setq evil-mode-line-format nil)

;;; Side panels: a tinted background sets them apart from the editing area

(defun my/nano-sidebar ()
  "Draw this buffer as a side panel: tinted, without a mode line.
A panel's status line would only repeat its buffer name."
  (face-remap-add-relative 'default 'my/nano-sidebar)
  (face-remap-add-relative 'fringe 'my/nano-sidebar)
  (setq mode-line-format nil))

(add-hook 'agent-session-list-mode-hook #'my/nano-sidebar)
(add-hook 'agent-review-nav-mode-hook #'my/nano-sidebar)

;;; Documentation popups (eldoc-box, when used): a padded card

(defvar eldoc-box-frame-parameters)
(with-eval-after-load 'eldoc-box
  ;; The theme draws the border in the card's own color, so the border is
  ;; padding; the left fringe is a character wide, the right one matches.
  (setf (alist-get 'internal-border-width eldoc-box-frame-parameters) 10
        (alist-get 'right-fringe eldoc-box-frame-parameters) 8)
  (setopt eldoc-box-max-pixel-width 720))

;;; Interaction details

(when (display-graphic-p)
  (pixel-scroll-precision-mode 1))
(blink-cursor-mode -1)
(setq-default cursor-in-non-selected-windows nil)

;; Line numbers: no jitter while scrolling past line 99, 999, ...
(setq-default display-line-numbers-width 3
              display-line-numbers-grow-only t)

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
