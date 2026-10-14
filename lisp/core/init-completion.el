;;; init-completion.el --- 补全与搜索 -*- lexical-binding: t; -*-

(use-package vertico
  :ensure t
  :demand t
  :custom (vertico-cycle t)
  :config (vertico-mode 1))

(use-package orderless
  :ensure t
  :demand t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

(use-package marginalia
  :ensure t
  :demand t
  :config (marginalia-mode 1))

(use-package consult
  :ensure t
  :bind (("C-s" . consult-line)
         ("C-x b" . consult-buffer)
         ("C-x 4 b" . consult-buffer-other-window)
         ("M-y" . consult-yank-pop)
         ("M-g g" . consult-goto-line)
         ("M-g i" . consult-imenu)
         ("M-g f" . consult-flymake)
         ("C-c r" . consult-ripgrep)
         ("C-c f" . consult-recent-file))
  :init
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref))

(use-package embark
  :ensure t
  :bind (("C-." . embark-act)
         ("C-h B" . embark-bindings)))

(use-package embark-consult
  :ensure t
  :after (embark consult))

(use-package corfu
  :ensure t
  :demand t
  :custom
  (corfu-auto t)
  (corfu-auto-delay 0.2)
  (corfu-auto-prefix 2)
  (corfu-cycle t)
  :config
  (global-corfu-mode 1)
  (corfu-history-mode 1)
  (corfu-popupinfo-mode 1))

(defun my/cape-dabbrev-english ()
  "只在英文单词处用 dabbrev 补全（至少 3 个字母）。
中文没有空格分词，dabbrev 会把整串汉字当成一个词，候选很乱，所以不补；
候选也只保留纯 ASCII 的词。"
  (when (and (looking-back "\\(?:^\\|[^[:alnum:]_]\\)[A-Za-z][A-Za-z0-9_-]\\{2,\\}"
                           (line-beginning-position))
             (require 'cape nil t))
    (funcall (cape-capf-predicate #'cape-dabbrev
                                  (lambda (candidate) (string-match-p "\\`[[:ascii:]]+\\'" candidate))))))

(use-package cape
  :ensure t
  :init
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'my/cape-dabbrev-english 90))

(provide 'init-completion)
;;; init-completion.el ends here
