;;; agent-emx-config-test.el --- Effective daemon display config -*- lexical-binding: t; -*-
(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'agent-emx)

(ert-deftest agent-emx-config-cache-refreshes-titles-and-programs ()
  (let ((agent-emx-config--value nil)
        (agent-session-agents '((codex :title "Codex" :backend emx :executable "codex"))))
    (should-not (agent-emx-config-collab :maxActive))
    (agent-emx-config-receive
     '(:agents (:codex (:title "Configured" :executable "/tmp/fake-codex"))
       :collab (:maxActive 2 :confirm :false)))
    (should (= (agent-emx-config-collab :maxActive) 2))
    (should-not (agent-emx-config-collab :confirm))
    (should (equal (agent-session--program 'codex) "/tmp/fake-codex"))
    (should (equal (agent-session--get 'codex :title) "Configured"))
    (agent-emx--dispatch (agent-emx--make-connection)
                         '(:method "config" :params (:config (:collab (:maxActive 3)))))
    (should (= (agent-emx-config-collab :maxActive) 3))))

(ert-deftest agent-emx-config-editor-tools-exclude-daemon-collaboration ()
  (dolist (name '("sessions" "session_read" "session_ask" "session_start" "session_stop"))
    (should-not (alist-get name agent-ui--methods nil nil #'equal)))
  (should-not (boundp 'agent-emx-agents))
  (should-not (fboundp 'agent-emx-offer)))

(provide 'agent-emx-config-test)
