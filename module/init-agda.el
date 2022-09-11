;;; -*- lexical-binding: t -*-

(leaf agda-input
  :straight (agda-input
             :host github
             :repo "agda/agda"
             :files ("src/data/emacs-mode/agda-input.el")))

(leaf agda2-mode
  :straight (agda2-mode
             :host github :repo "agda/agda"
             :files ("src/data/emacs-mode/*.el"
                     (:exclude "agda-input.el"))))

(provide 'init-agda)
