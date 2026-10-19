;;; init-term.el --- Terminal emulator (ghostel) -*- lexical-binding: t; -*-

;;; Commentary:

;; ghostel runs terminals on libghostty-vt, the engine of the Ghostty
;; terminal, loaded as a native module: fast output, true color, the Kitty
;; keyboard and graphics protocols, OSC 8 links, and shell integration
;; (directory tracking, prompt jumps) injected without rc file changes.
;;
;;   C-c t     terminal (C-u for a new one); SPC t with evil
;;   C-x p t   terminal in the project root (SPC p t); also `t' after C-x p p
;;
;; Most keys go to the shell.  C-c C-e shows the live terminal as a
;; read-only buffer with Emacs keys, C-c C-t freezes it for copying, and
;; C-c C-j comes back.  With evil, evil-ghostel starts terminals in insert
;; state; Escape goes to normal state unless a full-screen program runs.
;;
;; Building the module from source needs exactly Zig 0.16, so ghostel
;; downloads the prebuilt one from its GitHub releases into var/ on the
;; first M-x ghostel, and again when an upgraded ghostel needs a newer one.
;;
;; ghostel injects its bash integration with `bash --posix' and ENV, which
;; macOS's /bin/bash 3.2 ignores, so terminals there run /bin/zsh instead.
;; To keep bash, point `ghostel-shell' at a newer one (e.g. Homebrew's).

;;; Code:

(defun my/term-shell ()
  "Return the shell for ghostel terminals: the login shell.
macOS's /bin/bash 3.2 gets no shell integration from ghostel, so on
macOS a /bin/bash login shell is replaced with /bin/zsh."
  (let ((shell (or (getenv "SHELL") "/bin/sh")))
    (if (and (eq system-type 'darwin) (equal shell "/bin/bash"))
        "/bin/zsh"
      shell)))

(use-package ghostel
  :ensure t
  :bind ("C-c t" . ghostel)
  :custom
  (ghostel-shell (my/term-shell))
  ;; Outside the package directory, so an upgrade doesn't delete the module
  ;; while it is loaded.
  (ghostel-module-directory (my/var "ghostel/"))
  (ghostel-module-auto-install 'download)
  :config
  ;; Remote projects use tramp-rpc (init-remote.el): start the host's login
  ;; shell, as ghostel does for ssh.
  (add-to-list 'ghostel-tramp-shells '("rpc" login-shell)))

(with-eval-after-load 'project
  (keymap-set project-prefix-map "t" #'ghostel-project)
  (add-to-list 'project-switch-commands '(ghostel-project "Terminal" ?t) t))

;; evil may be turned off (see `my/use-evil'); declare it for the compiler.
(declare-function evil-define-key* "evil-core")

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion visual) 'global
    (kbd "<leader>t") #'ghostel)
  (use-package evil-ghostel
    :ensure t
    :hook (ghostel-mode . evil-ghostel-mode)))

(provide 'init-term)
;;; init-term.el ends here
