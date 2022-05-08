;;; -*- lexical-binding: t -*-

(straight-use-package 'osx-dictionary)
(straight-use-package 'exec-path-from-shell)

(meow-leader-define-key '("a d" . osx-dictionary-search-word-at-point))

(exec-path-from-shell-initialize)

(provide 'init-macos)
