;;; -*- lexical-binding: t -*-

(straight-use-package 'company)
(straight-use-package 'yasnippet)


(defun +complete ()
  (interactive)
  (or (yas-expand)
      (company-indent-or-complete-common nil)))


;;; company
(autoload #'company-mode "company")

(dolist (hook '(prog-mode-hook
                eshell-mode-hook))
  (add-hook hook #'company-mode))

(with-eval-after-load "company"
  (define-key company-mode-map (kbd "TAB") '+complete)
  (define-key company-mode-map [tab] '+complete)
  (define-key company-active-map (kbd "TAB") 'company-complete-common-or-cycle)
  (define-key company-active-map [tab] 'company-complete-common-or-cycle)
  (define-key company-active-map (kbd "RET") nil)
  (define-key company-active-map [return] nil)
  (define-key company-active-map (kbd "<C-return>") 'company-complete-selection))


;;; yasnippet
(autoload #'yas-minor-mode "yasnippet")

(add-hook 'prog-mode-hook #'yas-minor-mode)

(with-eval-after-load "yasnippet"
  (yas-reload-all))


(require 'init-coq)


(provide 'init-lang)