;;; agent-remote.el --- Shared host transport helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; Host daemons use an ssh -L ControlMaster forward (agent-emx-remote.el).
;; This module only finds that master and copies user-supplied inputs.

;;; Code:
(require 'agent-session)
(require 'tramp)
(declare-function tramp-rpc--controlmaster-socket-path "tramp-rpc-transport")

(defun agent-remote--ssh (control host &rest args)
  "Run ssh ARGS for HOST over the ControlMaster at CONTROL.
Return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((status (apply #'call-process "ssh" nil t nil "-S" control (append args (list host)))))
      (cons status (string-trim (buffer-string))))))

(defun agent-remote--master (root &optional connected-only)
  "Return (CONTROL HOST PID) of the ControlMaster serving remote ROOT.
With CONNECTED-ONLY, inspect the existing master without touching ROOT."
  (let ((vec (tramp-dissect-file-name root)))
    (unless (equal (tramp-file-name-method vec) "rpc")
      (user-error "远程会话目前只支持 /rpc: 路径（tramp-rpc）"))
    ;; Touching the root opens the tramp-rpc connection and its master.
    (if connected-only
        (unless (agent-session--host-connected-p root)
          (error "Remote host is not connected"))
      (unless (file-directory-p root)
        (user-error "远程目录不存在：%s" root)))
    (let* ((control (tramp-rpc--controlmaster-socket-path vec))
           (host (if-let* ((user (tramp-file-name-user vec)))
                     (concat user "@" (tramp-file-name-host vec))
                   (tramp-file-name-host vec)))
           (check (agent-remote--ssh control host "-O" "check")))
      (unless (and (eq (car check) 0) (string-match "pid=\\([0-9]+\\)" (cdr check)))
        (error "找不到 %s 的 SSH 主连接：%s" host (cdr check)))
      (list control host (match-string 1 (cdr check))))))

(defun agent-remote-upload (root file)
  "Copy local FILE to the host of remote ROOT; return its path there.
For inputs the agent opens itself, such as pasted images."
  (let ((dir (concat (file-remote-p root) "~/.cache/emacs-agent/uploads/")))
    (make-directory dir t)
    (let ((target (expand-file-name (file-name-nondirectory file) dir)))
      (copy-file file target t)
      (file-local-name target))))

(provide 'agent-remote)
;;; agent-remote.el ends here
