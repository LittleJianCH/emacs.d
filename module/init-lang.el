;;; -*- lexical-binding: t -*-

(defun +complete ()
  (interactive)
  (or (copilot-accept-completion)
      (yas-expand)
      (company-indent-or-complete-common nil)))


;;; company
(leaf company
  :straight t
  :commands company-mode
  :hook prog-mode-hook eshell-mode-hook
  :bind ((:company-mode-map
          ("TAB" . +complete)
          ([tab] . +complete))
         (:company-active-map
          ("TAB" . company-complete-common-or-cycle)
          ([tab] . company-complete-common-or-cycle)
          ("RET" . nil)
          ([return] . nil)
          ("<C-return>" . company-complete-selection)))
          
  :config
  (delq 'company-preview-if-just-one-frontend company-frontends))


;;; yasnippet
(leaf yasnippet
  :straight t
  :after company
  :commands (yas-minor-mode yas-reload-all)
  :hook ((prog-mode-hook . yas-minor-mode)))

;;; copilot
(leaf copilot
  :straight
  '(copilot :host github
            :repo "zerolfx/copilot.el"
            :files ("dist" "*.el"))
  :hook prog-mode-hook)

(require 'init-coq)


(provide 'init-lang)

