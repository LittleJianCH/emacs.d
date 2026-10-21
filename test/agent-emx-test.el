;;; agent-emx-test.el --- Tests for the daemon backend -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure UI/transport tests and an optional daemon echo round trip.

;;; Code:

(require 'ert)
(require 'agent-emx)

(agent-session-define-agent test-emx :title "Echo" :backend emx :emx-agent "echo")

(defmacro agent-emx-test--with-session (&rest body)
  "Run BODY with a fake SESSION and its buffer current."
  (declare (indent 0) (debug t))
  `(let* ((buffer (generate-new-buffer " *emx-test*"))
          (agent-session-status-functions nil)
          (agent-session-submit-functions nil)
          (agent-session--list-refresh-function nil)
          (agent-session--clock nil)
          (session (agent-session--make :agent 'test-emx :backend 'emx
                                        :root temporary-file-directory :buffer buffer
                                        :status 'idle :state (list :emx-id "s" :emx-epoch "epoch"))))
     (unwind-protect
         (progn
           (agent-session--setup-buffer session)
           (with-current-buffer buffer ,@body))
       (when (timerp agent-session--clock) (cancel-timer agent-session--clock))
       (kill-buffer buffer))))

(defun agent-emx-test--transcript (session)
  "Return SESSION's plain transcript."
  (with-current-buffer (agent-session-buffer session)
    (buffer-substring-no-properties (point-min) (agent-session-tail session))))

(defun agent-emx-test--event (session seq method &rest params)
  "Feed SESSION an event with SEQ, METHOD and PARAMS."
  (agent-emx--event session method (append (list :session "s" :seq seq) params)))

(ert-deftest agent-emx-test-text-stream-and-dedup ()
  (agent-emx-test--with-session
    (agent-emx-test--event session 1 "block/add"
                          :block '(:id "t" :type "text" :kind "assistant" :text "你" :done :false))
    (agent-emx-test--event session 2 "block/append" :id "t" :text "好")
    (agent-emx-test--event session 2 "block/append" :id "t" :text "duplicate")
    (agent-emx-test--event session 1 "block/append" :id "t" :text "old")
    (agent-emx-test--event session 3 "block/update" :id "t" :fields '(:done t))
    (should (equal (plist-get (agent-session--block session "t") :text) "你好"))
    (should (plist-get (agent-session--block session "t") :done))
    (should (string-match-p "你好" (agent-emx-test--transcript session)))
    (should (= 3 (plist-get (agent-emx--get session :emx-cursor) :seq)))))

(ert-deftest agent-emx-test-blocks-updates-and-order ()
  (agent-emx-test--with-session
    (agent-emx-test--event session 1 "block/add"
                          :block '(:id "u" :type "user" :text "hi"))
    ;; A daemon echo must retain the local block, including its display text.
    (agent-emx-test--event session 2 "block/add"
                          :block '(:id "u" :type "user" :text "filtered hi"))
    (agent-emx-test--event session 3 "block/add"
                          :block '(:id "tool" :type "tool" :view (:kind "command" :name "sh" :title "echo")
                                   :status "running" :output "a"))
    (agent-emx-test--event session 4 "block/append" :id "tool" :text "b")
    (agent-emx-test--event session 5 "block/update" :id "tool"
                          :fields '(:status "done" :view (:kind "edit" :name "edit" :title "file" :diff "diff")))
    (let ((tool (agent-session--block session "tool")))
      (should (eq (plist-get tool :kind) 'edit))
      (should (eq (plist-get tool :status) 'done))
      (should (equal (plist-get tool :output) "ab"))
      (should (equal (plist-get tool :diff) "diff")))
    (agent-emx-test--event session 5 "block/add" :history t :before "u"
                          :block '(:id "early" :type "user" :text "earlier"))
    (should (equal (mapcar #'car (agent-session--blocks-in-order session))
                   '("early" "u" "tool")))
    (should (equal (plist-get (agent-session--block session "u") :text) "hi"))
    (agent-emx-test--event session 6 "block/remove" :ids ["early" "tool"])
    (should (= 1 (hash-table-count (agent-session-blocks session))))))

(ert-deftest agent-emx-test-notices ()
  (agent-emx-test--with-session
    (agent-emx-test--event session 1 "block/add"
                          :block '(:id "n" :type "notice" :notice (:kind "effort-after-turn")))
    (should (string-match-p "推理强度将在当前回合结束后生效"
                            (agent-emx-test--transcript session)))
    (agent-emx-test--event session 2 "block/add"
                          :block '(:id "unknown" :type "notice" :notice (:kind "new-kind")))
    (should (eq (plist-get (agent-session--block session "unknown") :face) 'agent-session-dim))
    (let ((agent-emx-notice-formats
           '(("count" . "共 %s 项") ("named" . (lambda (args) (concat "名称：" (plist-get args :name)))))))
      (agent-emx-test--event session 3 "block/update" :id "n"
                            :fields '(:notice (:kind "count" :args (:count 2))))
      (should (equal (plist-get (agent-session--block session "n") :text) "共 2 项"))
      (agent-emx-test--event session 4 "block/update" :id "n"
                            :fields '(:notice (:kind "named" :args (:name "甲"))))
      (should (equal (plist-get (agent-session--block session "n") :text) "名称：甲")))))

(ert-deftest agent-emx-test-approval-answer-and-remove ()
  (agent-emx-test--with-session
    (let (sent)
      (cl-letf (((symbol-function 'agent-emx--ready)
                 (lambda (_session &optional callback) (when callback (funcall callback))))
                ((symbol-function 'agent-emx--request)
                 (lambda (_connection method params &rest _) (setq sent (cons method params)))))
        (agent-emx-test--event session 1 "ask/add"
                              :ask '(:id "a" :type "approval" :tool "tool"
                                     :view (:title "echo") :choices ["allow" "always" "deny"]))
        (let* ((ui-id (gethash "a" (agent-emx--table session :emx-asks)))
               (ask (agent-session--ask session ui-id)))
          (should (equal (plist-get ask :choices)
                         '((allow "允许") (always "本会话允许") (deny "拒绝"))))
          (should (equal (plist-get ask :tool) "tool"))
          (agent-session--answer session ui-id 'always)
          (should (equal sent '("session/answer" :id "s" :ask "a" :choice "always"))))
        (setq sent nil)
        (agent-emx-test--event session 2 "ask/add"
                              :ask '(:id "b" :type "approval" :description "approve" :choices ["allow" "deny"]))
        (let ((ui-id (gethash "b" (agent-emx--table session :emx-asks))))
          (agent-emx-test--event session 3 "ask/remove" :id "b" :resolution "cancelled")
          (agent-session--answer session ui-id 'allow)
          (should-not sent)
          (should (equal (plist-get (agent-session--ask session ui-id) :answer) "已取消")))))))

(ert-deftest agent-emx-test-questions ()
  (agent-emx-test--with-session
    (let (sent)
      (cl-letf (((symbol-function 'agent-emx--ready)
                 (lambda (_session &optional callback) (when callback (funcall callback))))
                ((symbol-function 'agent-emx--request)
                 (lambda (_ method params &rest _) (setq sent (cons method params)))))
        (agent-emx-test--event
         session 1 "ask/add"
         :ask '(:id "q" :type "question" :tool "tool"
                :questions [(:question "Pick" :header "H" :detail "D"
                             :options [(:label "one" :description "first")]
                             :multi :false :other t :secret :false :range [1 3 "items"])]))
        (let* ((id (gethash "q" (agent-emx--table session :emx-asks)))
               (ask (agent-session--ask session id))
               (question (car (plist-get ask :questions))))
          (should (equal (plist-get question :options) '(("one" . "first"))))
          (should-not (plist-get question :multi))
          (should-not (plist-get question :secret))
          (should (plist-get question :other))
          (should (equal (plist-get question :range) '(1 3 "items")))
          (agent-session--resolve-questions session id '((:selected ("one") :custom "extra")))
          (should (equal sent '("session/answer" :id "s" :ask "q"
                                :answers [(:selected ["one"] :custom "extra")]))))))))

(ert-deftest agent-emx-test-fresh-replay ()
  (agent-emx-test--with-session
    (agent-emx-test--event session 1 "block/add" :block '(:id "old" :type "user" :text "old"))
    (agent-emx-test--event session 2 "ask/add"
                          :ask '(:id "a" :type "approval" :description "test" :choices ["allow" "deny"]))
    (goto-char (point-max))
    (insert "draft")
    (agent-emx--attached session '(:epoch "epoch" :seq 10 :replay "fresh" :status "idle" :info (:model "echo")
                                  :settings (:mode "ask") :queue [] :asks []))
    (should (= 0 (hash-table-count (agent-session-blocks session))))
    (should-not (agent-session--pending-asks session))
    (should (equal (agent-session--input-text session) "draft"))
    (agent-emx-test--event session 10 "block/add" :history t
                          :block '(:id "history" :type "text" :kind "thinking" :text "past" :done t))
    (agent-emx-test--event session 10 "block/add" :history t
                          :block '(:id "history" :type "text" :kind "thinking" :text "past" :done t))
    (should (= 1 (hash-table-count (agent-session-blocks session))))
    (should (equal (plist-get (agent-session--block session "history") :text) "past"))
    (should-not (agent-emx--get session :emx-cursor))
    (agent-emx-test--event session 10 "history/done" :earlier :false)
    (should (equal (agent-emx--get session :emx-cursor)
                   '(:epoch "epoch" :seq 10)))
    (should (eq (agent-session-setting session :mode) 'ask))
    (agent-emx--attached session '(:epoch "epoch" :seq 15 :replay "events" :status "idle" :info nil
                                  :settings nil :asks [] :queue []))
    (should (= 10 (plist-get (agent-emx--get session :emx-cursor) :seq)))
    (agent-emx-test--event session 11 "info" :info '(:title "updated"))
    (should (equal (plist-get (agent-session-info session) :title) "updated"))))

(ert-deftest agent-emx-test-user-id-in-send-queue-and-steer ()
  (agent-emx-test--with-session
    (let (sent)
      (cl-letf (((symbol-function 'agent-emx--rpc)
                 (lambda (_ method params &optional _callback)
                   (push (cons method params) sent))))
        (let ((first (agent-session-submit session "first")))
          (should (equal (plist-get (cdar sent) :block) first))
          (let ((queued (agent-session-submit session "next")))
            (agent-session-set-status session 'idle)
            (should (equal (plist-get (cdar sent) :block) queued))))
        (agent-session-steer session "steer")
        (let ((id (plist-get (cdar sent) :block)))
          (should (equal (caar sent) "session/steer"))
          (should (equal (plist-get (agent-session--block session id) :text) "steer")))
        (should-not (agent-session-process session))))))

(ert-deftest agent-emx-test-incremental-replay-defers-snapshot ()
  (agent-emx-test--with-session
    (agent-emx-test--event session 1 "block/add"
                          :block '(:id "tool" :type "tool" :status "running"
                                   :view (:kind "command" :name "echo" :title "echo")))
    (agent-emx--set session :emx-attaching t)
    (agent-emx--attached session '(:epoch "epoch" :seq 3 :replay "events" :status "idle"
                                  :info nil :settings nil :asks [] :queue []))
    (should (agent-emx--get session :emx-attaching))
    (should (eq (plist-get (agent-session--block session "tool") :status) 'running))
    (agent-emx-test--event session 2 "block/update" :id "tool" :fields '(:status "done"))
    (agent-emx-test--event session 3 "status" :status "idle")
    (should-not (agent-emx--get session :emx-attaching))
    (should-not (agent-emx--get session :emx-replay))
    (should-not (plist-get (agent-session--block session "tool") :note))
    (should (eq (plist-get (agent-session--block session "tool") :status) 'done))))

(ert-deftest agent-emx-test-event-replay-keeps-earlier ()
  "Only a fresh view says whether earlier turns remain."
  (agent-emx-test--with-session
    (agent-emx--set session :emx-earlier t)
    (agent-emx--attached session '(:epoch "epoch" :seq 0 :replay "events" :status "idle"
                                  :info nil :settings nil :asks [] :queue []
                                  :earlier :false))
    (should (eq (agent-emx--get session :emx-earlier) t))))

(ert-deftest agent-emx-test-fresh-history-precedes-local-queue ()
  (agent-emx-test--with-session
    (agent-session-set-status session 'starting)
    (let ((id (agent-session-submit session "next" nil "hidden")) sent)
      (cl-letf (((symbol-function 'agent-emx--rpc)
                 (lambda (_ _method params) (setq sent params))))
        (agent-emx--attached session '(:epoch "epoch" :seq 5 :replay "fresh" :status "idle"
                                      :info nil :settings nil :asks [] :queue []))
        (should-not sent)
        (agent-emx-test--event session 5 "block/add" :history t
                              :block '(:id "old" :type "user" :text "old"))
        (agent-emx-test--event session 5 "block/add" :history t
                              :block '(:id "past" :type "text" :kind "assistant"
                                       :text "past" :done t))
        (should (equal (mapcar #'car (agent-session--blocks-in-order session))
                       (list "old" "past" id)))
        (agent-emx-test--event session 5 "history/done" :earlier :false)
        (should (string-match-p "hidden" (plist-get sent :text)))))))

(ert-deftest agent-emx-test-interactive-ensure-is-asynchronous ()
  (let ((connection (agent-emx--make-connection :var temporary-file-directory))
        command buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'call-process)
                   (lambda (&rest _) (ert-fail "Interactive startup blocked")))
                  ((symbol-function 'make-process)
                   (lambda (&rest params)
                     (setq command (plist-get params :command)
                           buffer (plist-get params :buffer))
                     'starter)))
          (let ((noninteractive nil)) (agent-emx--ensure connection))
          (should (equal command
                         (list "node" (expand-file-name "bin/emx" agent-emx--checkout)
                               "daemon" "--var" temporary-file-directory "--ensure")))
          (should (eq (agent-emx--connection-starter connection) 'starter)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest agent-emx-test-stop-during-open ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection :ready t)) callback stopped)
      (agent-emx--set session :emx-id nil)
      (cl-letf (((symbol-function 'agent-emx--request)
                 (lambda (_ method params &optional success _error)
                   (pcase method
                     ("session/open" (setq callback success)
                      (should (equal (plist-get params :agent) "echo")))
                     ("session/stop" (setq stopped params)))))
                ((symbol-function 'process-live-p) (lambda (_) t)))
        (agent-emx--attach session connection)
        (agent-session-backend-stop 'emx session)
        (funcall callback '(:id "late"))
        (should (equal stopped '(:id "late")))
        (should-not (agent-emx--get session :emx-id))
        (should (= 0 (hash-table-count (agent-emx--connection-sessions connection))))))))

(ert-deftest agent-emx-test-rejected-steer-falls-back ()
  (agent-emx-test--with-session
    (let (callback sent)
      (cl-letf (((symbol-function 'agent-emx--rpc)
                 (lambda (_ method &optional params success)
                   (if (equal method "session/steer") (setq callback success)
                     (push (cons method params) sent)))))
        (agent-session-set-status session 'running)
        (agent-session-steer session "next")
        (funcall callback '(:accepted :false))
        (should (equal (mapcar #'car (reverse sent)) '("session/interrupt" "session/send")))
        (should (equal (plist-get (cdar sent) :text) "next"))
        (should (agent-session--block session (plist-get (cdar sent) :block)))))))

(ert-deftest agent-emx-test-binary-framing-and-routing ()
  (agent-emx-test--with-session
    (let* ((connection (agent-emx--make-connection))
           (line (concat (json-serialize '(:jsonrpc "2.0" :method "block/add"
                                           :params (:session "s" :seq 1
                                                    :block (:id "t" :type "text" :kind "assistant"
                                                            :text "你好" :done :false))))
                         (encode-coding-string "\n" 'utf-8 t)))
           (cut (- (length line) 15)))
      (should-not (multibyte-string-p line))
      (puthash "s" session (agent-emx--connection-sessions connection))
      ;; Feed one byte at a time, including splits inside UTF-8 characters.
      (dotimes (i cut) (agent-emx--filter connection (substring line i (1+ i))))
      (should-not (agent-session--block session "t"))
      (agent-emx--filter connection (substring line cut))
      (should (equal (plist-get (agent-session--block session "t") :text) "你好")))))

(ert-deftest agent-emx-test-request-error-and-disconnect ()
  (agent-emx-test--with-session
    (let* ((connection (agent-emx--make-connection)) sent success failure)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_ bytes) (setq sent bytes))))
        (let ((id (agent-emx--request connection "hello" '(:client "emacs" :version "hash")
                                      (lambda (result) (setq success result))
                                      (lambda (error) (setq failure error)))))
          (should-not (multibyte-string-p sent))
          (agent-emx--dispatch connection (list :id id :result '(:daemon 1)))
          (should (equal success '(:daemon 1)))
          (should (= 0 (hash-table-count (agent-emx--connection-pending connection))))))
      (puthash 2 (cons nil (lambda (error)
                            (setq failure error)
                            (agent-emx--error session error)))
               (agent-emx--connection-pending connection))
      (agent-emx--lost connection '(:message "closed") t)
      (should (equal (plist-get failure :message) "closed"))
      (should (plist-get failure :connection-lost))
      (should (string-empty-p (agent-emx-test--transcript session)))
      (should (eq (agent-session-status session) 'disconnected))
      (should (= 0 (hash-table-count (agent-emx--connection-pending connection))))
      (setf (agent-emx--connection-waiters connection)
            (list (cons #'ignore (lambda (error) (agent-emx--error session error)))))
      (agent-emx--lost connection '(:message "startup failed"))
      (should (string-match-p "emx 请求失败：startup failed"
                              (agent-emx-test--transcript session))))))

(ert-deftest agent-emx-test-stop-without-session-process ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection :ready t)) sent)
      (agent-emx--set session :emx-connection connection)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'agent-emx--request)
                 (lambda (_ method params &rest _) (setq sent (cons method params)))))
        (agent-session-backend-stop 'emx session)
        (should (equal sent '("session/stop" :id "s")))
        (should-not (gethash "s" (agent-emx--connection-sessions connection)))
        (should-not (agent-session-process session))))))

(ert-deftest agent-emx-test-interrupted-fresh-attach-has-no-cursor ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection)) sent)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (agent-emx--set session :emx-cursor '(:epoch "old" :seq 100))
      (agent-emx--attached
       session '(:epoch "new" :seq 10 :replay "fresh" :status "idle"
                 :info nil :settings nil :queue [] :asks [] :earlier :false))
      (agent-emx-test--event session 10 "block/add" :history t
                            :block '(:id "partial" :type "user" :text "partial"))
      (should-not (agent-emx--get session :emx-cursor))
      (agent-emx--lost connection '(:message "closed") t)
      (should-not (agent-emx--get session :emx-cursor))
      (cl-letf (((symbol-function 'agent-emx--request)
                 (lambda (_ method params &rest _)
                   (setq sent (cons method params)))))
        (agent-emx--attach session connection)
        (should (equal sent '("session/attach" :id "s")))))))

(ert-deftest agent-emx-test-cursor-epoch-and-attach-params ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection)) sent)
      (agent-emx--set session :emx-cursor '(:epoch "old" :seq 100))
      (cl-letf (((symbol-function 'agent-emx--request)
                 (lambda (_ method params &rest _)
                   (setq sent (cons method params)))))
        (agent-emx--attach session connection)
        (should (equal sent '("session/attach" :id "s"
                              :after (:epoch "old" :seq 100)))))
      ;; Events belong to the epoch established by attach, not the old cursor.
      (agent-emx--attached
       session '(:epoch "new" :seq 2 :replay "events" :status "idle"
                 :info nil :settings nil :queue [] :asks [] :earlier :false))
      (should (equal (agent-emx--get session :emx-cursor)
                     '(:epoch "new" :seq 0)))
      (agent-emx-test--event session 1 "block/add"
                            :block '(:id "new" :type "user" :text "new"))
      (should (agent-session--block session "new"))
      (agent-emx-test--event session 2 "info" :info '(:title "new epoch"))
      (should (equal (agent-emx--get session :emx-cursor)
                     '(:epoch "new" :seq 2)))
      ;; Also guard event dedup itself against a cursor from another epoch.
      (agent-emx--set session :emx-cursor '(:epoch "old" :seq 100))
      (agent-emx-test--event session 3 "info" :info '(:title "accepted"))
      (should (equal (plist-get (agent-session-info session) :title) "accepted")))))

(ert-deftest agent-emx-test-earlier-button-insertion-and-retry ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection)) sent)
      (agent-emx--set session :emx-connection connection)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (agent-emx--attached
       session '(:epoch "epoch" :seq 10 :replay "fresh" :status "idle"
                 :info nil :settings nil :queue [] :asks [] :earlier t))
      (should (string-match-p "加载更早的记录"
                              (agent-emx-test--transcript session)))
      (agent-emx-test--event session 10 "block/add" :history t
                            :block '(:id "first" :type "user" :text "first"))
      (should (equal (mapcar #'car (agent-session--blocks-in-order session))
                     '("emx-history" "first")))
      (agent-emx-test--event session 10 "history/done" :earlier t)
      (cl-letf (((symbol-function 'agent-emx--ready)
                 (lambda (_ &optional callback) (when callback (funcall callback))))
                ((symbol-function 'agent-emx--request)
                 (lambda (_ method params &rest _)
                   (push (cons method params) sent))))
        (goto-char (point-min))
        (search-forward "加载更早的记录")
        (backward-char)
        (should (button-at (point)))
        (call-interactively (key-binding (kbd "RET")))
        (should (equal (car sent)
                       '("session/earlier" :id "s" :before "first" :turns 20)))
        (should (string-match-p "正在载入历史记录"
                                (agent-emx-test--transcript session)))
        ;; A lost request must not leave the button permanently busy.
        (agent-emx--lost connection '(:message "closed") t)
        (should-not (agent-emx--get session :emx-earlier-busy))
        (agent-emx--attached
         session '(:epoch "epoch" :seq 10 :replay "events" :status "idle"
                   :info nil :settings nil :queue [] :asks [] :earlier t))
        (agent-emx--show-history session)
        (should (= 2 (length sent)))
        (should (equal (car sent) (cadr sent)))
        (agent-emx-test--event session 10 "block/add" :history t :before "first"
                              :block '(:id "older" :type "user" :text "older"))
        (agent-emx-test--event session 10 "block/add" :history t :before "first"
                              :block '(:id "old" :type "user" :text "old"))
        (should (equal (mapcar #'car (agent-session--blocks-in-order session))
                       '("emx-history" "older" "old" "first")))
        ;; The delimiter has the current seq and must bypass dedup.
        (agent-emx-test--event session 10 "history/done" :earlier :false)
        (should-not (agent-emx--get session :emx-earlier-busy))
        (should-not (agent-session--block session "emx-history"))
        (should (equal (mapcar #'car (agent-session--blocks-in-order session))
                       '("older" "old" "first")))
        (should (equal (agent-emx--get session :emx-cursor)
                       '(:epoch "epoch" :seq 10)))))))

(ert-deftest agent-emx-test-partial-earlier-page-retries-original-anchor ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection)) sent)
      (agent-emx--set session :emx-connection connection)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (agent-emx-test--event session 10 "block/add"
                            :block '(:id "u21" :type "user" :text "page-21"))
      (agent-emx--set session :emx-earlier t)
      (agent-emx--history-line session)
      (cl-letf (((symbol-function 'agent-emx--ready)
                 (lambda (_ &optional callback) (when callback (funcall callback))))
                ((symbol-function 'agent-emx--request)
                 (lambda (_ method params &rest _)
                   (push (cons method params) sent))))
        (agent-emx--show-history session)
        ;; Only the first block arrives before the transport fails.
        (agent-emx-test--event
         session 10 "block/add" :history t :before "u21"
         :block '(:id "u1" :type "text" :kind "assistant" :text "page-01" :done t))
        (agent-emx--lost connection '(:message "closed") t)
        (agent-emx--attached
         session '(:epoch "epoch" :seq 11 :replay "events" :status "idle"
                   :info nil :settings nil :queue [] :asks [] :earlier :false))
        (agent-emx-test--event session 11 "info" :info '(:title "reconnected"))
        (should-not (agent-emx--get session :emx-attaching))
        (should (equal (agent-emx--first-block session) "u1"))
        ;; Retry via the actual button after replay, despite the new first block.
        (goto-char (point-min))
        (search-forward "加载更早的记录")
        (button-activate (button-at (1- (point))))
        (should (= (length sent) 2))
        (dolist (request sent)
          (should (equal request
                         '("session/earlier" :id "s" :before "u21" :turns 20))))
        ;; Repeated history must not redraw a block inside the insertion wrapper.
        (agent-emx-test--event
         session 11 "block/add" :history t :before "u21"
         :block '(:id "u1" :type "text" :kind "assistant" :text "page-01" :done t))
        (cl-loop for n from 2 to 20 do
                 (agent-emx-test--event
                  session 11 "block/add" :history t :before "u21"
                  :block (list :id (format "u%d" n) :type "user"
                               :text (format "page-%02d" n))))
        (agent-emx-test--event session 11 "history/done" :earlier t)
        (should-not (agent-emx--get session :emx-earlier-before))
        (should-not (agent-emx--get session :emx-earlier-busy))
        (should (equal (mapcar #'car (agent-session--blocks-in-order session))
                       (cons "emx-history"
                             (cl-loop for n from 1 to 21 collect (format "u%d" n)))))
        (goto-char (point-min))
        (cl-loop for n from 1 to 21 for text = (format "page-%02d" n) do
                 (should (= 1 (how-many text (point-min) (agent-session-tail session))))
                 (should (search-forward text (agent-session-tail session) t)))
        ;; A completed page releases its anchor for the next page.
        (agent-emx--show-history session)
        (should (equal (car sent)
                       '("session/earlier" :id "s" :before "u1" :turns 20)))))))

(ert-deftest agent-emx-test-earlier-button-redraw-and-remove ()
  (agent-emx-test--with-session
    (agent-emx-test--event session 1 "block/add"
                          :block '(:id "u" :type "user" :text "retained transcript"))
    (let ((original (agent-emx-test--transcript session)))
      (agent-emx--set session :emx-earlier t)
      (dolist (busy '(nil t nil t nil t nil))
        (agent-emx--set session :emx-earlier-busy busy)
        (agent-emx--history-line session)
        (let ((block (agent-session--block session "emx-history")))
          (should (< (plist-get block :start) (plist-get block :end))))
        (should (= 1 (how-many "加载更早的记录\\|正在载入历史记录"
                               (point-min) (agent-session-tail session))))
        (should (equal (mapcar #'car (agent-session--blocks-in-order session))
                       '("emx-history" "u"))))
      (agent-emx--set session :emx-earlier :false)
      (agent-emx--history-line session)
      (should-not (agent-session--block session "emx-history"))
      (should (equal original (agent-emx-test--transcript session))))))

(ert-deftest agent-emx-test-disconnected-stop-survives-buffer-and-reconnect ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection)) sent callbacks hello)
      (agent-emx--set session :emx-connection connection)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (cl-letf (((symbol-function 'agent-emx--request)
                 (lambda (_ method params &optional success failure)
                   (push (cons method params) sent)
                   (if (equal method "hello") (setq hello success)
                     (push (cons success failure) callbacks))))
                ((symbol-function 'make-network-process) (lambda (&rest _) 'socket)))
        (agent-session-backend-stop 'emx session)
        (kill-buffer buffer)
        (should-not sent)
        (should (equal (agent-emx--connection-pending-stops connection) '("s")))
        (should-not (gethash "s" (agent-emx--connection-sessions connection)))
        (setf (agent-emx--connection-waiters connection)
              (list (cons (lambda (_)
                            (agent-emx--request connection "sessions/list" nil))
                          nil)))
        (agent-emx--connect connection '(:socket "unused" :version "v"))
        (should (equal (mapcar #'car sent) '("hello")))
        (funcall hello nil)
        (should (equal (mapcar #'car (reverse sent))
                       '("hello" "session/stop" "sessions/list")))
        (should (equal (plist-get (cdr (cadr sent)) :id) "s"))
        (should (equal (agent-emx--connection-pending-stops connection) '("s")))
        ;; Transport errors retain the stop for the next hello.
        (funcall (cdr (cadr callbacks)) '(:connection-lost t))
        (agent-emx--lost connection '(:message "closed") t)
        (agent-emx--connect connection '(:socket "unused" :version "v"))
        (funcall hello nil)
        (funcall (caar callbacks) nil)
        (should-not (agent-emx--connection-pending-stops connection))
        ;; Already absent on a restarted daemon is also an acknowledgement.
        (setf (agent-emx--connection-pending-stops connection) '("gone"))
        (agent-emx--flush-stops connection)
        (funcall (cdar callbacks) '(:code 1 :message "No session"))
        (should-not (agent-emx--connection-pending-stops connection))))))

(defun agent-emx-test--wait (predicate)
  "Wait up to ten seconds for PREDICATE, processing daemon output."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(ert-deftest agent-emx-test-echo-round-trip-and-reconnect ()
  (unless (and (executable-find "node")
               (file-exists-p (expand-file-name "emx/daemon/main.ts" agent-emx--checkout)))
    (ert-skip "Node or the daemon implementation is not available yet"))
  (let* ((agent-emx-var-directory (make-temp-file "emx-" t))
         (agent-emx--connections (make-hash-table :test #'equal))
         (agent-session-submit-functions nil)
         (agent-session-status-functions nil)
         (agent-session--list-refresh-function nil)
         (agent-session--clock nil)
         (agent-session-last-settings nil)
         buffer session connection)
    (unwind-protect
        (progn
          (setq buffer (agent-session-open 'test-emx temporary-file-directory)
                session (buffer-local-value 'agent-session--current buffer)
                connection (agent-emx--get session :emx-connection))
          (agent-emx-test--wait (lambda () (eq (agent-session-status session) 'idle)))
          (let ((tools (plist-get (agent-emx-test--mcp connection session "tools/list") :tools))
                (result (agent-emx-test--mcp connection session "tools/call"
                                            '(:name "context"))))
            (should (seq-find (lambda (tool) (equal (plist-get tool :name) "context")) tools))
            (should-not (eq t (plist-get result :isError)))
            (should (stringp (plist-get (aref (plist-get result :content) 0) :text))))
          (let ((id (agent-session-send session "hi")))
            (agent-emx-test--wait
             (lambda () (and (eq (agent-session-status session) 'idle)
                             (string-match-p "echo: hi" (agent-emx-test--transcript session)))))
            (should (agent-session--block session id))
            (should (= 1 (seq-count (lambda (entry) (eq (plist-get (cdr entry) :type) 'user))
                                    (agent-session--blocks-in-order session)))))
          (let ((before (agent-emx-test--transcript session))
                (cursor (copy-sequence (agent-emx--get session :emx-cursor)))
                (count (hash-table-count (agent-session-blocks session))))
            (delete-process (agent-emx--connection-process connection))
            (agent-emx-test--wait (lambda () (eq (agent-session-status session) 'disconnected)))
            (agent-emx-reconnect session)
            (agent-emx-test--wait (lambda () (eq (agent-session-status session) 'idle)))
            (should (equal cursor (agent-emx--get session :emx-cursor)))
            (ert-info ((format "Before: %s\nAfter: %s" before (agent-emx-test--transcript session)))
              (should (= count (hash-table-count (agent-session-blocks session))))
              (should (equal before (agent-emx-test--transcript session)))))
          ;; Sending while disconnected must initiate an async attach and queue.
          (delete-process (agent-emx--connection-process connection))
          (agent-emx-test--wait (lambda () (eq (agent-session-status session) 'disconnected)))
          (agent-session-send session "你好")
          (agent-emx-test--wait
           (lambda () (and (eq (agent-session-status session) 'idle)
                           (string-match-p "echo: 你好" (agent-emx-test--transcript session)))))
          (agent-session-send session "ask allow")
          (agent-emx-test--wait (lambda () (agent-session--pending-asks session)))
          ;; A pending approval survives a disconnected view and reattach.
          (delete-process (agent-emx--connection-process connection))
          (agent-emx-test--wait (lambda () (eq (agent-session-status session) 'disconnected)))
          (agent-emx-reconnect session)
          (agent-emx-test--wait
           (lambda () (and (not (agent-emx--get session :emx-attaching))
                           (agent-session--pending-asks session))))
          (should (= 1 (length (agent-session--pending-asks session))))
          (agent-session--answer session (car (agent-session--pending-asks session)) 'allow)
          (agent-emx-test--wait
           (lambda () (and (eq (agent-session-status session) 'idle)
                           (string-match-p "allowed" (agent-emx-test--transcript session)))))
          (agent-session-send session "tool echo")
          (agent-emx-test--wait
           (lambda () (and (eq (agent-session-status session) 'idle)
                           (seq-some
                            (lambda (entry)
                              (let ((block (cdr entry)))
                                (and (eq (plist-get block :type) 'tool)
                                     (eq (plist-get block :status) 'done)
                                     (equal (plist-get block :output) "tool output"))))
                            (agent-session--blocks-in-order session)))))
          (should-not (agent-session-process session)))
      (when (buffer-live-p buffer) (agent-session-kill-quietly buffer))
      (when (timerp agent-session--clock) (cancel-timer agent-session--clock))
      (when (and connection (process-live-p (agent-emx--connection-process connection)))
        (delete-process (agent-emx--connection-process connection)))
      (call-process "node" nil nil nil (expand-file-name "bin/emx" agent-emx--checkout)
                    "daemon" "--var" agent-emx-var-directory "--stop")
      (delete-directory agent-emx-var-directory t))))

(ert-deftest agent-emx-test-capabilities-and-usage-events ()
  (agent-emx-test--with-session
    (let (calls ends quotas)
      (cl-letf (((symbol-function 'agent-usage-add-call)
                 (lambda (_ model usage) (push (cons model usage) calls)))
                ((symbol-function 'agent-usage-end-turn) (lambda (_) (cl-incf ends)))
                ((symbol-function 'agent-usage-set-quota)
                 (lambda (_ &rest props) (push props quotas))))
        (setq ends 0)
        (agent-emx-test--event
         session 1 "capabilities" :capabilities
         '(:models [(:id "fake/chat" :name "Chat" :efforts ["high"] :defaultEffort "high")]
           :modes ["ask" "auto" "plan"] :commands [(:name "status" :hint "arg")]))
        (should (equal (agent-session-backend-modes 'emx session) '(ask auto plan)))
        (should (equal (plist-get (car (agent-session-backend-models 'emx session)) :efforts)
                       '("high")))
        (should (equal (plist-get (car (agent-session-backend-models 'emx session)) :default-effort)
                       "high"))
        (should (equal (agent-session-backend-commands 'emx session)
                       '((:name "status" :hint "arg"))))
        (dotimes (_ 2)
          (agent-emx-test--event session 2 "usage/call" :model "fake/chat"
                                :usage '(:input 1 :cacheRead 2 :cacheWrite 3 :output 4)))
        (agent-emx-test--event session 3 "usage/end")
        (agent-emx-test--event session 3 "usage/end")
        (agent-emx-test--event session 4 "quota" :balance [(:amount 12.34 :currency "CNY")])
        (should (equal calls '(("fake/chat" :input 1 :cache-read 2 :cache-write 3 :output 4))))
        (should (= ends 1))
        (should (equal quotas '((:balance ((:amount 12.34 :currency "CNY"))))))))))

(ert-deftest agent-emx-test-plan-review-feedback ()
  (dolist (choice '(0 1))
    (agent-emx-test--with-session
      (let (sent prompted)
        (cl-letf (((symbol-function 'agent-emx--rpc)
                   (lambda (_ method params &rest _) (setq sent (cons method params))))
                  ((symbol-function 'read-string)
                   (lambda (&rest _) (setq prompted t) " revise ")))
          (agent-emx-test--event
           session 1 "ask/add" :ask
           '(:id "plan" :type "question" :tool "tool"
             :questions [(:question "Plan" :options [(:label "yes") (:label "no")]
                          :intent (:kind "plan-review" :approve "yes"))]))
          (let* ((id (gethash "plan" (agent-emx--table session :emx-asks)))
                 (ask (agent-session--ask session id)))
            (should (equal (plist-get ask :title) "批准这个计划并开始执行？"))
            (should (equal (plist-get ask :choices) '((0 "yes") (1 "no"))))
            (agent-session--answer session id choice)
            (should (eq prompted (= choice 1)))
            (should (equal sent
                           (list "session/answer" :ask "plan" :answers
                                 (vector (if (= choice 0) '(:selected ["yes"])
                                           '(:selected ["no"] :custom "revise"))))))))))))

(ert-deftest agent-emx-test-dsh-localized-blocks ()
  (agent-emx-test--with-session
    (agent-emx--block session '(:id "u" :type "user" :text "past" :imageCount 2))
    (should (equal (plist-get (agent-session--block session "u") :text) "[图片] [图片] past"))
    (agent-emx--block session '(:id "plan" :type "tool" :status "done"
                               :view (:name "todo_write" :kind "plan" :title ""
                                      :items [(:text "A" :status "done")
                                              (:text "B" :status "active")])))
    (should (equal (plist-get (agent-session--block session "plan") :title) "更新计划"))
    (should (equal (plist-get (agent-session--block session "plan") :output) "☑ A\n▶ B"))
    (dolist (notice '(("backend-error" (:message "boom") "出错：boom")
                      ("command-error" (:message "bad") "命令失败：bad")
                      ("command-result" nil "命令已执行")
                      ("max-tokens" nil "输出达到 token 上限")
                      ("history-end" nil "—— 以上为历史记录 ——")
                      ("dsh-warning" (:message "warning") "dsh：warning")
                      ("dsh-version" (:version "X" :tested "Y") "dsh 版本为 X")))
      (agent-emx--notice session (car notice) (list :kind (car notice) :args (cadr notice)))
      (should (string-prefix-p (nth 2 notice)
                               (plist-get (agent-session--block session (car notice)) :text))))))

(ert-deftest agent-emx-test-failed-todo-shows-error-output ()
  (agent-emx-test--with-session
    (agent-emx-test--event
     session 1 "block/add" :block
     '(:id "todo" :type "tool" :status "running"
       :view (:name "todo_write" :kind "plan" :title ""
              :items [(:text "proposed task" :status "pending")])))
    (should (equal (plist-get (agent-session--block session "todo") :output)
                   "☐ proposed task"))
    (agent-emx-test--event session 2 "block/update" :id "todo"
                          :fields '(:status "error" :output "todo validation failed"))
    (should (equal (plist-get (agent-session--block session "todo") :output)
                   "todo validation failed"))
    (should (string-match-p "todo validation failed" (agent-emx-test--transcript session)))
    (should-not (string-match-p "☐ proposed task" (agent-emx-test--transcript session)))))

(ert-deftest agent-emx-test-dsh-switch-keeps-existing-backend ()
  (require 'agent-dsh)
  (let ((agent-session-agents (copy-tree agent-session-agents))
        (agent-emx-agents nil))
    (agent-emx-test--with-session
      (setf (agent-session-backend session) 'dsh)
      (agent-emx--select-agents 'agent-emx-agents '(dsh))
      (should (eq (agent-session--get 'dsh :backend) 'emx))
      (should (equal (agent-session--get 'dsh :emx-agent) "dsh"))
      (should (eq (agent-session-backend session) 'dsh))
      (agent-emx--select-agents 'agent-emx-agents nil)
      (should (eq (agent-session--get 'dsh :backend) 'dsh))
      (should-not (agent-session--get 'dsh :emx-agent)))))

(ert-deftest agent-emx-test-open-passes-parent-without-mcp ()
  (require 'agent-dsh)
  (agent-emx-test--with-session
    (let ((agent-session-agents (copy-tree agent-session-agents))
          (agent-emx-agents nil)
          sent)
      (agent-emx--select-agents 'agent-emx-agents '(dsh))
      (setf (agent-session-agent session) 'dsh
            (agent-session-info session) '(:parent "parent"))
      (agent-emx--set session :emx-id nil)
      (cl-letf (((symbol-function 'agent-dsh--mcp-servers)
                 (lambda (_) [(:name "emacs" :command "node" :args ["emx" "mcp"])]))
                ((symbol-function 'agent-emx--request)
                 (lambda (_ method params &rest _) (setq sent (cons method params)))))
        (agent-emx--attach session (agent-emx--make-connection))
        (should (equal (car sent) "session/open"))
        (should-not (plist-member (cdr sent) :mcpServers))
        (should (equal (plist-get (cdr sent) :parent) "emacs"))))))

(agent-session-define-agent test-emx-dsh :title "DeepSeek" :backend emx :emx-agent "dsh")

(ert-deftest agent-emx-test-dsh-round-trip ()
  (unless (executable-find "node") (ert-skip "Node is unavailable"))
  (require 'agent-dsh)
  (let* ((agent-emx-var-directory (make-temp-file "emx-dsh-" t))
         (agent-emx--connections (make-hash-table :test #'equal))
         (process-environment
          (cons (concat "EMX_DSH_EXECUTABLE="
                        (expand-file-name "test/emx/fixtures/dsh.mjs" agent-emx--checkout))
                process-environment))
         (agent-session-submit-functions nil)
         (agent-session-status-functions nil)
         (agent-session--list-refresh-function nil)
         (agent-session--clock nil)
         (agent-session-last-settings nil)
         buffer session connection calls (ends 0) quotas)
    (cl-letf (((symbol-function 'agent-usage-add-call)
               (lambda (_ model usage) (push (cons model usage) calls)))
              ((symbol-function 'agent-usage-end-turn) (lambda (_) (cl-incf ends)))
              ((symbol-function 'agent-usage-set-quota)
               (lambda (_ &rest props) (push props quotas))))
      (unwind-protect
          (progn
            (setq buffer (agent-session-open 'test-emx-dsh agent-emx-var-directory "resume-id" '(:mode edits))
                  session (buffer-local-value 'agent-session--current buffer)
                  connection (agent-emx--get session :emx-connection))
            (agent-emx-test--wait (lambda () (eq (agent-session-status session) 'idle)))
            (should (string-match-p "past reply" (agent-emx-test--transcript session)))
            (should-not calls)
            (should (memq 'plan (agent-session-backend-modes 'emx session)))
            (should (equal (plist-get (car (agent-session-backend-models 'emx session)) :id)
                           "fake/chat"))
            (agent-session-configure session :mode 'plan)
            (agent-session-send session "plan")
            (agent-emx-test--wait (lambda () (agent-session--pending-asks session)))
            (agent-session--answer session (car (agent-session--pending-asks session)) 0)
            (agent-emx-test--wait
             (lambda () (and (= ends 1) (eq (agent-session-status session) 'idle))))
            (should (eq (agent-session-setting session :mode) 'edits))
            (should (equal (caar calls) "fake/chat"))
            (should (equal (cdar calls) '(:input 2 :cache-read 3 :cache-write 4 :output 5)))
            (agent-emx-test--wait (lambda () quotas))
            (should-not (agent-session-process session))
            (should (string-match-p "dsh 版本为 test-version" (agent-emx-test--transcript session))))
        (when (buffer-live-p buffer) (agent-session-kill-quietly buffer))
        (when (timerp agent-session--clock) (cancel-timer agent-session--clock))
        (when (and connection (process-live-p (agent-emx--connection-process connection)))
          (delete-process (agent-emx--connection-process connection)))
        (call-process "node" nil nil nil (expand-file-name "bin/emx" agent-emx--checkout)
                      "daemon" "--var" agent-emx-var-directory "--stop")
        (delete-directory agent-emx-var-directory t)))))

(ert-deftest agent-emx-test-parent-and-plan-settings ()
  (agent-emx-test--with-session
    (setf (agent-session-info session) (list :parent buffer)
          (agent-session-settings session) '(:mode plan :before-plan full))
    (should (equal (plist-get (agent-emx--choices session) :beforePlan) "full"))
    (agent-emx-test--event session 1 "info" :info '(:parent "daemon-parent" :sessionId "native"))
    (should (eq (plist-get (agent-session-info session) :parent) buffer))
    (should (equal (agent-session-resume-id session) "native"))
    (agent-emx-test--event session 2 "settings" :settings '(:mode "plan" :beforePlan "auto"))
    (should (eq (plist-get (agent-session-settings session) :before-plan) 'auto))))

(provide 'agent-emx-test)
;;; agent-emx-test.el ends here

(ert-deftest agent-emx-test-editor-call-caller-deferred-and-errors ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection))
          (agent-ui--methods (copy-tree agent-ui--methods))
          (agent-ui--deferred (make-hash-table :test #'equal))
          sent cancelled)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (agent-ui-defmethod "test-caller" () "Return the daemon caller."
        (list :buffer (plist-get agent-ui-caller :agent_buffer)
              :root (agent-ui--caller-root)
              :same (eq session (agent-ui-caller-session))))
      (agent-ui-defmethod "test-deferred" () "Wait for a result."
        (agent-ui-defer (lambda () (list (agent-ui--caller-root)))
                        :cancel (lambda () (setq cancelled t))))
      (agent-ui-defmethod "test-error" () "Signal a method error."
        (error "Fixture error"))
      (cl-letf (((symbol-function 'agent-emx--write)
                 (lambda (_ message) (setq sent message))))
        (cl-labels ((call (method &optional params id)
                      (agent-emx--dispatch
                       connection
                       (list :jsonrpc "2.0" :id 42 :method "editor/call"
                             :params (list :method method :params params
                                           :caller (list :session (or id "s")
                                                         :root "/untrusted/"))))
                      (plist-get sent :result)))
          (let ((result (call "test-caller")))
            (should (eq t (plist-get result :ok)))
            (should (equal (plist-get result :result)
                           (list :buffer (buffer-name buffer)
                                 :root (agent-session-root session) :same t))))
          (let* ((result (call "test-deferred"))
                 (id (plist-get result :pending)))
            (should (stringp id))
            (should (equal (plist-get (call "_poll" (list :id id)) :result)
                           (agent-session-root session))))
          (let ((id (plist-get (call "test-deferred") :pending)))
            (call "_poll" (list :id id :cancel t))
            (should cancelled)
            (should-not (gethash id agent-ui--deferred)))
          (dolist (method '("test-error" "missing"))
            (let ((result (call method)))
              (should (eq :false (plist-get result :ok)))
              (should (stringp (plist-get result :error)))))
          (should (eq :false (plist-get (call "context" nil "missing") :ok))))))))

(ert-deftest agent-emx-test-tools-on-hello-and-change ()
  (let* ((connection (agent-emx--make-connection))
         (agent-emx--connections (make-hash-table :test #'equal))
         (agent-emx--tools-signatures (make-hash-table :test #'eq))
         (agent-ui--methods (copy-tree agent-ui--methods))
         hello notices)
    (puthash nil connection agent-emx--connections)
    (cl-letf (((symbol-function 'make-network-process) (lambda (&rest _) 'fake))
              ((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'agent-emx--request)
               (lambda (_ method params &optional callback &rest _)
                 (when (equal method "hello")
                   (setq hello params)
                   (funcall callback nil))))
              ((symbol-function 'agent-emx--write)
               (lambda (_ message) (push message notices))))
      (agent-emx--connect connection '(:socket "unused" :version "test"))
      (should (equal (json-serialize (plist-get hello :tools))
                     (json-serialize (agent-emx--tools))))
      (agent-emx--publish-tools)
      (should-not notices)
      (agent-ui-defmethod "test-changed" () "A new tool." :read-only t "ok")
      ;; Run the same hook the existing signature timer uses, without stamps.
      (run-hooks 'agent-ui-tools-change-functions)
      (should (= 1 (length notices)))
      (should (equal (plist-get (car notices) :method) "editor/tools"))
      (should (member "test-changed" (append (plist-get (plist-get (car notices) :params)
                                                       :readOnly) nil)))
      (agent-emx--publish-tools)
      (should (= 1 (length notices)))
      ;; Permission metadata changes must publish even if MCP definitions don't.
      (setf (plist-get (alist-get "test-changed" agent-ui--methods nil nil #'equal)
                       :read-only) nil)
      (agent-emx--publish-tools)
      (should (= 2 (length notices)))
      (should-not (seq-some (lambda (tool) (plist-member tool :annotations))
                             (plist-get (agent-emx--tools) :tools))))))

(ert-deftest agent-emx-test-editor-response-serialization-error ()
  (let ((connection (agent-emx--make-connection)) wire)
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_ bytes) (setq wire bytes))))
      (agent-emx--write connection
                        (list :jsonrpc "2.0" :id 1 :result (current-buffer)))
      (should (= -32603 (plist-get (plist-get (agent-emx--parse wire) :error) :code))))))

(defun agent-emx-test--mcp (connection session method &optional params)
  "Run a real stdio MCP METHOD with PARAMS for SESSION on CONNECTION."
  (let* ((process-environment
          (append (list (concat "EMX_DAEMON_SOCKET="
                                (process-contact (agent-emx--connection-process connection)
                                                 :service))
                        (concat "EMX_SESSION=" (agent-emx--get session :emx-id))
                        "EMX_EMACSCLIENT=/does-not-exist") process-environment))
         (buffer (generate-new-buffer " *emx-mcp-test*"))
         (process (make-process
                   :name "emx-mcp-test" :buffer buffer :connection-type 'pipe
                   :coding 'utf-8-unix :noquery t
                   :command (list "node" (expand-file-name "bin/emx" agent-emx--checkout)
                                  "mcp"))))
    (unwind-protect
        (progn
          (process-send-string process
                               (concat (json-serialize
                                        (list :jsonrpc "2.0" :id 1 :method method
                                              :params (or params (make-hash-table)))) "\n"))
          (agent-emx-test--wait
           (lambda () (with-current-buffer buffer (string-search "\n" (buffer-string)))))
          (with-current-buffer buffer
            (let ((message (json-parse-string (car (split-string (buffer-string) "\n"))
                                              :object-type 'plist)))
              (should-not (plist-get message :error))
              (plist-get message :result))))
      (delete-process process)
      (kill-buffer buffer))))

(ert-deftest agent-emx-test-editor-call-json-booleans ()
  (agent-emx-test--with-session
    (let ((connection (agent-emx--make-connection))
          (agent-ui--methods (copy-tree agent-ui--methods))
          seen sent)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (agent-ui-defmethod "test-booleans"
          ((append boolean "Append content") (nested object "Nested values"))
          "Record boolean arguments."
        (setq seen (list :append append :nested nested))
        (if append "appended" "replaced"))
      (cl-letf (((symbol-function 'agent-emx--write)
                 (lambda (_ message) (setq sent message))))
        (let* ((wire "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor/call\",\"params\":{\"method\":\"test-booleans\",\"caller\":{\"session\":\"s\"},\"params\":{\"append\":false,\"nested\":{\"values\":[false,null,true,{\"flag\":false}]}}}}")
               (message (agent-emx--parse wire))
               (legacy (json-parse-string wire :object-type 'plist
                                           :null-object nil :false-object nil)))
          (agent-emx--dispatch connection message)
          (should (equal (plist-get (plist-get sent :result) :result) "replaced"))
          (should (equal seen (plist-get (plist-get legacy :params) :params)))
          ;; Tool argument normalization must not alter event decoding.
          (should (eq :false (plist-get (plist-get (plist-get message :params)
                                                               :params) :append))))))))

(defun agent-emx-test--editor-call (connection method params &optional session)
  "Call editor METHOD with PARAMS on CONNECTION as SESSION."
  (let (sent)
    (cl-letf (((symbol-function 'agent-emx--write)
               (lambda (_ message) (setq sent message))))
      (agent-emx--dispatch
       connection (list :jsonrpc "2.0" :id 42 :method "editor/call"
                        :params (list :method method :params params
                                      :caller (list :session (or session "s")))))
      (plist-get sent :result))))

(defun agent-emx-test--deferred-cleanup (action)
  "Check deferred ownership and cancellation for ACTION."
  (agent-emx-test--with-session
    (let* ((connection (agent-emx--make-connection))
           (other (agent-emx--make-connection))
           (agent-ui--methods (copy-tree agent-ui--methods))
           (agent-ui--deferred (make-hash-table :test #'equal))
           cancelled)
      (agent-emx--set session :emx-connection connection)
      (puthash "s" session (agent-emx--connection-sessions connection))
      (puthash "other" session (agent-emx--connection-sessions connection))
      (puthash "s" session (agent-emx--connection-sessions other))
      (agent-ui-defmethod "test-owned" () "Wait until cancelled."
        (let ((owner (plist-get agent-ui-caller :session)))
          (agent-ui-defer (lambda () nil)
                          :cancel (lambda () (push owner cancelled)))))
      (let* ((id (plist-get (agent-emx-test--editor-call connection "test-owned" nil)
                            :pending))
             (sibling (plist-get (agent-emx-test--editor-call
                                  connection "test-owned" nil "other") :pending))
             (foreign (plist-get (agent-emx-test--editor-call other "test-owned" nil)
                                 :pending))
             (legacy (cadr (agent-ui-defer (lambda () nil)))))
        (pcase action
          ('stop (agent-session-backend-stop 'emx session))
          ('lost (agent-emx--lost connection '(:message "closed") t))
          ('cancel
           (remhash "s" (agent-emx--connection-sessions connection))
           (should (eq t (plist-get
                          (agent-emx-test--editor-call
                           connection "_poll" (list :id id :cancel t)) :ok)))))
        (should-not (gethash id agent-ui--deferred))
        (should (equal (sort cancelled #'string<)
                       (if (eq action 'lost) '("other" "s") '("s"))))
        (should (eq (not (eq action 'lost))
                    (not (null (gethash sibling agent-ui--deferred)))))
        (should (gethash foreign agent-ui--deferred))
        (should (gethash legacy agent-ui--deferred))
        ;; A late cleanup must succeed after local cancellation and mapping loss.
        (remhash "s" (agent-emx--connection-sessions connection))
        (should (eq t (plist-get
                       (agent-emx-test--editor-call
                        connection "_poll" (list :id id :cancel t)) :ok)))
        (should (= (length cancelled) (if (eq action 'lost) 2 1)))))))

(ert-deftest agent-emx-test-editor-deferred-stop ()
  (agent-emx-test--deferred-cleanup 'stop))

(ert-deftest agent-emx-test-editor-deferred-lost ()
  (agent-emx-test--deferred-cleanup 'lost))

(ert-deftest agent-emx-test-editor-deferred-cancel-detached ()
  (agent-emx-test--deferred-cleanup 'cancel))


(ert-deftest agent-emx-test-tools-change-during-hello ()
  (let* ((connection (agent-emx--make-connection))
         (agent-emx--connections (make-hash-table :test #'equal))
         (agent-emx--tools-signatures (make-hash-table :test #'eq))
         (agent-ui--methods (copy-tree agent-ui--methods))
         hello acknowledge notices)
    (puthash nil connection agent-emx--connections)
    (cl-letf (((symbol-function 'make-network-process) (lambda (&rest _) 'fake))
              ((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'agent-emx--request)
               (lambda (_ method params &optional callback &rest _)
                 (when (equal method "hello")
                   (setq hello params acknowledge callback))))
              ((symbol-function 'agent-emx--write)
               (lambda (_ message) (push message notices))))
      (agent-emx--connect connection '(:socket "unused" :version "test"))
      (agent-ui-defmethod "test-during-hello" () "Added during hello." "ok")
      (agent-emx--publish-tools)
      (should-not notices)
      (funcall acknowledge nil)
      (agent-emx--publish-tools)
      (should (= 1 (length notices)))
      (should (equal (plist-get (car notices) :method) "editor/tools"))
      (should-not (seq-find
                   (lambda (tool) (equal (plist-get tool :name) "test-during-hello"))
                   (plist-get (plist-get hello :tools) :tools)))
      (should (seq-find
               (lambda (tool) (equal (plist-get tool :name) "test-during-hello"))
               (plist-get (plist-get (car notices) :params) :tools)))
      (agent-emx--publish-tools)
      (should (= 1 (length notices))))))
