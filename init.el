;; if init-private.el exsists, load it
(when (file-exists-p (expand-file-name "module/init-private.el" user-emacs-directory))
  (require 'init-private))

(require 'init-meow)
(require 'init-laf)

(require 'init-app)
(require 'init-lang)
