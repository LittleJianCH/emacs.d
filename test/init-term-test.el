;;; init-term-test.el --- Tests for the terminal module -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-term-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'project)

(defvar ghostel-module-directory)
(defvar ghostel-shell)
(defvar ghostel-tramp-shells)

(defmacro init-term-test--with-shell (system shell &rest body)
  "Run BODY with `system-type' SYSTEM and $SHELL set to SHELL (nil: unset)."
  (declare (indent 2))
  `(let ((system-type ,system)
         (process-environment (cons (if ,shell (concat "SHELL=" ,shell) "SHELL")
                                    process-environment)))
     ,@body))

(ert-deftest init-term-shell-avoids-macos-bash ()
  "macOS's /bin/bash 3.2 ignores ghostel's integration, so zsh replaces it.
Other login shells, including bash elsewhere, are used as they are."
  (init-term-test--with-shell 'darwin "/bin/bash"
    (should (equal (my/term-shell) "/bin/zsh")))
  (init-term-test--with-shell 'darwin "/opt/homebrew/bin/bash"
    (should (equal (my/term-shell) "/opt/homebrew/bin/bash")))
  (init-term-test--with-shell 'gnu/linux "/bin/bash"
    (should (equal (my/term-shell) "/bin/bash")))
  (init-term-test--with-shell 'darwin nil
    (should (equal (my/term-shell) "/bin/sh"))))

(ert-deftest init-term-ghostel-settings ()
  "Settings applied once ghostel loads (`:custom' waits for its defcustoms).
The native module lives under var/, outside the package directory, and
tramp-rpc hosts start their login shell."
  (require 'ghostel)
  (should (file-in-directory-p ghostel-module-directory my/var-dir))
  (should (equal ghostel-shell (my/term-shell)))
  (should (equal (assoc "rpc" ghostel-tramp-shells) '("rpc" login-shell))))

(ert-deftest init-term-keys ()
  "C-c t opens a terminal.  telega moved to C-c T: it loads after
init-term, so binding C-c t too would silently take the key back."
  (should (eq (keymap-lookup global-map "C-c t") #'ghostel))
  (should (keymap-lookup global-map "C-c T")))

(ert-deftest init-term-project-terminal ()
  "Projects open a terminal with C-x p t and from `project-switch-project'."
  (should (eq (keymap-lookup project-prefix-map "t") #'ghostel-project))
  (should (assq 'ghostel-project project-switch-commands)))

;;; init-term-test.el ends here
