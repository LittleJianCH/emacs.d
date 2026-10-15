;;; agent-session-test.el --- Tests for agent-session -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests the session UI with a fake backend (echoes immediately) instead of a real agent.
;; Layout modeled on telega: conversation | footer (separator, aux line, prompt) | input.
;; Run:
;;   emacs --batch -L lisp/agent -l test/agent-session-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-session)
(require 'agent-session-list)
(require 'agent-claude)
(require 'agent-codex)
(require 'agent-dsh)

(cl-defmethod agent-session-backend-start ((_ (eql test-echo)) session)
  (agent-session-set-status session 'idle))

(cl-defmethod agent-session-backend-send ((_ (eql test-echo)) session text)
  (unless (string-prefix-p "hold" text)
    (agent-session-text session (format "reply-%s" text) (concat "收到：" text))
    (agent-session-set-status session 'idle)))

(cl-defmethod agent-session-backend-stop ((_ (eql test-echo)) _session) nil)

(defvar agent-session-test--steered nil "Steer messages received by the fake backend.")
(defvar agent-session-test--interrupted nil "Whether the fake backend was interrupted.")

(cl-defmethod agent-session-backend-steer ((_ (eql test-echo)) _session text)
  (push text agent-session-test--steered)
  t)

(cl-defmethod agent-session-backend-interrupt ((_ (eql test-echo)) _session)
  (setq agent-session-test--interrupted t))

(cl-defmethod agent-session-backend-models ((_ (eql test-echo)) _session)
  '((:id "small" :name "Small" :efforts ("low" "high") :default-effort "low")
    (:id "big" :name "Big" :efforts ("high" "max"))))

(cl-defmethod agent-session-backend-modes ((_ (eql test-echo)) _session)
  '(ask edits auto full plan))

(cl-defmethod agent-session-backend-commands ((_ (eql test-echo)) _session)
  '((:name "compact" :description "压缩上下文")))

(agent-session-define-agent test-echo :title "Echo")
(agent-session-define-agent test-echo2 :title "Echo2" :backend test-echo)

(defmacro agent-session-test--with-session (&rest body)
  "Run BODY in a new fake session buffer."
  `(let ((default-directory temporary-file-directory)
         ;; Each test starts from default settings, independent of the others.
         (agent-session-last-settings nil)
         (before (agent-session-buffers))
         (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (agent-session-test-echo t))
           (with-current-buffer buffer
             (goto-char (point-max))
             ,@body))
       ;; Clean up all sessions this test created (including those from switching agent).
       (dolist (b (agent-session-buffers))
         (unless (memq b before) (kill-buffer b))))))

(defun agent-session-test--type (string)
  "Type STRING at the end of the input area and send it."
  (goto-char (point-max))
  (insert string)
  (agent-session-send-input))

(defun agent-session-test--transcript ()
  "Return the plain text of the transcript (before the footer)."
  (buffer-substring-no-properties (point-min) (agent-session-tail agent-session--current)))

(defun agent-session-test--footer ()
  "Return the plain text of the footer (separator, aux line, prompt)."
  (buffer-substring-no-properties (agent-session-tail agent-session--current)
                                  (agent-session-input agent-session--current)))

(defun agent-session-test--mode-line ()
  "Return the plain text of the mode line.
In batch mode `format-mode-line' does not evaluate :eval, so call the
generating function directly."
  (substring-no-properties (agent-session--mode-line agent-session--current)))

(ert-deftest agent-session-test-multiple-messages ()
  "Several messages can be sent in a row; the conversation appends them in order."
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (agent-session-test--type "two")
   (should (string-match-p "one\\(.\\|\n\\)*收到：one\\(.\\|\n\\)*two\\(.\\|\n\\)*收到：two"
                           (agent-session-test--transcript)))))

(ert-deftest agent-session-test-transcript-read-only ()
  "The transcript and footer are read-only; the input area is editable."
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (goto-char (point-min))
   (should-error (insert "x") :type 'text-read-only)
   (goto-char (agent-session-tail agent-session--current))
   (should-error (insert "x") :type 'text-read-only)
   (goto-char (point-max))
   (insert "ok")
   (should (equal (agent-session--input-text agent-session--current) "ok"))))

(ert-deftest agent-session-test-footer ()
  "Footer: separator and prompt; queued messages and requests go on the aux line."
  (agent-session-test--with-session
   (should (string-match-p "\\`\n *\n.*Echo ❯ \\'" (agent-session-test--footer)))
   (agent-session-test--type "hold")
   (agent-session-test--type "排队的消息")
   (should (string-match-p "工作中" (agent-session-test--footer)))
   (should (string-match-p "⏳ 排队：排队的消息" (agent-session-test--footer)))
   (agent-session-ask agent-session--current :title "Write：a.txt"
                      :choices '((allow "允许") (deny "拒绝")) :callback #'ignore)
   (should (string-match-p "⚠ Write：a.txt +允许 +拒绝" (agent-session-test--footer)))))

(ert-deftest agent-session-test-typing-in-transcript ()
  "Typing in the transcript jumps to the end of the input area."
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (switch-to-buffer (current-buffer))
   (goto-char (point-min))
   (execute-kbd-macro "xy")
   (should (equal (agent-session--input-text agent-session--current) "xy"))))

(ert-deftest agent-session-test-point-out-of-prompt ()
  "Point never stays inside the prompt."
  (agent-session-test--with-session
   (switch-to-buffer (current-buffer))
   (goto-char (point-max))
   (execute-kbd-macro (kbd "x <left> <left> <left>"))
   (should (>= (point) (agent-session-input agent-session--current)))))

(ert-deftest agent-session-test-footer-keeps-input ()
  "Redrawing the footer (e.g. on status change) keeps the input and point."
  (agent-session-test--with-session
   (goto-char (point-max))
   (insert "草稿中")
   (backward-char 1)
   (agent-session-configure agent-session--current :mode 'full)
   (agent-session-set-status agent-session--current 'running)
   (agent-session--refresh agent-session--current)
   (should (equal (agent-session--input-text agent-session--current) "草稿中"))
   (should (equal (char-after) ?中))))

(ert-deftest agent-session-test-queue-order ()
  "Messages typed while busy are queued and moved to the end when sent.
The transcript order matches the actual order."
  (agent-session-test--with-session
   (agent-session-test--type "hold")            ; no reply: session keeps running
   (agent-session-test--type "q1")
   (agent-session-test--type "q2")
   (should (equal (mapcar #'cdr (agent-session-queue agent-session--current)) '("q1" "q2")))
   (should (string-match-p "排队 2" (agent-session-test--mode-line)))
   (agent-session-set-status agent-session--current 'idle)
   (should-not (agent-session-queue agent-session--current))
   (should (string-match-p "hold\\(.\\|\n\\)*q1\\(.\\|\n\\)*收到：q1\\(.\\|\n\\)*q2\\(.\\|\n\\)*收到：q2"
                           (agent-session-test--transcript)))))

(defun agent-session-test--complete (_session input)
  "Type INPUT in the input area of SESSION and return the completion candidates.
The prompt is on the same line as the input.  Clear the input afterwards."
  (goto-char (point-max))
  (insert input)
  (prog1 (pcase-let ((`(,beg ,end ,table . ,_) (agent-session-completion-at-point)))
           (all-completions (buffer-substring-no-properties beg end) table))
    (delete-region (agent-session-input agent-session--current) (point-max))))

(ert-deftest agent-session-test-local-command ()
  "Local commands run in Emacs and are not sent as messages."
  (agent-session-test--with-session
   (let ((agent-session-last-settings nil))
     (agent-session-test--type "/model big")
     (should (equal (agent-session-setting agent-session--current :model) "big"))
     (agent-session-test--type "/effort max")
     (should (equal (agent-session-setting agent-session--current :effort) "max"))
     ;; Switching to a model that lacks the current effort resets the effort to default.
     (agent-session-test--type "/model small")
     (should-not (agent-session-setting agent-session--current :effort))
     (agent-session-test--type "/mode full")
     (should (eq (agent-session-setting agent-session--current :mode) 'full))
     (should-not (agent-session--has-conversation agent-session--current))
     ;; The agent's own commands are sent as usual.
     (agent-session-test--type "/compact")
     (should (string-match-p "收到：/compact" (agent-session-test--transcript))))))

(ert-deftest agent-session-test-completion ()
  "/ completes command names and arguments; @ triggers even mid-line."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (should (member "/model" (agent-session-test--complete session "/mo")))
     (should (member "/compact" (agent-session-test--complete session "/com")))
     (should (equal (sort (agent-session-test--complete session "/model ") #'string<)
                    '("big" "small")))
     (should (equal (agent-session-test--complete session "/effort h") '("high")))
     ;; A / at the start of the second line also completes.
     (should (member "/model" (agent-session-test--complete session "说明\n/mo"))))))

(ert-deftest agent-session-test-completion-annotation-width ()
  "/ completion annotations have equal width; the popup stays within the window.
corfu right-aligns annotations, so they need equal width to line up in a column."
  (agent-session-test--with-session
   (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 50))
             ((symbol-function 'agent-session-backend-commands)
              (lambda (&rest _)
                '((:name "loop" :description "Run a prompt or slash command on a recurring interval"
                         :hint "[interval] [prompt]")
                  (:name "mcp" :description "Manage MCP servers" :hint "")
                  (:name "docs" :description "中文说明也要对齐" :hint nil)))))
     (goto-char (point-max))
     (insert "/")
     (pcase-let* ((`(,_beg ,_end ,table . ,plist) (agent-session-completion-at-point))
                  (annotate (plist-get plist :annotation-function))
                  (widths (seq-uniq (mapcar (lambda (c) (string-width (funcall annotate c)))
                                            (all-completions "/" table)))))
       (should (= (length widths) 1))
       (should (< (+ (car widths) (length "/interrupt")) 50))
       (should (<= corfu-max-width 49))))))

(ert-deftest agent-session-test-switch-agent ()
  "Switch agent in place when empty; otherwise open a new session with the draft."
  (agent-session-test--with-session
   (let ((buffer (current-buffer)))
     (agent-session-select-agent 'test-echo2)
     (should (eq (agent-session-agent agent-session--current) 'test-echo2))
     (should (eq (current-buffer) buffer))
     (agent-session-test--type "hi")
     (goto-char (point-max))
     (insert "草稿")
     (agent-session-select-agent 'test-echo)
     (let ((new (seq-find (lambda (b) (and (not (eq b buffer))
                                           (eq (agent-session-agent
                                                (buffer-local-value 'agent-session--current b))
                                               'test-echo)))
                          (agent-session-buffers))))
       (should new)
       (should (equal (with-current-buffer new
                        (agent-session--input-text agent-session--current))
                      "草稿"))
       (kill-buffer new)))))

(ert-deftest agent-session-test-mode-line ()
  "The mode line shows agent, model, effort, permission mode and status."
  (agent-session-test--with-session
   (let ((agent-session-last-settings nil))
     (should (string-match-p "空闲.*Echo · Small · 推理 默认 · 自动审查"
                             (agent-session-test--mode-line)))
     (agent-session-configure agent-session--current :model "big" :effort "max" :mode 'full)
     (should (string-match-p "Big · 推理 max · 完全访问" (agent-session-test--mode-line)))
     (agent-session-test--type "/plan")
     (should (string-match-p "计划模式" (agent-session-test--mode-line)))
     (agent-session-test--type "/default")
     (should (eq (agent-session-setting agent-session--current :mode) 'full)))))

(ert-deftest agent-session-test-approval ()
  "Pending requests show only in the footer.
The transcript only marks waiting and the outcome on the related tool."
  (agent-session-test--with-session
   (let (answer)
     (agent-session-tool agent-session--current "t1" :kind 'edit :title "a.txt" :status 'running)
     (agent-session-ask agent-session--current :title "Write：a.txt"
                        :choices '((allow "允许") (deny "拒绝"))
                        :callback (lambda (key) (setq answer key))
                        :tool "t1")
     (should (string-match-p "⚠ Write：a.txt +允许 +拒绝" (agent-session-test--footer)))
     (should-not (string-match-p "⚠" (agent-session-test--transcript)))
     (should (string-match-p "a.txt.*等待确认" (agent-session-test--transcript)))
     (should (string-match-p "等待确认" (agent-session-test--mode-line)))
     (agent-session-approve)
     (should (eq answer 'allow))
     (should (string-match-p "a.txt.*允许" (agent-session-test--transcript)))
     (should-not (string-match-p "等待确认\\|→" (agent-session-test--transcript)))
     (should-not (string-match-p "等待确认" (agent-session-test--mode-line)))
     (should-not (string-match-p "⚠" (agent-session-test--footer))))))

(ert-deftest agent-session-test-thinking-collapsed ()
  "Thinking is folded to one line by default; expanding shows the full text."
  (agent-session-test--with-session
   (agent-session-text agent-session--current "th" "第一段思考。" 'thinking)
   (agent-session-text agent-session--current "th" "第二段思考。" 'thinking)
   (should (string-match-p "▸ 思考中…" (agent-session-test--transcript)))
   (should-not (string-match-p "第一段" (agent-session-test--transcript)))
   (agent-session-text-done agent-session--current "th")
   (should (string-match-p "▸ 思考\n" (agent-session-test--transcript)))
   (agent-session--update agent-session--current "th" :collapsed nil)
   (should (string-match-p "▾ 思考\n.*第一段思考。第二段思考。" (agent-session-test--transcript)))))

(ert-deftest agent-session-test-list ()
  "The session list shows live sessions and their titles."
  (agent-session-test--with-session
   (agent-session-test--type "修复输入区的问题")
   (let ((buffer (current-buffer)))
     (with-temp-buffer
       (agent-session-list-mode)
       (setq agent-session-list--root temporary-file-directory)
       (agent-session-list--render)
       (should (string-match-p "进行中\\(.\\|\n\\)*Echo\\(.\\|\n\\)*修复输入区的问题"
                               (buffer-string)))
       (goto-char (point-min))
       (agent-session-list-next)
       (should (eq (plist-get (get-text-property (point) 'agent-session-entry) :buffer) buffer))))))

(ert-deftest agent-session-test-list-debounce ()
  "The debounced refresh callback refreshes once and does not reschedule itself.
It used to hang Emacs."
  (let ((agent-session-list--pending nil)
        (scheduled 0) (refreshed 0))
    (agent-session-list--refresh-soon)
    (let ((timer agent-session-list--pending))
      (should (timerp timer))
      (cancel-timer timer)
      (cl-letf* ((original (symbol-function 'agent-session-list--refresh-soon))
                 ((symbol-function 'agent-session-list--refresh-soon)
                  (lambda () (cl-incf scheduled) (funcall original)))
                 ((symbol-function 'agent-session-list--refresh)
                  (lambda () (cl-incf refreshed))))
        (funcall (timer--function timer))
        (should (= refreshed 1))
        (should (= scheduled 0))
        (should-not agent-session-list--pending)))))

(defun agent-session-test--visible-transcript ()
  "Return the visible (not folded) text of the transcript."
  (let ((end (agent-session-tail agent-session--current)) (pos (point-min)) (parts nil))
    (while (< pos end)
      (let ((next (next-single-char-property-change pos 'invisible nil end)))
        (unless (invisible-p pos) (push (buffer-substring-no-properties pos next) parts))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(ert-deftest agent-session-test-fold-turn ()
  "A finished turn folds its steps into a summary; the final reply stays visible.
The summary can be expanded."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")              ; turn in progress
     (agent-session-tool session "c1" :kind 'command :title "cargo test" :status 'ok)
     (agent-session-text session "mid" "先跑一下测试。")
     (agent-session-text-done session "mid")
     (agent-session-tool session "e1" :kind 'edit :title "a.rs" :status 'ok)
     (agent-session-tool session "e2" :kind 'edit :title "b.rs" :status 'error)
     (agent-session-text session "final" "改好了。")
     (agent-session-text-done session "final")
     ;; A turn in progress is not folded
     (should (string-match-p "cargo test" (agent-session-test--visible-transcript)))
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should (string-match-p "执行了 3 个操作 · 1 条命令 · 2 次编辑 · 1 个失败 · 用时" visible))
       (should (string-match-p "改好了。" visible))
       (should-not (string-match-p "cargo test\\|先跑一下测试\\|a.rs" visible)))
     ;; Expand
     (goto-char (point-min))
     (search-forward "执行了")
     (push-button (button-start (button-at (point))))
     (should (string-match-p "▾ 执行了.*\\(.\\|\n\\)*cargo test\\(.\\|\n\\)*a.rs"
                             (agent-session-test--visible-transcript)))
     ;; Next turn: earlier folds are untouched; the new turn folds too when it ends
     (agent-session-test--type "第二个问题")
     (should (string-match-p "收到：第二个问题" (agent-session-test--visible-transcript))))))

(ert-deftest agent-session-test-fold-skips-queued ()
  "A queued message inside the previous turn does not split that turn."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")
     (agent-session-tool session "c1" :kind 'command :title "step-1" :status 'ok)
     (agent-session-test--type "排队消息")          ; typed while running, queued
     (agent-session-tool session "c2" :kind 'command :title "step-2" :status 'ok)
     (agent-session-text session "final" "完成。")
     (agent-session-text-done session "final")
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should (string-match-p "执行了 2 个操作" visible))
       (should-not (string-match-p "step-1\\|step-2" visible))
       (should (string-match-p "完成。" visible))
       ;; Once sent, the queued message appears at the end and gets a reply
       (should (string-match-p "完成。\\(.\\|\n\\)*排队消息\\(.\\|\n\\)*收到：排队消息" visible))))))

(ert-deftest agent-session-test-fold-interrupted-turn ()
  "A turn with no final reply (e.g. interrupted) folds only until the next message."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")
     (agent-session-tool session "c1" :kind 'command :title "step-1" :status 'ok)
     (agent-session-set-status session 'idle)        ; tool call last, no final reply
     (agent-session-test--type "下一个问题")
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should-not (string-match-p "step-1" visible))
       (should (string-match-p "下一个问题\\(.\\|\n\\)*收到：下一个问题" visible))))))

(ert-deftest agent-session-test-fold-keeps-last-reply ()
  "Interrupted turn: the last explanation stays visible; steps around it fold."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")
     (agent-session-tool session "c1" :kind 'command :title "step-1" :status 'ok)
     (agent-session-text session "m1" "我先改配置。")
     (agent-session-text-done session "m1")
     (agent-session-tool session "c2" :kind 'command :title "step-2" :status 'ok)
     (agent-session-set-status session 'idle)        ; ended without a final reply
     (agent-session-test--type "下一个问题")
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should (string-match-p "执行了 2 个操作" visible))
       (should (string-match-p "我先改配置。" visible))
       (should-not (string-match-p "step-1\\|step-2" visible))
       (should (string-match-p "下一个问题" visible)))
     ;; After expanding, both stretches of steps appear
     (goto-char (point-min))
     (search-forward "执行了")
     (push-button (button-start (button-at (point))))
     (should (string-match-p "step-1\\(.\\|\n\\)*我先改配置。\\(.\\|\n\\)*step-2"
                             (agent-session-test--visible-transcript))))))

(ert-deftest agent-session-test-steer-queued ()
  "A queued message can become a steer, sent into the current turn at once."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (agent-session-test--steered nil))
     (agent-session-test--type "hold")
     (agent-session-test--type "改用方案 B")
     (should (string-match-p "⏳ 排队：改用方案 B +引导 +取消" (agent-session-test--footer)))
     (agent-session-steer-queued)
     (should-not (agent-session-queue session))
     (should (equal agent-session-test--steered '("改用方案 B")))
     (should-not (string-match-p "排队" (agent-session-test--footer)))
     (should (string-match-p "↪ 引导\n *改用方案 B" (agent-session-test--transcript)))
     (should (eq (agent-session-status session) 'running)))))

(ert-deftest agent-session-test-steer-input ()
  "M-RET sends as a steer while running; when idle it is a normal send."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (agent-session-test--steered nil))
     (goto-char (point-max)) (insert "先别发")
     (agent-session-steer-input)                    ; idle: normal send
     (should (string-match-p "收到：先别发" (agent-session-test--transcript)))
     (should-not agent-session-test--steered)
     (agent-session-test--type "hold")
     (goto-char (point-max)) (insert "顺便加个测试")
     (agent-session-steer-input)
     (should (equal agent-session-test--steered '("顺便加个测试")))
     (should-not (agent-session-queue session)))))

(ert-deftest agent-session-test-steer-fallback ()
  "Without backend steer support, interrupt the turn and queue the message first."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (agent-session-test--interrupted nil))
     (agent-session-test--type "hold")
     (agent-session-test--type "排在后面")
     (cl-letf (((symbol-function 'agent-session-backend-steer) #'ignore))
       (agent-session-steer session "请先做这个"))
     (should agent-session-test--interrupted)
     (should (equal (mapcar #'cdr (agent-session-queue session)) '("请先做这个" "排在后面")))
     ;; The turn ends after the interrupt: the steer message is sent first
     (agent-session-set-status session 'idle)
     (should (string-match-p "收到：请先做这个\\(.\\|\n\\)*收到：排在后面"
                             (agent-session-test--transcript))))))

(ert-deftest agent-session-test-cancel-queued ()
  "Withdrawing a queued message moves it from queue and transcript to the input."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")
     (agent-session-test--type "写错了")
     (agent-session-cancel-queued)
     (should-not (agent-session-queue session))
     (should-not (string-match-p "写错了" (agent-session-test--transcript)))
     (should (equal (agent-session--input-text session) "写错了")))))

(ert-deftest agent-session-test-list-mouse ()
  "Session list: clicking an entry opens the session, clicking × ends it."
  (agent-session-test--with-session
   (agent-session-test--type "鼠标测试")
   (let ((session-buffer (current-buffer))
         (list-buffer (get-buffer-create "*agent-sessions-test*")))
     (unwind-protect
         (progn
           (switch-to-buffer list-buffer)
           (agent-session-list-mode)
           (setq agent-session-list--root temporary-file-directory)
           (agent-session-list--render)
           ;; No real display in batch mode; build positioned mouse events directly.
           (cl-flet ((click (pos)
                       (agent-session-list-mouse-open
                        (list 'mouse-1 (list (selected-window) pos '(0 . 0) 0)))))
             ;; Click on the entry's title: open the session
             (goto-char (point-min))
             (search-forward "鼠标测试")
             (let (opened)
               (cl-letf (((symbol-function 'agent-session-display)
                          (lambda (b) (setq opened b) (selected-window))))
                 (click (match-beginning 0)))
               (should (eq opened session-buffer)))
             ;; Click the × on this session's entry: end it after confirming (the list may
             ;; contain other sessions)
             (with-current-buffer list-buffer
               (goto-char (point-min))
               (let* ((start (text-property-search-forward
                              'agent-session-entry (list :buffer session-buffer) #'equal))
                      (kill (progn (goto-char (prop-match-beginning start))
                                   (search-forward " ×" (prop-match-end start))
                                   (match-beginning 0))))
                 (should (equal (get-text-property kill 'help-echo) "结束这个会话"))
                 (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                   (click kill))))
             (should-not (buffer-live-p session-buffer))))
       (kill-buffer list-buffer)))))

;; Regression: when all entries shared one mouse-face, hovering highlighted adjacent
;; entries as one block.
(ert-deftest agent-session-test-list-hover-one-entry ()
  "Session list: the mouse highlights of two adjacent entries do not touch."
  (with-temp-buffer
    (agent-session-list--insert-entry '(:id "a") "  第一项\n")
    (agent-session-list--insert-entry '(:id "b") "  第二项\n")
    (goto-char (point-min))
    (let ((first (get-text-property (point) 'mouse-face))
          (second (progn (forward-line 1) (get-text-property (point) 'mouse-face))))
      (should (and first second (not (eq first second)))))
    ;; Trailing whitespace stretches to the window's right edge and is highlighted (whole
    ;; line highlight); the entry's final newline is not (no spill onto the next line)
    (goto-char (point-min))
    (while (search-forward "\n" nil t)
      (should-not (get-text-property (1- (point)) 'mouse-face))
      (should (get-text-property (- (point) 2) 'mouse-face))
      (should (equal (get-text-property (- (point) 2) 'display) '(space :align-to right))))
    ;; Multi-line entry: hovering any line highlights the whole entry as one block
    (erase-buffer)
    (agent-session-list--insert-entry '(:id "c") "  第一行\n    第二行\n")
    (let ((face (get-text-property (point-min) 'mouse-face)))
      (should (= (next-single-property-change (point-min) 'mouse-face)
                 (1- (point-max))))
      (goto-char (point-max))
      (forward-line -1)
      (should (eq (get-text-property (point) 'mouse-face) face)))))

;; When the same session is also open in Claude Desktop etc., show the messages they
;; write to the session log.
(ert-deftest agent-session-test-claude-sync ()
  "Session sync: show other clients' messages only; keep partial lines for later.
Also mark that the context needs reloading."
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (file (make-temp-file "agent-sync-" nil ".jsonl"))
          (line (lambda (entry) (concat (json-encode entry) "\n")))
          (own (funcall line '((type . "user") (entrypoint . "sdk-cli") (uuid . "u0")
                               (message . ((role . "user") (content . "Emacs 里发的"))))))
          (desktop-user (funcall line '((type . "user") (entrypoint . "claude-desktop") (uuid . "u1")
                                        (message . ((role . "user")
                                                    (content . [((type . "text") (text . "桌面端发的"))
                                                                ((type . "image"))]))))))
          (orphan (funcall line '((type . "user") (entrypoint . "claude-desktop") (uuid . "r0")
                                  (message . ((role . "user")
                                              (content . [((type . "tool_result") (tool_use_id . "t0")
                                                           (content . "无主结果"))]))))))
          (desktop-reply (funcall line '((type . "assistant") (entrypoint . "claude-desktop") (uuid . "a1")
                                         (message . ((content . [((type . "text") (text . "桌面端回复"))])))))))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-claude--transcript) (lambda (_) file)))
           (agent-claude--set session :sync-offset 0)
           ;; The last line is not fully written yet
           (with-temp-file file
             (insert own orphan desktop-user (substring desktop-reply 0 20)))
           (agent-claude--sync session)
           (let ((text (agent-session-test--transcript)))
             (should-not (string-search "Emacs 里发的" text))
             ;; Tool results whose call was not read are not shown on their own
             (should-not (string-search "无主结果" text))
             (should-not (agent-session--block session "t0"))
             (should (string-search "以下来自 Claude Desktop" text))
             (should (string-search "桌面端发的\n[图片]" text))
             (should-not (string-search "桌面端回复" text)))
           (should (agent-claude--state session :external))
           ;; Sync after it is written: the reply is added, the source notice not repeated
           (with-temp-file file
             (insert own orphan desktop-user desktop-reply))
           (agent-claude--sync session)
           (let ((text (agent-session-test--transcript)))
             (should (string-search "桌面端回复" text))
             (should (= 1 (how-many "以下来自" (point-min) (point-max)))))
           (should (= (agent-claude--state session :sync-offset)
                      (file-attribute-size (file-attributes file)))))
       (delete-file file)))))

;; Images: paste clipboard images or insert files; on send Claude uses base64 and
;; Codex uses local paths.
(ert-deftest agent-session-test-images ()
  "Image attachments: clipboard paste, sending with messages, backend formats."
  (agent-session-test--with-session
   (let* ((agent-session-image-directory (make-temp-file "agent-images-" t))
          (png "\x89PNG\r\n\x1a\nfake")
          (session agent-session--current)
          sent)
     (unwind-protect
         (cl-letf (((symbol-function 'gui-get-selection)
                    (lambda (_ type) (if (eq type 'TARGETS) [TARGETS image/png] png)))
                   ((symbol-function 'agent-session-backend-send)
                    (lambda (_ _ text) (setq sent text))))
           ;; Paste: the clipboard image is saved to a file and a placeholder is inserted
           (goto-char (point-max))
           (insert "看这张图 ")
           (agent-session-yank)
           (let ((file (car (agent-session-message-images (agent-session--input-text session)))))
             (should (file-exists-p file))
             (should (equal (with-temp-buffer (set-buffer-multibyte nil)
                                              (insert-file-contents-literally file) (buffer-string))
                            png))
             (agent-session-send-input)
             ;; The sent message carries the image; the transcript shows the placeholder
             (should (equal (agent-session-message-images sent) (list file)))
             (should (equal (agent-session-message-text sent) "看这张图"))
             (should (string-search "看这张图 [图片]" (agent-session-test--transcript)))
             ;; Claude: image first (base64), then text
             (let ((content (agent-claude--content sent)))
               (should (equal (plist-get (aref content 0) :type) "image"))
               (should (equal (base64-decode-string
                               (plist-get (plist-get (aref content 0) :source) :data))
                              png))
               (should (equal (aref content 1) '(:type "text" :text "看这张图"))))
             ;; Codex: text and the local image path
             (should (equal (agent-codex--input sent)
                            (vector '(:type "text" :text "看这张图")
                                    (list :type "localImage" :path file))))
             ;; Without images Claude still sends a plain string
             (should (equal (agent-claude--content "纯文字") "纯文字")))
           ;; If the clipboard has text, paste it as text (e.g. files copied in Finder)
           (cl-letf (((symbol-function 'gui-get-selection)
                      (lambda (_ type) (if (eq type 'TARGETS) [TARGETS STRING image/tiff] png))))
             (should-not (agent-session--clipboard-image))))
       (delete-directory agent-session-image-directory t)))))

(ert-deftest agent-session-test-code-blocks ()
  "Only shell code blocks are runnable; indentation and console prompts are stripped."
  (let ((blocks (agent-session--code-blocks
                 (concat "说明\n```bash\necho a\necho b\n```\n"
                         "```python\nprint(1)\n```\n"
                         "- 列表\n  ```sh\n  ls -a\n  ```\n"
                         "```console\n$ git status\nOn branch main\n```"))))
    (should (equal (mapcar (lambda (b) (nth 3 b)) blocks)
                   '("echo a\necho b" "ls -a" "git status")))
    (should (equal (mapcar #'car blocks) '(0 1 2)))))

(defun agent-session-test--run-and-wait (label)
  "Press the first transcript button labelled LABEL and wait for the command."
  (goto-char (point-min))
  (search-forward label)
  (push-button (match-beginning 0))
  (let ((deadline (+ (float-time) 5)))
    (while (and (seq-some (lambda (p) (and (equal (process-name p) "agent-run") (process-live-p p)))
                          (process-list))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    ;; Let the sentinel finish.
    (accept-process-output nil 0.05)))

(ert-deftest agent-session-test-run-code ()
  "Reply commands run with one click; output and exit status show below the block."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-text-done session "r1" "试试：\n```bash\necho hello\n```\n```sh\nexit 3\n```\n完毕")
     (should (string-search "```bash  ▶ 运行  ⧉ 复制" (agent-session-test--transcript)))
     (agent-session-test--run-and-wait "▶ 运行")
     (let ((text (agent-session-test--transcript)))
       ;; The output sits after the first code block and before the second.
       (should (string-match-p "echo hello\n```\n✓ 完成 · [0-9.]+s\nhello\n```sh" text))
       (should (string-search "```bash  ↻ 重新运行" text)))
     (agent-session-test--run-and-wait "▶ 运行")
     (should (string-match-p "exit 3\n```\n✗ 退出码 3" (agent-session-test--transcript)))
     ;; Copy.
     (goto-char (point-min))
     (search-forward "⧉ 复制")
     (push-button (match-beginning 0))
     (should (equal (current-kill 0) "echo hello")))))

(ert-deftest agent-session-test-markdown-hides-markup ()
  "Finished replies hide markdown markup; opening fences show their language."
  (agent-session-test--with-session
   (agent-session-text-done agent-session--current "r1"
                            "**粗体** 和 `code`\n```bash\necho hi\n```\n```\nplain\n```\n完")
   (goto-char (point-min))
   (search-forward "**粗体**")
   (should (invisible-p (match-beginning 0)))
   (should-not (invisible-p (+ 2 (match-beginning 0))))
   (search-forward "```bash")
   (should (equal (get-char-property (match-beginning 0) 'display) "bash"))
   ;; The run buttons after the label and the line break stay visible.
   (should-not (invisible-p (match-end 0)))
   (search-forward "echo hi\n")
   (should (invisible-p (point)))
   (search-forward "```\nplain")
   (should (invisible-p (match-beginning 0)))
   (should-not (invisible-p (- (point) 5)))))

(ert-deftest agent-session-test-run-command-remote-login-shell ()
  "Remote commands run through the user's login shell; local ones don't."
  (let ((default-directory "/ssh:host:/tmp/"))
    (should (equal (agent-session--run-command "rustup show")
                   '("/bin/sh" "-c" "exec \"${SHELL:-/bin/sh}\" -lc \"$1\"" "sh" "rustup show"))))
  (let ((default-directory temporary-file-directory))
    (should (equal (agent-session--run-command "ls")
                   (list shell-file-name shell-command-switch "ls"))))
  ;; The command reaches the login shell intact, quotes included.
  (let ((argv (let ((default-directory "/ssh:host:/tmp/"))
                (agent-session--run-command "printf '%s' \"a b\""))))
    (with-temp-buffer
      (apply #'call-process (car argv) nil t nil (cdr argv))
      (should (equal (buffer-string) "a b")))))

(ert-deftest agent-session-test-run-code-eof-error ()
  "A run is still recorded when sending EOF fails (remote process already gone)."
  (agent-session-test--with-session
   (agent-session-text-done agent-session--current "r1" "```bash\necho hi\n```")
   (cl-letf (((symbol-function 'process-send-eof)
              (lambda (&rest _) (error "Process not found"))))
     (agent-session-test--run-and-wait "▶ 运行"))
   (should (string-match-p "✓ 完成 · [0-9.]+s\nhi" (agent-session-test--transcript)))))

(ert-deftest agent-session-test-run-buttons-face ()
  "Code block buttons use a face without underline."
  (agent-session-test--with-session
   (agent-session-text-done agent-session--current "r1" "```bash\necho hi\n```")
   (goto-char (point-min))
   (dolist (label '("▶ 运行" "⧉ 复制"))
     (search-forward label)
     (should (eq (get-text-property (match-beginning 0) 'face) 'agent-session-run-button)))
   (should-not (face-attribute 'agent-session-run-button :underline nil t))))

(ert-deftest agent-session-test-run-code-tail ()
  "Only the last `agent-session-run-output-lines' lines of output are shown."
  (agent-session-test--with-session
   (agent-session-text-done agent-session--current "r1" "```bash\nseq 1 8\n```")
   (agent-session-test--run-and-wait "▶ 运行")
   (should (string-match-p "…（省略 3 行）\n4\n5\n6\n7\n8"
                           (agent-session-test--transcript)))))

(ert-deftest agent-session-test-stop-code ()
  "A running command can be stopped; redrawing keeps point in place."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-text-done session "r1" "```bash\nsleep 30\n```")
     (goto-char (point-min))
     (search-forward "▶ 运行")
     (let ((pos (match-beginning 0)))
       (push-button pos)
       (should (string-search "■ 停止" (agent-session-test--transcript)))
       (should (string-search "… 运行中" (agent-session-test--transcript)))
       (with-selected-window (display-buffer (current-buffer))
         (goto-char (1+ pos))
         (agent-session--render session "r1")
         (should (= (point) (1+ pos))))
       (agent-session-test--run-and-wait "■ 停止")
       (should (string-search "■ 已停止" (agent-session-test--transcript)))
       (should (string-search "↻ 重新运行" (agent-session-test--transcript)))))))

(ert-deftest agent-session-test-dsh-messages ()
  "Bridge messages render as streamed text, tool blocks and approvals."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (written nil))
     (cl-letf (((symbol-function 'agent-session-write)
                (lambda (_ object) (push object written))))
       (dolist (message
                '((:method "status" :params (:status "running"))
                  (:method "text" :params (:id "a/0" :kind "thinking" :delta "想一想"))
                  (:method "text" :params (:id "a/1" :kind "assistant" :delta "先列"))
                  (:method "text" :params (:id "a/1" :kind "assistant" :delta "文件"))
                  (:method "text/done" :params (:id "a/1" :text "先列文件"))
                  (:method "text" :params (:id "b/1" :kind "assistant" :delta "重试前的残片"))
                  (:method "discard" :params (:ids ["b/1"]))
                  (:method "tool" :params (:id "c1" :name "bash"
                                           :arguments "{\"command\":\"ls -la\\nwc -l\"}"))
                  (:method "tool" :params (:id "c2" :name "read"
                                           :arguments "{\"path\":\"/tmp/x/src/main.rs\"}"))))
         (agent-session-backend-handle 'dsh session message))
       (should (eq (agent-session-status session) 'running))
       (should (string-search "先列文件" (agent-session-test--transcript)))
       (should-not (string-search "重试前的残片" (agent-session-test--transcript)))
       (should-not (agent-session--block session "b/1"))
       (should (eq (plist-get (agent-session--block session "a/0") :kind) 'thinking))
       ;; Multi-line commands show their first line
       (let ((tool (agent-session--block session "c1")))
         (should (eq (plist-get tool :kind) 'command))
         (should (equal (plist-get tool :title) "ls -la"))
         (should (eq (plist-get tool :status) 'running)))
       (should (eq (plist-get (agent-session--block session "c2") :kind) 'read))
       ;; The bridge asks for approval; the answer goes back as a decision
       (agent-session-backend-handle
        'dsh session '(:id "dsh-1" :method "approval"
                       :params (:callId "c1" :toolName "bash" :reason "需要完全访问")))
       (should (string-search "ls -la（需要完全访问）" (agent-session-test--footer)))
       (agent-session-approve)
       (should (equal (car written) '(:jsonrpc "2.0" :id "dsh-1" :result (:decision "allow"))))
       (agent-session-backend-handle
        'dsh session '(:method "tool/done" :params (:id "c1" :isError t :output "boom")))
       (should (eq (plist-get (agent-session--block session "c1") :status) 'error))
       (agent-session-backend-handle 'dsh session '(:method "status" :params (:status "idle")))
       (should (eq (agent-session-status session) 'idle))))))

(provide 'agent-session-test)
;;; agent-session-test.el ends here
