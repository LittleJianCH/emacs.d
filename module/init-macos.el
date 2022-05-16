;;; -*- lexical-binding: t -*-

(leaf exec-path-from-shell
  :straight t
  :config (exec-path-from-shell-initialize))

(leaf osx-dictionary
  :straight t
  :commands (osx-dictionary-search-word-at-point
             osx-dictionary-search-input)
  :after exec-path-from-shell
  :init (meow-leader-define-key '("a d" . osx-dictionary-search-word-at-point)))

(provide 'init-macos)
