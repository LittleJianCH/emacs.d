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

;; Remote processes (eglot servers, compile, shell commands) get a plain non-login
;; PATH, missing tools installed under the home directory such as
;; ~/.cargo/bin/rust-analyzer.  Put the remote login shell's PATH first, so a
;; toolchain installed there (e.g. a gvm Go) wins over an older one in /usr/bin;
;; tramp-rpc fetches it once per connection.
(with-eval-after-load 'tramp
  (setq tramp-remote-path
        (cons 'tramp-own-remote-path
              (delq 'tramp-own-remote-path tramp-remote-path))))

;; Projects on dev keep their per-project settings (e.g. eglot workspace
;; configuration) in .dir-locals.el; read it for remote files too.  Costs a few
;; round trips when a file is visited, not while typing.
(setq enable-remote-dir-locals t)

;;; No synchronous remote calls on the typing path

;; Every remote call waits a full network round trip (30-300ms to dev), and Emacs
;; is single-threaded.  Same principle as VS Code: refresh remote state on events
;; such as visiting or saving a file, never by polling.

;; autorevert does not revert remote files (`auto-revert-remote-files' is nil),
;; but `auto-revert-check-vc-info' still runs `vc-refresh-state' on remote buffers
;; every second: a dozen remote calls per round, enough to keep Emacs busy in that
;; timer forever.  Remote buffers refresh VC state only when visited and saved.
(defun my/remote-buffer-setup ()
  "Turn off polling-style remote access in remote buffers."
  (when (file-remote-p default-directory)
    (setq-local auto-revert-check-vc-info nil)))
(add-hook 'find-file-hook #'my/remote-buffer-setup)

;; `vc-registered' tries every backend in turn, and on a remote file each attempt
;; is another network round trip.
(setq vc-handled-backends '(Git))

(provide 'init-remote)
;;; init-remote.el ends here
