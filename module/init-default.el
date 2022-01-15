;;; -*- lexical-binding: t -*-

(setq-default
 inhibit-startup-message t

 tab-width 4 ; can be overrided by major mode
 indent-tabs-mode nil ; indent with whitespace
 
 ;; backup setups
 backup-directory-alist `(("." . "~/.emacs.saves"))
 backup-by-copying t
 delete-old-versions t
 kept-new-versions 6
 kept-old-versions 2

 display-line-numbers-width 3

 custom-file (expand-file-name "custom.el" user-emacs-directory)

 y-or-n-p-use-read-key t)

(fset 'yes-or-no-p 'y-or-n-p)


(provide 'init-default)
