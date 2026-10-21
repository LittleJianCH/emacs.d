;;; agent-emx-reload.el --- Update connected daemon runtimes -*- lexical-binding: t; -*-

;;; Commentary:
;; Loaded after the client and host transport.  All reload entry points use
;; my/reload-config; only an explicit reload builds or installs runtime code.

;;; Code:
(require 'init-reload)

(defun agent-emx-reload--call (connection method params)
  "Call METHOD with PARAMS on CONNECTION while servicing editor events."
  (let ((deadline (+ (float-time) 30)) done result failure)
    (agent-emx--request connection method params
                        (lambda (value) (setq result value done t))
                        (lambda (error) (setq failure error done t)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (unless done (error "Timed out waiting for %s" method))
    (when failure (error "%s" (plist-get failure :message)))
    result))

(defun agent-emx-reload--disconnected (connection)
  "Start at most one recovery loop after CONNECTION's restart."
  (when (and (gethash connection agent-emx-reload--restarting)
             (not (gethash connection agent-emx-reload--recovering)))
    (puthash connection t agent-emx-reload--recovering)
    (run-at-time 0.1 nil #'agent-emx-reload--recover connection 100)))

(defun agent-emx-reload--recover (connection attempts)
  "Reconnect CONNECTION after its self-managed restart, with ATTEMPTS left.
Host recovery uses only the installed socket; never install from a timer."
  (when (gethash connection agent-emx-reload--restarting)
    (if (<= attempts 0)
        (progn
          (remhash connection agent-emx-reload--restarting)
          (remhash connection agent-emx-reload--recovering)
          (message "emx 重启后连接失败，请手动重新连接"))
      (let ((success
             (lambda (_)
               (remhash connection agent-emx-reload--restarting)
               (remhash connection agent-emx-reload--recovering)
               (message "emx 已更新并恢复会话；下次发送时继续")))
            (failure
             (lambda (_)
               (run-at-time 0.1 nil #'agent-emx-reload--recover
                            connection (1- attempts)))))
        (setf (agent-emx--connection-waiters connection)
              (append (agent-emx--connection-waiters connection)
                      (list (cons success failure))))
        (if (agent-emx--connection-place connection)
            (let ((agent-emx-remote--automatic t))
              (agent-emx-remote--ensure connection))
          (agent-emx--ensure connection))))))

(defun agent-emx-reload-daemons ()
  "Build current runtime and update every connected place.
Return daemon plists with string statuses and English failure/blocker text."
  (let (connections reports manifest build-error)
    (maphash
     (lambda (_ connection)
       (when (and (agent-emx--connection-ready connection)
                  (process-live-p (agent-emx--connection-process connection))
                  (or (not (agent-emx--connection-place connection))
                      (agent-session--host-connected-p
                       (agent-emx--connection-place connection))))
         ;; A local usage-only attachment shares the editor daemon's state.
         (unless (seq-some
                  (lambda (peer)
                    (and (equal (agent-emx--connection-place peer)
                                (agent-emx--connection-place connection))
                         (equal (agent-emx--connection-var peer)
                                (agent-emx--connection-var connection)))) connections)
           (push connection connections))))
     agent-emx--connections)
    (when connections
      (condition-case err
          (setq manifest (agent-emx-remote--manifest))
        (error (setq build-error (error-message-string err)))))
    (dolist (connection connections)
      (let ((place (or (agent-emx--connection-place connection) "local")))
        (push
         (cons :place
               (cons place
                     (condition-case err
                         (progn
                           (when build-error (error "%s" build-error))
                           (let* ((version (plist-get manifest :version))
                                  (peer (agent-emx-reload--call connection "ping" nil))
                                  (runtime (expand-file-name "bin/emx" agent-emx--checkout)))
                             (if (equal version (plist-get peer :version))
                                 (list :status "up_to_date" :version version)
                               (unless (= (or (plist-get (plist-get peer :capabilities) :restart) 0) 1)
                                 (error "Daemon lacks scheduled restart support; use the manual fallback"))
                               (when (agent-emx--connection-place connection)
                                 (setq runtime
                                       (file-local-name
                                        (concat (agent-emx-remote--install
                                                 (agent-emx--connection-place connection) manifest)
                                                "bin/emx"))))
                               (puthash connection version agent-emx-reload--restarting)
                               (let ((result (agent-emx-reload--call
                                              connection "daemon/restart"
                                              (list :version version :runtime runtime))))
                                 (when (equal (plist-get result :status) "restarted")
                                   (let ((deadline (+ (float-time) 15)))
                                     (while (and (gethash connection agent-emx-reload--restarting)
                                                 (< (float-time) deadline))
                                       (accept-process-output nil 0.01)))
                                   (unless (and (agent-emx--connection-ready connection)
                                                (not (gethash connection agent-emx-reload--restarting))
                                                (equal version
                                                       (plist-get (agent-emx-reload--call
                                                                   connection "ping" nil) :version)))
                                     (error "Daemon restart recovery did not reach the target version")))
                                 result))))
                       (error
                        (remhash connection agent-emx-reload--restarting)
                        (list :status "failed" :error (error-message-string err))))))
         reports)))
    (nreverse reports)))

(setq my/reload-emx-function #'agent-emx-reload-daemons)

(provide 'agent-emx-reload)
;;; agent-emx-reload.el ends here
