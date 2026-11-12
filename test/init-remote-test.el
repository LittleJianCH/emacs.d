;;; init-remote-test.el --- Tests for init-remote -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-remote-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'autorevert)

(ert-deftest init-remote-global-auto-revert-skips-remote-buffers ()
  "Global Auto-Revert never adopts remote buffers, even after a mode change.
Remote files are never reverted, yet each adopted remote buffer cost
several tramp calls on every one-second poll."
  (let ((global-auto-revert-non-file-buffers nil))
    (with-temp-buffer
      ;; file-remote-p only parses the name; nothing connects.
      (setq default-directory "/ssh:example.invalid:/tmp/"
            buffer-file-name "/ssh:example.invalid:/tmp/a.txt")
      (auto-revert--global-add-current-buffer)
      (should-not auto-revert--global-mode)
      (text-mode)
      (setq buffer-file-name "/ssh:example.invalid:/tmp/a.txt")
      (auto-revert--global-add-current-buffer)
      (should-not auto-revert--global-mode)
      (setq buffer-file-name nil))
    (with-temp-buffer
      (setq default-directory temporary-file-directory
            buffer-file-name (expand-file-name "a.txt" temporary-file-directory))
      (auto-revert--global-add-current-buffer)
      (should auto-revert--global-mode)
      (setq buffer-file-name nil))))

(provide 'init-remote-test)
;;; init-remote-test.el ends here
