(add-to-list 'load-path (expand-file-name "module" user-emacs-directory))

(setq url-proxy-services
   '(("http" . "127.0.0.1:7890")
     ("https" . "127.0.0.1:7890")))

(require 'init-straight)
(require 'init-leaf)
(require 'init-default)
