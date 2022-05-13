;;; -*- lexical-binding: t -*-

(leaf magit
  :straight t
  :commands magit
  :init (meow-leader-define-key '("a m" . magit)))

(provide 'init-magit)
