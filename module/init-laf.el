;;; -*- lexical-binding: t -*-

(straight-use-package 'one-themes)
(straight-use-package 'rainbow-delimiters)


(scroll-bar-mode -1)
(menu-bar-mode -1)
(tool-bar-mode -1)

;; theme
(load-theme 'one-light t)

;; font
(set-frame-font "Menlo-16" t t)

;; rainbow-delimiters
(require 'rainbow-delimiters)
(add-hook 'prog-mode-hook #'rainbow-delimiters-mode-enable)

(provide 'init-laf)
