;;; init-remote.el --- Remote editing -*- lexical-binding: t; -*-

;; Remote files go through tramp-rpc: use /rpc:dev:/path instead of /ssh:dev:/path.
;; A small Rust server runs on the remote host and Emacs talks MessagePack-RPC to it
;; over ssh instead of parsing shell output, so each round trip costs far less and
;; git commands are prefetched in batches.  The server binary is downloaded from
;; GitHub Releases on first connection and deployed to ~/.cache/emacs/tramp-rpc/.

(use-package tramp-rpc
  ;; Pinned to a release tag: the server protocol revision must match the Elisp
  ;; exactly, and the main branch often runs ahead of the released binaries.
  ;; Bump the tag here to upgrade.
  :vc (:url "https://github.com/ArthurHeymans/emacs-tramp-rpc"
       :rev "v0.15.0"
       :lisp-dir "lisp")
  :defer t                              ; the package autoloads register the rpc method
  :custom
  ;; Git installs don't fetch a server binary by default; use the release binary
  ;; so the first connection downloads and deploys it automatically.
  (tramp-rpc-deploy-git-build-policy 'release)
  (tramp-rpc-deploy-local-cache-directory (my/var "tramp-rpc/")))

(provide 'init-remote)
;;; init-remote.el ends here
