;;; agent-remote.el --- Agents of remote projects reach Emacs over SSH -*- lexical-binding: t; -*-

;;; Commentary:

;; The agent CLI of a remote project runs on the project's host (see
;; `agent-session-start-process'), like Claude Desktop's and T3 Code's SSH
;; modes.  Its MCP server, emx, has to stay here: it drives this Emacs through
;; emacsclient.  So each host gets a bridge:
;;
;;   agent on host --stdio--> python3 relay --unix socket on host (0600)-->
;;   ssh -R over the tramp-rpc ControlMaster --> unix socket here -->
;;   Emacs --stdio--> local `emx mcp'
;;
;; The relay's first line names the agent's session buffer; Emacs then starts
;; an emx for that session and pipes the bytes both ways.  The forward lives in
;; the ControlMaster, so a new master (after a reconnect) gets a new bridge.

;;; Code:

(require 'agent-session)
(require 'tramp)

(declare-function tramp-rpc--controlmaster-socket-path "tramp-rpc-transport")

(defconst agent-remote--relay "\
import os, socket, sys, threading
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall((sys.argv[2] + '\\n').encode())
def up():
    while True:
        d = os.read(0, 65536)
        if not d:
            s.shutdown(socket.SHUT_WR)
            break
        s.sendall(d)
threading.Thread(target=up, daemon=True).start()
while True:
    d = s.recv(65536)
    if not d:
        break
    os.write(1, d)
"
  "Python program on the host relaying stdio to the bridge socket.
Arguments: the socket path and the session buffer name.")

(defvar agent-remote--bridges (make-hash-table :test 'equal)
  "Bridges by remote prefix (\"/rpc:dev:\").
Each is a plist (:server PROCESS :dir LOCAL-DIR :remote SOCKET :master PID).")

(defun agent-remote--ssh (control host &rest args)
  "Run ssh ARGS for HOST over the ControlMaster at CONTROL.
Return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((status (apply #'call-process "ssh" nil t nil "-S" control (append args (list host)))))
      (cons status (string-trim (buffer-string))))))

(defun agent-remote--master (root)
  "Return (CONTROL HOST PID) of the ControlMaster serving remote ROOT."
  (let ((vec (tramp-dissect-file-name root)))
    (unless (equal (tramp-file-name-method vec) "rpc")
      (user-error "远程会话目前只支持 /rpc: 路径（tramp-rpc）"))
    ;; Touching the root opens the tramp-rpc connection and its master.
    (unless (file-directory-p root)
      (user-error "远程目录不存在：%s" root))
    (let* ((control (tramp-rpc--controlmaster-socket-path vec))
           (host (if-let* ((user (tramp-file-name-user vec)))
                     (concat user "@" (tramp-file-name-host vec))
                   (tramp-file-name-host vec)))
           (check (agent-remote--ssh control host "-O" "check")))
      (unless (and (eq (car check) 0) (string-match "pid=\\([0-9]+\\)" (cdr check)))
        (error "找不到 %s 的 SSH 主连接：%s" host (cdr check)))
      (list control host (match-string 1 (cdr check))))))

(defun agent-remote--close (bridge)
  "Stop the local end of BRIDGE."
  (when (process-live-p (plist-get bridge :server))
    (delete-process (plist-get bridge :server)))
  (ignore-errors (delete-directory (plist-get bridge :dir) t)))

(defun agent-remote-bridge (root)
  "Ensure the emx bridge to the host of remote ROOT.
Return the bridge socket's path on the host."
  (let* ((prefix (file-remote-p root))
         (bridge (gethash prefix agent-remote--bridges)))
    (pcase-let ((`(,control ,host ,master) (agent-remote--master root)))
      (unless (and bridge
                   (process-live-p (plist-get bridge :server))
                   (equal master (plist-get bridge :master)))
        (when bridge (agent-remote--close bridge))
        (let* ((dir (make-temp-file "agent-remote-" t))
               (local (expand-file-name "emx.sock" dir))
               (remote-dir (concat prefix "~/.cache/emacs-agent/"))
               (server (agent-remote--listen local))
               remote)
          (make-directory remote-dir t)
          (set-file-modes remote-dir #o700)
          ;; A fresh name per bridge: sshd won't replace a stale socket file.
          (setq remote (file-local-name
                        (expand-file-name (format "emx-%s-%s.sock" (emacs-pid)
                                                  (substring (md5 (format "%s%s" (random) (float-time)))
                                                             0 8))
                                          remote-dir)))
          (pcase (agent-remote--ssh control host "-O" "forward" "-R" (concat remote ":" local))
            (`(0 . ,_))
            (`(,_ . ,output)
             (delete-process server)
             (delete-directory dir t)
             (error "无法建立到 %s 的 emx 通道：%s" host output)))
          (setq bridge (list :server server :dir dir :remote remote :master master))
          (puthash prefix bridge agent-remote--bridges))))
    (plist-get bridge :remote)))

(defun agent-remote-upload (root file)
  "Copy local FILE to the host of remote ROOT; return its path there.
For inputs the agent opens itself, such as pasted images."
  (let ((dir (concat (file-remote-p root) "~/.cache/emacs-agent/uploads/")))
    (make-directory dir t)
    (let ((target (expand-file-name (file-name-nondirectory file) dir)))
      (copy-file file target t)
      (file-local-name target))))

(defun agent-remote-mcp-command (session)
  "Command line on the host that connects SESSION's agent to emx."
  (list "python3" "-c" agent-remote--relay
        (agent-remote-bridge (agent-session-root session))
        (buffer-name (agent-session-buffer session))))

;;; Local end: one emx per connection

(defun agent-remote--listen (socket)
  "Listen on Unix SOCKET for relay connections; return the server process."
  (make-network-process
   :name "agent-remote-bridge" :server t :family 'local
   :service socket :coding 'binary :noquery t
   :filter #'agent-remote--filter
   :sentinel #'agent-remote--sentinel))

(defun agent-remote--start-emx (connection name)
  "Start emx for the session in buffer NAME, piped to CONNECTION."
  (if-let* ((buffer (get-buffer name))
            (session (buffer-local-value 'agent-session--current buffer)))
      (let* ((default-directory temporary-file-directory)
             (process-environment (agent-session-environment session))
             (emx (make-process
                   :name "agent-remote-emx" :command (agent-session-emx-command)
                   :connection-type 'pipe :coding 'binary :noquery t
                   :stderr (get-buffer-create " *agent-remote-emx stderr*")
                   :filter (lambda (_process output)
                             (when (process-live-p connection)
                               (process-send-string connection output)))
                   :sentinel (lambda (process _event)
                               (unless (process-live-p process)
                                 (when (process-live-p connection)
                                   (delete-process connection)))))))
        (process-put connection 'agent-remote-emx emx)
        emx)
    (delete-process connection)
    nil))

(defun agent-remote--filter (connection data)
  "Pass DATA from the relay on CONNECTION to its emx.
The first line names the session; emx starts once it has arrived."
  (if-let* ((emx (process-get connection 'agent-remote-emx)))
      (when (process-live-p emx) (process-send-string emx data))
    (let* ((pending (concat (process-get connection 'agent-remote-pending) data))
           (newline (string-search "\n" pending)))
      (if (not newline)
          (process-put connection 'agent-remote-pending pending)
        (process-put connection 'agent-remote-pending nil)
        (when-let* ((emx (agent-remote--start-emx
                          connection (decode-coding-string (substring pending 0 newline) 'utf-8)))
                    (rest (substring pending (1+ newline))))
          (unless (string-empty-p rest) (process-send-string emx rest)))))))

(defun agent-remote--sentinel (connection _event)
  "End the emx of CONNECTION once the relay has gone."
  (unless (process-live-p connection)
    (when-let* ((emx (process-get connection 'agent-remote-emx)))
      (when (process-live-p emx) (delete-process emx)))))

(provide 'agent-remote)
;;; agent-remote.el ends here
