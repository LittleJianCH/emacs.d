;;; init-base-test.el --- Tests for init-base -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-base-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

(ert-deftest init-base-evil-keybinding-preset ()
  "evil's integration settings are set before evil can load by any path.
evil-collection warns when evil loaded with `evil-want-keybinding' on,
e.g. after a plain M-x evil-mode autoloaded it without init-evil."
  (should (default-value 'evil-want-integration))
  (should-not (default-value 'evil-want-keybinding)))

(ert-deftest init-base-truncates-code-lines ()
  "Code and config buffers truncate long lines; prose wraps."
  (with-temp-buffer
    (emacs-lisp-mode)
    (should truncate-lines))
  (with-temp-buffer
    (conf-unix-mode)
    (should truncate-lines))
  (when (fboundp 'toml-ts-mode)
    (with-temp-buffer
      ;; Hooks run even when the grammar is missing.
      (ignore-errors (toml-ts-mode))
      (should truncate-lines)
      (should-not visual-line-mode)))
  (with-temp-buffer
    (text-mode)
    (should-not truncate-lines)
    (should visual-line-mode)))

(provide 'init-base-test)
;;; init-base-test.el ends here
