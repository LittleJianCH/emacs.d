;;; init-remote-test.el --- Tests for init-remote -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-remote-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'autorevert)

(ert-deftest init-remote-no-vc-polling-after-mode-change ()
  "Remote buffers keep VC polling off when their major mode is re-run.
A mode change kills buffer-local variables; a remote buffer that lost
the setting ran `vc-refresh-state' over the network every second."
  (with-temp-buffer
    ;; file-remote-p only parses the name; nothing connects.
    (setq default-directory "/ssh:example.invalid:/tmp/")
    (my/remote-buffer-setup)
    (should-not auto-revert-check-vc-info)
    (text-mode)
    (should (local-variable-p 'auto-revert-check-vc-info))
    (should-not auto-revert-check-vc-info))
  (with-temp-buffer
    (setq default-directory temporary-file-directory)
    (text-mode)
    (should-not (local-variable-p 'auto-revert-check-vc-info))))

(provide 'init-remote-test)
;;; init-remote-test.el ends here
