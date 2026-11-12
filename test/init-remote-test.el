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

(defun init-remote-test--server (root buffer)
  "Return an eglot server for project ROOT managing BUFFER, without a process."
  (require 'eglot)
  (let ((server (make-instance 'eglot-lsp-server
                               :process (make-pipe-process
                                         :name "init-remote-test" :noquery t))))
    (setf (eglot--project server) (cons 'transient root)
          ;; As after connecting, with `eglot-autoreconnect' allowing it.
          (eglot--inhibit-autoreconnect server) nil)
    (push buffer (eglot--managed-buffers server))
    server))

(ert-deftest init-remote-eglot-remote-server-lost ()
  "A remote server dying with its connection marks its buffers, no reconnect.
eglot reconnected at once while offline, failed and gave up for good."
  (with-temp-buffer
    (let ((server (init-remote-test--server "/ssh:example.invalid:/tmp/"
                                            (current-buffer))))
      (unwind-protect
          (progn
            (my/eglot--server-lost server)
            (should my/eglot--lost)
            (should (eq (eglot--inhibit-autoreconnect server) t)))
        (delete-process (jsonrpc--process server)))))
  ;; Asked to shut down: nothing to restart.
  (with-temp-buffer
    (let ((server (init-remote-test--server "/ssh:example.invalid:/tmp/"
                                            (current-buffer))))
      (unwind-protect
          (progn
            (setf (eglot--shutdown-requested server) t)
            (my/eglot--server-lost server)
            (should-not my/eglot--lost))
        (delete-process (jsonrpc--process server)))))
  ;; Local servers keep eglot's own reconnection.
  (with-temp-buffer
    (let ((server (init-remote-test--server temporary-file-directory
                                            (current-buffer))))
      (unwind-protect
          (progn
            (my/eglot--server-lost server)
            (should-not my/eglot--lost)
            (should-not (eglot--inhibit-autoreconnect server)))
        (delete-process (jsonrpc--process server))))))

(ert-deftest init-remote-eglot-shutdown-skips-reconnect ()
  "Through eglot's own shutdown, a lost remote server neither warns nor
reconnects."
  (with-temp-buffer
    (let ((server (init-remote-test--server "/ssh:example.invalid:/tmp/"
                                            (current-buffer)))
          (reconnects 0) warnings)
      (unwind-protect
          (cl-letf (((symbol-function 'eglot-reconnect)
                     (lambda (_server) (cl-incf reconnects)))
                    ((symbol-function 'eglot--warn)
                     (lambda (format &rest args)
                       (push (apply #'format format args) warnings))))
            (eglot--on-shutdown server)
            (should (= reconnects 0))
            (should-not warnings)
            (should my/eglot--lost))
        (delete-process (jsonrpc--process server))))))

(ert-deftest init-remote-eglot-restarts-once-connected ()
  "A buffer that lost its server restarts it only once connected again."
  (with-temp-buffer
    (let ((connected nil) (ensured 0))
      (cl-letf (((symbol-function 'my/eglot--connected-p) (lambda () connected))
                ((symbol-function 'eglot-ensure) (lambda () (cl-incf ensured))))
        (my/eglot--restart-lost)
        (should (= ensured 0))
        (setq my/eglot--lost t)
        (my/eglot--restart-lost)
        (should (= ensured 0))
        (should my/eglot--lost)
        (setq connected t)
        (my/eglot--restart-lost)
        (should (= ensured 1))
        (should-not my/eglot--lost)
        (my/eglot--restart-lost)
        (should (= ensured 1))))))

(provide 'init-remote-test)
;;; init-remote-test.el ends here
