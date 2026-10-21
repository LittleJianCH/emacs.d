;;; agent-emx-collab-test.el --- Daemon child view tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'agent-emx)
(require 'agent-collab)
(require 'agent-emx-test)

(ert-deftest agent-emx-collab-adopts-child-without-opening-another-cli ()
  (agent-emx-test--with-session
    (let* ((connection (agent-emx--make-connection))
           (parent session)
           (agent-session-last-settings nil)
           attached child)
      (puthash "parent" parent (agent-emx--connection-sessions connection))
      (agent-session-tool parent "start" :kind 'mcp :status 'running :title "emacs · session_start")
      (cl-letf (((symbol-function 'agent-emx--attach)
                 (lambda (session peer)
                   (should (eq peer connection))
                   (setq attached session))))
        (setq child
              (agent-emx--adopt
               connection '(:id "child" :agent "dsh" :root "/private/tmp/"
                             :info (:parent "parent" :handle "bounded" :profile "coder-flash"
                                             :named t :title "子任务")))))
      (unwind-protect
          (progn
            (should (eq child attached))
            (should (eq (agent-session-backend child) 'emx))
            (should (eq (agent-session-parent child) parent))
            (should (eq (gethash "child" (agent-emx--connection-sessions connection)) child))
            (should (equal (agent-session-handle child) "bounded"))
            (should (eq (plist-get (agent-session--block parent "start") :subagent)
                        (agent-session-buffer child)))
            (should (eq child (agent-emx--adopt connection '(:id "child"))))
            (agent-emx--ask child '(:id "ask" :type "approval" :choices ["allow" "deny"]
                                       :view (:kind "command" :name "bash" :title "echo")))
            (should (agent-session--pending-asks parent))
            (let ((answer nil))
              (cl-letf (((symbol-function 'agent-emx--rpc)
                         (lambda (target method params &optional _callback)
                           (setq answer (list target method params)))))
                (let* ((copy (agent-session--ask parent
                                                 (car (agent-session--pending-asks parent))))
                       (callback (plist-get copy :callback)))
                  (funcall callback 'allow)))
              (should (eq (car answer) child))
              (should (equal (cadr answer) "session/answer")))
            (agent-emx--close-view connection "child")
            (should-not (buffer-live-p (agent-session-buffer child)))
            (should-not (agent-session--pending-asks parent)))
        (when (buffer-live-p (agent-session-buffer child))
          (agent-emx--close-view connection "child"))))))

(ert-deftest agent-emx-collab-origin-and-hidden-note-are-not-user-text ()
  (agent-emx-test--with-session
    (agent-emx--block session '(:id "mail" :type "user" :text "Reply from child"
                                   :origin "@bounded"))
    (should (equal (plist-get (agent-session--block session "mail") :origin) "@bounded"))
    (should-not (memq 'agent-collab--name-on-submit
                      agent-session-submit-functions))))
(provide 'agent-emx-collab-test)

(ert-deftest agent-emx-collab-reconnect-reattaches-existing-child-once ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection)) calls)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (agent-session-set-status session 'disconnected)
      (cl-letf (((symbol-function 'agent-emx--attach)
                 (lambda (target peer) (push (cons target peer) calls))))
        (dotimes (_ 2)
          (should (eq session (agent-emx--adopt connection '(:id "s"))))))
      (should (= (length calls) 1))
      (should (eq (caar calls) session)))))
