;;; -*- lexical-binding: t -*-

(straight-use-package 'magit)

(meow-leader-define-key '("a m" . magit))

(provide 'init-magit)
