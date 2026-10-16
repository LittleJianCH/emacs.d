;;; init-base-test.el --- Tests for init-base -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-base-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

(defvar treesit-auto-install-grammar)

(ert-deftest init-base-evil-keybinding-preset ()
  "evil's integration settings are set before evil can load by any path.
evil-collection warns when evil loaded with `evil-want-keybinding' on,
e.g. after a plain M-x evil-mode autoloaded it without init-evil."
  (should (default-value 'evil-want-integration))
  (should-not (default-value 'evil-want-keybinding)))

(ert-deftest init-base-scroll-with-point ()
  "C-j / C-k scroll a line and move point with it, keeping its screen row.
Scrolling needs a real display: run it in the running Emacs."
  (skip-unless (not noninteractive))
  (save-window-excursion
    (with-temp-buffer
      (dotimes (i 100) (insert (format "line %d\n" i)))
      (switch-to-buffer (current-buffer))
      (let ((row (lambda () (count-screen-lines (window-start) (point))))
            (line (lambda () (line-number-at-pos))))
        (goto-char (point-min))
        (forward-line 20)
        (move-to-column 3)
        (set-window-start nil (save-excursion (forward-line -5) (point)))
        (let ((row0 (funcall row)))
          (my/scroll-down-with-point)
          (should (= (funcall line) 22))
          (should (= (funcall row) row0))
          (should (= (current-column) 3))
          (my/scroll-up-with-point 2)
          (should (= (funcall line) 20))
          (should (= (funcall row) row0)))
        ;; At the start the text can't scroll: only point moves.
        (goto-char (point-min))
        (forward-line 3)
        (set-window-start nil (point-min))
        (my/scroll-up-with-point)
        (should (= (funcall line) 3))
        (should (= (window-start) (point-min)))))))

(ert-deftest init-base-no-scroll-margin ()
  "No scroll margin, which makes touchpad scrolling jump back."
  (should (= (default-value 'scroll-margin) 0)))

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
      ;; Hooks run even when the grammar is missing, as long as nothing asks
      ;; to install it (a checkout without tree-sitter/, such as a worktree).
      (let ((treesit-auto-install-grammar nil))
        (ignore-errors (toml-ts-mode)))
      (should truncate-lines)
      (should-not visual-line-mode)))
  (with-temp-buffer
    (text-mode)
    (should-not truncate-lines)
    (should visual-line-mode)))

(provide 'init-base-test)
;;; init-base-test.el ends here
