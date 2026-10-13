;;; init-ui.el --- 主题、字体、窗口 -*- lexical-binding: t; -*-

;; 内置 Modus 主题；浅色可改为 modus-operandi。
(setq modus-themes-mixed-fonts t
      modus-themes-bold-constructs t)
(load-theme 'modus-vivendi t)

;;; 字体：从候选中选第一个已安装的

(defun my/first-font (fonts)
  "返回 FONTS 中第一个已安装的字体名。"
  (seq-find (lambda (f) (find-font (font-spec :family f))) fonts))

(defun my/setup-fonts (&optional frame)
  "为 FRAME 设置等宽字体与中文字体。"
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

;;; 交互细节

(when (display-graphic-p)
  (pixel-scroll-precision-mode 1))
(blink-cursor-mode -1)
(setq-default cursor-in-non-selected-windows nil)

;; 左右分屏比上下分屏更适合“代码 | agent”的布局。
(setq split-width-threshold 140
      split-height-threshold nil
      window-combination-resize t)

;; C-c <left> / C-c <right> 撤销 / 重做窗口布局变化。
(winner-mode 1)
(keymap-global-set "M-o" #'other-window)

(use-package which-key
  :demand t
  :custom (which-key-idle-delay 0.4)
  :config (which-key-mode 1))

(provide 'init-ui)
;;; init-ui.el ends here
