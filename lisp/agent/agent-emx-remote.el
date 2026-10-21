;;; agent-emx-remote.el --- Host daemons over tramp-rpc -*- lexical-binding: t; -*-

;;; Commentary:
;; Loaded by agent-emx after its connection type is defined.  The legacy
;; keeper/relay in agent-remote remains for backends not opted into emx.

;;; Code:
(require 'agent-remote)

(defvar agent-emx-remote--manifest nil "Cached runtime files and code version.")
(defvar agent-emx-remote--timer nil "Timer checking already connected hosts.")
(defvar agent-emx-remote--automatic nil "Non-nil in automatic reconnect work.")
(defvar agent-emx-remote--inflight (make-hash-table :test #'eq)
  "Remote usage receipts currently being handed to the local daemon.")

(defun agent-emx-remote--manifest ()
  "Get the local code version and its exact runtime manifest."
  (or (and agent-emx-remote--automatic agent-emx-remote--manifest)
      (setq agent-emx-remote--manifest
            (with-temp-buffer
              (let ((default-directory agent-emx--checkout))
                (unless (zerop (call-process "node" nil t nil
                                             (expand-file-name "bin/emx" agent-emx--checkout)
                                             "daemon" "--manifest"))
                  (error "Cannot read emx runtime manifest"))
                (agent-emx--parse (buffer-string)))))))

(defun agent-emx-remote-client-id ()
  "Identify this checkout and machine independently of its code version."
  (substring (secure-hash 'sha1 (concat (file-truename agent-emx--checkout)
					"\0" (system-name))) 0 16))

(defun agent-emx-remote--node-p (version)
  "Whether VERSION identifies Node 22.18 or later."
  (and (stringp version)
       (string-match "\\`v\\([0-9]+\\)\\.\\([0-9]+\\)\\." version)
       (let ((major (string-to-number (match-string 1 version)))
             (minor (string-to-number (match-string 2 version))))
         (or (> major 22) (and (= major 22) (>= minor 18))))))

(defun agent-emx-remote--install (root manifest &optional force)
  "Verify MANIFEST in a private staging directory, then publish atomically.
FORCE replaces a broken published installation after a failed ensure."
  (when agent-emx-remote--automatic
    (error "Automatic reconnect cannot install host files"))
  (let* ((version (plist-get manifest :version))
         (parent (concat (file-remote-p root) "~/.cache/emacs-agent/emx/"))
         (dir (concat parent version "/"))
         (marker (concat dir ".complete"))
         (complete (lambda ()
                     (and (file-exists-p marker)
                          (equal (with-temp-buffer (insert-file-contents marker)
                                                   (buffer-string)) version)))))
    (unless (and (not force) (funcall complete))
      (make-directory parent t)
      ;; Never copy into the published directory.  Only user-triggered repair
      ;; removes a broken install; competing completed publications stay intact.
      (when (file-exists-p dir) (delete-directory dir t))
      (let ((staging (concat parent version ".stage-"
                             (format "%s-%s" (emacs-pid) (random most-positive-fixnum)) "/")))
        (make-directory staging)
        (set-file-modes staging #o700)
        (unwind-protect
            (progn
              (seq-doseq (entry (plist-get manifest :integrity))
                (let* ((file (plist-get entry :file))
                       (target (concat staging file)))
                  (make-directory (file-name-directory target) t)
                  (copy-file (expand-file-name file agent-emx--checkout) target)
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally target)
                    (unless (and (= (buffer-size) (plist-get entry :size))
                                 (equal (secure-hash 'sha256 (current-buffer))
                                        (plist-get entry :sha256)))
                      (error "Host runtime verification failed: %s" file)))))
              (with-temp-file (concat staging ".complete") (insert version))
              (condition-case err
                  (rename-file (directory-file-name staging) (directory-file-name dir))
                (file-already-exists
                 (unless (funcall complete) (signal (car err) (cdr err))))))
          (when (file-exists-p staging) (delete-directory staging t)))))
    dir))

(defun agent-emx-remote--json-line (output)
  "Parse the last line of OUTPUT that holds a JSON object.
The ensure command's output may include stderr lines, such as warnings
of the host's Node, before its result."
  (if-let* ((line (car (last (seq-filter (lambda (line) (string-prefix-p "{" line))
                                         (split-string output "\n" t))))))
      (agent-emx--parse line)
    (error "No result from the host daemon: %s" (string-trim output))))

(defun agent-emx-remote--process (root command buffer)
  "Run ensure COMMAND on ROOT's host into BUFFER, on user action only."
  (when agent-emx-remote--automatic
    (error "Automatic reconnect cannot run host processes"))
  ;; Bootstrap outside any project so the daemon baseline has no direnv.
  (let ((default-directory (concat (file-remote-p root) "~/")))
    (apply #'process-file (car command) nil buffer nil (cdr command))))

(defun agent-emx-remote--forward (root remote old &optional connected-only)
  "Forward a private local socket to REMOTE on ROOT's host.
Reuse OLD only if the ControlMaster is unchanged.  Return transport data."
  (let ((default-directory temporary-file-directory))
   (pcase-let ((`(,control ,host ,master)
               (if connected-only (agent-remote--master root t)
                 (agent-remote--master root))))
    (if (and (equal master (plist-get old :master))
             (equal control (plist-get old :control))
             (equal remote (plist-get old :remote))
             (file-exists-p (plist-get old :socket)))
        old
      (agent-emx-remote--close-forward old)
      (let* ((dir (make-temp-file "emx-forward-" t))
             (socket (expand-file-name "emx.sock" dir)))
        (set-file-modes dir #o700)
        (pcase (agent-remote--ssh control host "-O" "forward" "-L"
                                  (concat socket ":" remote))
          (`(0 . ,_)
           (list :dir dir :socket socket :remote remote :control control
                 :host host :master master))
          (`(,_ . ,output)
           (delete-directory dir t)
           (error "Cannot forward emx on %s: %s" host output))))))))

(defun agent-emx-remote--close-forward (forward)
  "Remove private local resources of FORWARD without opening a connection."
  (let ((default-directory temporary-file-directory))
   (when-let* ((dir (plist-get forward :dir)))
    ;; Cancel only an existing master; ssh -O never establishes a connection.
    (ignore-errors
      (agent-remote--ssh (plist-get forward :control) (plist-get forward :host)
                         "-O" "cancel" "-L"
                         (concat (plist-get forward :socket) ":"
                                 (plist-get forward :remote))))
    (ignore-errors (delete-directory dir t)))))

(defun agent-emx-remote--ensure (connection)
  "Ensure CONNECTION on user action; automatic work only forwards locally."
  (condition-case err
      (let* ((root (agent-emx--connection-place connection))
             (old (agent-emx--connection-remote connection))
             (result
              (if agent-emx-remote--automatic
                  (progn
                    (unless (and (agent-session--host-connected-p root)
                                 (plist-get old :remote))
                      (error "No remembered host socket; reconnect manually"))
                    (list :socket (plist-get old :remote)))
                (let* ((manifest (agent-emx-remote--manifest))
                       (version (plist-get manifest :version))
                       (relative (concat ".cache/emacs-agent/emx/" version))
                       (command (list "sh" "-c"
                                      (format (concat "if test \"$(cat \"$HOME/%s/.complete\" 2>/dev/null)\" = %s; then exec node \"$HOME/%s/bin/emx\" "
                                                      "daemon --client %s --ensure; else exit 44; fi")
                                              relative version relative (agent-emx-remote-client-id)))))
                  (with-temp-buffer
                    (let ((status (agent-emx-remote--process root command (current-buffer))))
                      (unless (zerop status)
                        (agent-emx-remote--install root manifest t)
                        (erase-buffer)
                        (setq status (agent-emx-remote--process root command (current-buffer))))
                      (unless (zerop status)
                        (error "Host daemon ensure failed: %s" (buffer-string)))
                      (let ((value (agent-emx-remote--json-line (buffer-string))))
                        (unless (or (eq (plist-get value :stale) t)
                                    (equal version (plist-get value :version)))
                          (error "Installed emx version does not match manifest"))
                        value)))))))
        (let ((forward (agent-emx-remote--forward
                        root (plist-get result :socket) old agent-emx-remote--automatic)))
          (setf (agent-emx--connection-remote connection) forward)
          (setq result (plist-put result :socket (plist-get forward :socket)))
          ;; The callback below does local socket work only.  No sentinel or
          ;; timer is allowed to enter the synchronous tramp file handler.
          (if agent-emx-remote--automatic
              (progn
                (agent-emx--connect connection result)
                (run-at-time 2 nil #'agent-emx-remote--hello-expired
                             connection (agent-emx--connection-process connection)))
            (agent-emx--local-connection
             (lambda (_) (agent-emx--connect connection result))
             (lambda (error) (agent-emx--lost connection error))))))
    (error (agent-emx--lost connection (list :message (error-message-string err))))))

(defun agent-emx-remote--hello-expired (connection process)
  "Disconnect a silent automatic hello on CONNECTION's captured PROCESS."
  (when (and (eq process (agent-emx--connection-process connection))
             (not (agent-emx--connection-ready connection)))
    (agent-emx--lost connection '(:message "Host daemon did not answer") t)
    (when (process-live-p process) (delete-process process))))

(defun agent-emx-remote-connection (root callback error-callback)
  "Obtain ROOT's host connection, calling CALLBACK after hello.
ERROR-CALLBACK receives failures.  One connection per host prefix shares
all its project views, since one host daemon has one editor attachment."
  (unless (string-prefix-p "/rpc:" root)
    (error "Remote emx sessions require /rpc: roots"))
  (let* ((place (agent-session-place root))
         (node (plist-get (gethash place agent-session--remote-programs) :node))
         (key (cons (file-remote-p root) (expand-file-name agent-emx-var-directory)))
         (connection (or (gethash key agent-emx--connections)
                         (puthash key (agent-emx--make-connection :place root)
                                  agent-emx--connections))))
    (unless (agent-emx-remote--node-p node)
      (error "Remote emx requires Node >= 22.18; program lookup reported %s" node))
    (if (and (agent-emx--connection-ready connection)
             (process-live-p (agent-emx--connection-process connection)))
        (funcall callback connection)
      (setf (agent-emx--connection-waiters connection)
            (append (agent-emx--connection-waiters connection)
                    (list (cons callback error-callback))))
      (unless (or (process-live-p (agent-emx--connection-starter connection))
                  (process-live-p (agent-emx--connection-process connection)))
        (agent-emx-remote--ensure connection)))
    (unless (timerp agent-emx-remote--timer)
      (setq agent-emx-remote--timer (run-at-time 10 10 #'agent-emx-remote--reconnect)))
    connection))

(defun agent-emx-remote--reconnect ()
  "Reconnect views only when their tramp-rpc host is already connected."
  (let ((agent-emx-remote--automatic t))
    (maphash
     (lambda (_ connection)
       (when-let* ((root (agent-emx--connection-place connection))
                   ((agent-session--host-connected-p root)))
         (maphash
          (lambda (_ session)
            (when (and (buffer-live-p (agent-session-buffer session))
                       (agent-emx--get session :emx-id)
                       (eq (agent-session-status session) 'disconnected)
                       (not (agent-emx--get session :emx-attaching)))
              (condition-case nil (agent-emx--ready session) (error nil))))
          (agent-emx--connection-sessions connection))))
     agent-emx--connections)))

(defun agent-emx-remote-path (connection path)
  "Map host PATH from CONNECTION to an Emacs file name."
  (if-let* ((root (agent-emx--connection-place connection)))
      (agent-session-expand-file-name path root)
    path))

(defun agent-emx-remote-result (connection value)
  "Convert editor result VALUE to CONNECTION's host paths on the wire."
  (let* ((root (agent-emx--connection-place connection))
         (prefix (and root (file-remote-p root))))
    (cond
     ((and prefix (stringp value) (string-prefix-p prefix value))
      (substring value (length prefix)))
     ((consp value) (cons (agent-emx-remote-result connection (car value))
                          (agent-emx-remote-result connection (cdr value))))
     ((vectorp value) (vconcat (mapcar (lambda (v) (agent-emx-remote-result connection v)) value)))
     (t value))))

(defun agent-emx-remote-config-call (connection message)
  "Forward remote config tool MESSAGE on CONNECTION to the local daemon."
  (let* ((params (plist-get message :params))
         (process (agent-emx--connection-process connection))
         (reply (lambda (result)
                  (when (and (eq process (agent-emx--connection-process connection))
                             (process-live-p process))
                    (agent-emx--write connection
                                      (list :jsonrpc "2.0" :id (plist-get message :id)
                                            :result result)))))
         (fail (lambda (error)
                 (funcall reply (list :ok :false :error (plist-get error :message))))))
    (agent-emx--local-connection
     (lambda (local)
       (agent-emx--request local "config/call"
                           (list :method (plist-get params :method)
                                 :arguments (or (plist-get params :params) (make-hash-table)))
                           (lambda (value) (funcall reply (list :ok t :result value))) fail))
     fail)))

(defun agent-emx-remote-push-config ()
  "Send the effective local config to every attached host daemon."
  (maphash
   (lambda (_ connection)
     (when (and (agent-emx--connection-place connection)
                (agent-emx--connection-ready connection))
       (agent-emx--request connection "config/push" (list :config (or agent-emx-config--wire agent-emx-config--value))
                           nil (lambda (error) (message "emx 远程配置更新失败：%s"
                                                        (plist-get error :message))))))
   agent-emx--connections))

(defun agent-emx-remote-configure-usage (connection)
  "Configure host quota commands on ready CONNECTION, using host executables."
  (agent-emx--request
   connection "usage/configure"
   (list :agents (vconcat (mapcar (lambda (a) (symbol-name (car a))) agent-session-agents)))
   nil (lambda (error) (message "emx 远程用量配置失败：%s" (plist-get error :message)))))

(defun agent-emx-remote-usage (connection entries)
  "Relay durable usage ENTRIES from CONNECTION; acknowledge after local receipt."
  (seq-doseq (entry entries)
    (let* ((id (plist-get entry :id))
           (inflight (or (gethash connection agent-emx-remote--inflight)
                         (puthash connection (make-hash-table :test #'equal)
                                  agent-emx-remote--inflight)))
           (method (plist-get entry :method))
           (params (copy-tree (plist-get entry :params)))
           (root (agent-emx--connection-place connection)))
      (unless (gethash id inflight)
        (puthash id t inflight)
        (if (equal method "quota")
            (setq params (plist-put params :reading
                                    (plist-put (plist-get params :reading) :host
                                               (file-remote-p root 'host))))
          (when-let* ((record (plist-get params :record))
                      (path (plist-get record :root)))
            (setq params (plist-put params :record
                                    (plist-put record :root (concat (file-remote-p root) path))))))
        (agent-emx--local-connection
         (lambda (local)
           (agent-emx--request
            local (concat "usage/" method) (append (list :id id)
                                   (when (plist-get entry :source)
                                     (list :source (plist-get entry :source)
                                           :sequence (plist-get entry :sequence))) params)
            (lambda (ack)
              (remhash id inflight)
              (when (and (equal (plist-get ack :id) id)
                         (agent-emx--connection-ready connection))
                (agent-emx--request connection "usage/ack"
                                    (if (plist-get ack :source)
                                        (list :source (plist-get ack :source)
                                              :sequence (plist-get ack :sequence))
                                      (list :id id)))))
            (lambda (_) (remhash id inflight))))
         (lambda (_) (remhash id inflight)))))))

(provide 'agent-emx-remote)
;;; agent-emx-remote.el ends here
