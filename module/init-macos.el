;;; -*- lexical-binding: t -*-

(straight-use-package 'osx-dictionary)

(global-set-key (kbd "C-c a d") 'osx-dictionary-search-word-at-point)

(provide 'init-macos)
