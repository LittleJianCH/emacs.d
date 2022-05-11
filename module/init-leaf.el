;;; -*- lexical-binding: t -*-

(eval-and-compile
  (straight-use-package 'leaf)
  (straight-use-package 'leaf-keywords)

  (require 'leaf)
  (require 'leaf-keywords)
  (leaf-keywords-init))


(provide 'init-leaf)
