;;; -*- lexical-binding: t -*-

(straight-use-package 'osx-dictionary)

(meow-leader-define-key '("a d" . osx-dictionary-search-word-at-point))

(provide 'init-macos)
