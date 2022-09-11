;;; -*- lexical-binding: t -*-

(leaf proof-general
  :straight t
  :custom
  (coq-prog-name . "/opt/homebrew/bin/coqtop"))

(leaf company-coq
  :straight t
  :hook coq-mode-hook
  :config (company-coq-mode))

(provide 'init-coq)
