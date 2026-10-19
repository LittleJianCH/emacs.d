;;; agent-session-test.el --- Tests for agent-session -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests the session UI with a fake backend (echoes immediately) instead of a real agent.
;; Layout modeled on telega: conversation | footer (separator, aux line, prompt) | input.
;; Run:
;;   emacs --batch -L lisp/agent -L lisp/agent/backend
;;     -l test/agent-session-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-session)
(require 'agent-session-list)
(require 'agent-claude)
(require 'agent-codex)
(require 'agent-dsh)
(require 'agent-ui)
(require 'agent-collab)

;; Never name sessions with a real model in tests.
(setq agent-collab-handle-command nil
      agent-collab-agent-handle-commands nil)

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
       ;; Clean up all sessions this test created (including those from switching
       ;; agent), without asking about the sessions they started.
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
         (dolist (b (agent-session-buffers))
           (unless (memq b before) (kill-buffer b)))))))

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
     ;; The placeholder handle follows the new agent.
     (should (equal (agent-session-handle agent-session--current) "test-echo2"))
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

(ert-deftest agent-session-test-select-agent-no-annotation ()
  "Agent candidates are plain names: a title would only repeat them."
  (agent-session-test--with-session
   (let (annotate candidates)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt collection &rest _)
                  (setq candidates collection
                        annotate (plist-get completion-extra-properties
                                            :annotation-function))
                  "test-echo2")))
       (agent-session-select-agent))
     (should (member "test-echo2" candidates))
     (should-not annotate)
     (should (eq (agent-session-agent agent-session--current) 'test-echo2)))))

(ert-deftest agent-session-test-resume-keeps-title ()
  "A resumed session keeps its title instead of taking the next message."
  (agent-session-test--with-session
   (cl-letf (((symbol-function 'agent-session-backend-history)
              (lambda (_backend _root callback)
                (funcall callback '((:id "old" :title "旧标题" :time 0)))))
             ((symbol-function 'completing-read)
              (lambda (_prompt candidates &rest _) (caar candidates))))
     (agent-session-resume)
     (let ((session agent-session--current))
       (should (equal (agent-session-resume-id session) "old"))
       (agent-session-test--type "新消息")
       (should (equal (agent-session-display-title session) "旧标题"))))))

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

(ert-deftest agent-session-test-list-toggle ()
  "The list command opens, hides from either window, and reopens the sidebar."
  (save-window-excursion
    (agent-session-test--with-session
     (let ((agent-session-list--buffer-name " *agent-list-toggle-test*")
           (agent-session-list--timer nil)
           (agent-session--list-refresh-function nil)
           (session-buffer (current-buffer))
           (main-window (selected-window)))
       (unwind-protect
           (cl-letf (((symbol-function 'agent-session-list--fetch) #'ignore))
             (switch-to-buffer session-buffer)
             (dotimes (pass 2)
               (call-interactively (lookup-key agent-session-command-map "s"))
               (let ((window (get-buffer-window agent-session-list--buffer-name)))
                 (should (window-live-p window))
                 (should (eq (window-parameter window 'window-side) 'left))
                 (should (eq (selected-window) window)))
               ;; Close once from the sidebar, then from the session window.
               (when (= pass 1) (select-window main-window))
               (call-interactively (lookup-key agent-session-command-map "s"))
               (should-not (get-buffer-window agent-session-list--buffer-name))
               (should (get-buffer agent-session-list--buffer-name))
               (should (buffer-live-p session-buffer))
               (should (eq (window-buffer main-window) session-buffer))))
         (when (timerp agent-session-list--timer)
           (cancel-timer agent-session-list--timer))
         (when-let* ((buffer (get-buffer agent-session-list--buffer-name)))
           (kill-buffer buffer)))))))

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
  "C-u C-c C-c sends as a steer while running; when idle it is a normal send."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (agent-session-test--steered nil))
     (goto-char (point-max)) (insert "先别发")
     (agent-session-send-input t)                   ; idle: normal send
     (should (string-match-p "收到：先别发" (agent-session-test--transcript)))
     (should-not agent-session-test--steered)
     (agent-session-test--type "hold")
     (goto-char (point-max)) (insert "顺便加个测试")
     (agent-session-send-input t)
     (should (equal agent-session-test--steered '("顺便加个测试")))
     (should-not (agent-session-queue session)))))

(ert-deftest agent-session-test-ret-newline ()
  "RET adds a newline in the input area; C-c C-c sends, M-RET is free."
  (agent-session-test--with-session
   (should (eq (keymap-lookup agent-session-mode-map "C-c C-c") #'agent-session-send-input))
   (should-not (keymap-lookup agent-session-mode-map "M-RET"))
   (goto-char (point-max))
   (insert "第一行")
   (agent-session-ret)
   (insert "第二行")
   (should (equal (agent-session--input-text agent-session--current) "第一行\n第二行"))
   (should-not (string-search "收到" (agent-session-test--transcript)))
   (agent-session-send-input)
   (should (string-search "收到：第一行\n第二行" (agent-session-test--transcript)))))

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
                                   (search-forward "×" (prop-match-end start))
                                   (match-beginning 0))))
                 (should (equal (get-text-property kill 'help-echo) "结束这个会话"))
                 ;; × comes last on its line, after the handle, aligned to the right.
                 (should (string-blank-p (buffer-substring (point) (line-end-position))))
                 (should (search-backward
                          (concat "@" (agent-session-handle
                                       (buffer-local-value 'agent-session--current session-buffer)))
                          (prop-match-beginning start) t))
                 (should (eq (car-safe (get-text-property (1- kill) 'display)) 'space))
                 (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                   (click kill))))
             (should-not (buffer-live-p session-buffer))))
       (kill-buffer list-buffer)))))

(ert-deftest agent-session-test-list-head-line ()
  "Session list: a session's first line leaves room for × and keeps the handle."
  (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 30)))
    (let ((line (agent-session-list--head-line "  ● 工作中 1m  Claude · emacs.d"
                                               "  @greeting-check")))
      (should (<= (string-width line) 27))
      (should (string-suffix-p "…  @greeting-check" line)))
    (should (equal (agent-session-list--head-line "  ● 空闲" "  @a") "  ● 空闲  @a"))))

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

;; A long session's transcript is tens of megabytes: a resumed session shows
;; the latest turns, read by a script in the background, and earlier ones on
;; request.
(defun agent-session-test--claude-transcript (file)
  "Write a transcript with two turns to FILE; return the offset of the second."
  (let* ((line (lambda (entry) (concat (json-encode entry) "\n")))
         (first (concat
                 (funcall line '((type . "system") (subtype . "init")))
                 (funcall line '((type . "user") (uuid . "u1") (message . ((content . "提问一")))))
                 (funcall line '((type . "assistant") (uuid . "a1")
                                 (message . ((content . [((type . "thinking") (thinking . "想了很久"))
                                                         ((type . "tool_use") (id . "t1") (name . "Bash")
                                                          (input . ((command . "ls"))))])))))
                 (funcall line '((type . "user") (uuid . "r1") (toolUseResult . "大块记录")
                                 (message . ((content . [((type . "tool_result") (tool_use_id . "t1")
                                                          (content . "a.txt"))])))))
                 (funcall line '((type . "user") (uuid . "m1") (isMeta . t)
                                 (message . ((content . "元信息")))))
                 (funcall line '((type . "assistant") (uuid . "s1") (isSidechain . t)
                                 (message . ((content . [((type . "text") (text . "子任务"))])))))
                 (funcall line '((type . "api-request") (body . "请求体")))
                 (funcall line '((type . "assistant") (uuid . "a2")
                                 (message . ((content . [((type . "text") (text . "回答一"))])))))))
         (second (concat
                  (funcall line '((type . "user") (uuid . "u2")
                                  (message . ((content . [((type . "text") (text . "提问二"))])))))
                  (funcall line '((type . "attachment") (uuid . "q1")
                                  (attachment . ((type . "queued_command") (prompt . "插话")))))
                  (funcall line '((type . "assistant") (uuid . "a3")
                                  (message . ((content . [((type . "text") (text . "回答二"))]))))))))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert (encode-coding-string (concat first second) 'utf-8)
              ;; Still being written
              "{\"type\":\"assistant\""))
    (string-bytes first)))

(ert-deftest agent-session-test-claude-history-script ()
  "The history script picks the last turns and only the fields shown."
  (skip-unless (executable-find "python3"))
  (let ((file (make-temp-file "agent-history-" nil ".jsonl")))
    (unwind-protect
        (let* ((second (agent-session-test--claude-transcript file))
               (size (file-attribute-size (file-attributes file)))
               (run (lambda (turns stop)
                      (with-temp-buffer
                        (insert agent-claude--python-lib agent-claude--history-script)
                        (should (zerop (call-process-region
                                        (point-min) (point-max) "python3" t t nil
                                        "-" file (number-to-string turns)
                                        (number-to-string stop))))
                        (agent-claude--parse-history)))))
          (pcase-let ((`(,entries ,start ,end) (funcall run 1 -1)))
            (should (= start second))
            ;; The unfinished last line is left for syncing
            (should (= end (- size (length "{\"type\":\"assistant\""))))
            (should (equal (mapcar (lambda (e) (plist-get e :uuid)) entries) '("u2" "q1" "a3"))))
          (pcase-let ((`(,entries ,start ,end) (funcall run 1 second)))
            (should (= start 0))
            (should (= end second))
            ;; Bookkeeping and subagents are left out; so is what isn't shown
            (should (equal (mapcar (lambda (e) (plist-get e :uuid)) entries)
                           '("u1" "a1" "r1" "m1" "a2")))
            (let ((text (format "%S" entries)))
              (dolist (gone '("想了很久" "大块记录" "子任务" "请求体"))
                (should-not (string-search gone text))))
            ;; Parts not shown stay as stubs, keeping the indices of the others
            (should (equal (mapcar (lambda (p) (plist-get p :type))
                                   (plist-get (plist-get (nth 1 entries) :message) :content))
                           '("thinking" "tool_use"))))
          (should (equal (funcall run 5 -1)
                         (list (car (funcall run 2 -1)) 0 (nth 2 (funcall run 1 -1))))))
      (delete-file file))))

(ert-deftest agent-session-test-claude-history-load ()
  "Resuming loads the last turns in the background, above messages shown
meanwhile; the button above them loads the earlier ones."
  (skip-unless (executable-find "python3"))
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (file (make-temp-file "agent-history-" nil ".jsonl"))
          (agent-claude-history-turns 1)
          (wait (lambda ()
                  (with-timeout (10 (error "History did not load"))
                    (while (agent-claude--state session :history-busy)
                      (accept-process-output nil 0.05))))))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-claude--transcript) (lambda (_) file)))
           (let ((second (agent-session-test--claude-transcript file)))
             (agent-claude--show-history session)
             (should (string-search "正在载入历史记录" (agent-session-test--transcript)))
             ;; Shown while the history loads
             (agent-session-notice session "实时消息")
             (funcall wait)
             (let ((text (agent-session-test--transcript)))
               (should (string-search "载入更早的 1 个回合" text))
               (should-not (string-search "提问一" text))
               (should (< (string-search "提问二" text) (string-search "插话" text)
                          (string-search "回答二" text) (string-search "以上为历史记录" text)
                          (string-search "实时消息" text))))
             (should (= (agent-claude--state session :history-start) second))
             (should (= (agent-claude--state session :sync-offset)
                        (- (file-attribute-size (file-attributes file))
                           (length "{\"type\":\"assistant\""))))
             ;; Load the earlier turn
             (goto-char (point-min))
             (should (search-forward "载入更早" nil t))
             (push-button (match-beginning 0))
             (funcall wait)
             (let ((text (agent-session-test--transcript)))
               (should-not (string-search "载入更早" text))
               (should (= 1 (how-many "以上为历史记录" (point-min) (point-max))))
               (should (< (string-search "提问一" text) (string-search "回答一" text)
                          (string-search "提问二" text) (string-search "实时消息" text))))
             (should (eq (plist-get (agent-session--block session "t1") :status) 'ok))
             ;; Redrawing the block the earlier turns went before keeps them apart
             (agent-session--update session "u2" :text "提问二（改）")
             (let ((text (agent-session-test--transcript)))
               (should (string-search "回答一" text))
               (should (< (string-search "回答一" text) (string-search "提问二（改）" text))))))
       (agent-claude--unwatch session)
       (delete-file file)))))

(ert-deftest agent-session-test-claude-follow ()
  "A remote transcript is followed by a script on the host: it passes on
only what other clients write, and where it has read up to."
  (skip-unless (executable-find "python3"))
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (file (make-temp-file "agent-follow-" nil ".jsonl"))
          (line (lambda (entry) (concat (json-encode entry) "\n")))
          (own (funcall line '((type . "user") (entrypoint . "sdk-cli") (uuid . "u0")
                               (message . ((content . "Emacs 里发的"))))))
          (desktop (funcall line '((type . "user") (entrypoint . "claude-desktop") (uuid . "u1")
                                   (toolUseResult . "不显示的记录")
                                   (message . ((content . "桌面端发的")))))))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-claude--transcript) (lambda (_) file)))
           (with-temp-file file (insert "{\"type\":\"system\"}\n"))
           (agent-claude--set session :sync-offset 0)
           (agent-claude--follow session)
           (should (process-live-p (agent-claude--state session :watch)))
           (write-region (concat own desktop) nil file t 'silent)
           (with-timeout (10 (error "Nothing followed"))
             (while (not (string-search "桌面端发的" (agent-session-test--transcript)))
               (accept-process-output nil 0.05)))
           (should-not (string-search "Emacs 里发的" (agent-session-test--transcript)))
           (should (string-search "以下来自 Claude Desktop" (agent-session-test--transcript)))
           (should (agent-claude--state session :external))
           (should (= (agent-claude--state session :sync-offset)
                      (file-attribute-size (file-attributes file))))
           (let ((process (agent-claude--state session :watch)))
             (agent-claude--unwatch session)
             (should-not (process-live-p process)))
           ;; Remote file-notify descriptors are processes too: they are
           ;; removed as watches, not killed.
           (let ((descriptor (make-pipe-process :name "fake-watch" :noquery t))
                 removed)
             (agent-claude--set session :watch descriptor)
             (cl-letf (((symbol-function 'file-notify-rm-watch)
                        (lambda (watch) (setq removed watch))))
               (agent-claude--unwatch session))
             (should (eq removed descriptor))
             (should (process-live-p descriptor))
             (delete-process descriptor)))
       (agent-claude--unwatch session)
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

(ert-deftest agent-session-test-dsh-tool-views ()
  "dsh tool calls show diffs, the todo list and MCP names; quiet results stay hidden."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (let ((write (agent-dsh--tool-view session "write" '(:file_path "x/a.txt" :content "alpha\nbeta"))))
       (should (eq (plist-get write :kind) 'edit))
       (should (equal (plist-get write :diff) "--- x/a.txt\n+++ x/a.txt\n+alpha\n+beta")))
     (should (equal (plist-get (agent-dsh--tool-view session "edit" '(:file_path "b" :old_string "x"
                                                                       :new_string "y"))
                               :diff)
                    "--- b\n+++ b\n-x\n+y"))
     (should (equal (plist-get (agent-dsh--tool-view
                                session "todo_write"
                                '(:todos [(:content "做 A" :status "completed")
                                          (:content "做 B" :status "in_progress")]))
                               :output)
                    "☑ 做 A\n▶ 做 B"))
     (should (equal (agent-dsh--tool-view session "mcp__emacs__open" nil)
                    '(:kind mcp :title "emacs · open")))
     ;; A successful write keeps its diff but not the echoed file
     (agent-dsh--notification session "tool" '(:id "w1" :name "write"
                                              :arguments "{\"file_path\":\"a.txt\",\"content\":\"hi\"}"))
     (agent-dsh--notification session "tool/done" '(:id "w1" :isError nil :output "<path>a.txt</path>"))
     (should (eq (plist-get (agent-session--block session "w1") :status) 'ok))
     (should-not (plist-get (agent-session--block session "w1") :output))
     ;; A result for a call never shown is ignored
     (agent-dsh--notification session "tool/done" '(:id "ghost" :isError nil :output "x"))
     (should-not (agent-session--block session "ghost")))))

(ert-deftest agent-session-test-dsh-replay ()
  "A resumed dsh session replays users, thinking, replies and tools."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (dolist (item '(("user" (:id "u1" :text "看图" :images 1))
                     ("text/done" (:id "3/0" :kind "thinking" :text "想"))
                     ("text/done" (:id "3/1" :kind "assistant" :text "好的"))
                     ("tool" (:id "c1" :name "bash" :arguments "{\"command\":\"ls\"}"))
                     ("tool/done" (:id "c1" :isError t :output "boom"))))
       (agent-dsh--notification session (car item) (cadr item)))
     (should (string-search "[图片] 看图" (agent-session-test--transcript)))
     (should (eq (plist-get (agent-session--block session "3/0") :kind) 'thinking))
     (should (string-search "好的" (agent-session-test--transcript)))
     (should (eq (plist-get (agent-session--block session "c1") :status) 'error)))))

(ert-deftest agent-session-test-dsh-modes ()
  "Modes map to dsh presets; plan keeps the preset of the mode before it and
an approved plan review switches the session back."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (setf (agent-session-settings session) (list :mode 'auto))
     (should (equal (agent-dsh--preset session) "auto"))
     (setf (agent-session-settings session) (list :mode 'plan :before-plan 'full))
     (should (equal (agent-dsh--preset session) "danger-full-access"))
     ;; Presets the bridge lacks are not offered
     (setf (agent-session-state session) (list :presets '("read-only" "workspace-write") :plan t))
     (should (equal (agent-session-backend-modes 'dsh session) '(ask edits plan)))
     ;; dsh left plan mode (plan approved): follow it
     (cl-letf (((symbol-function 'agent-session-backend-apply-settings) #'ignore))
       (agent-dsh--apply-config session '(:model "p/m" :plan nil)))
     (should (eq (agent-session-setting session :mode) 'full)))))

(ert-deftest agent-session-test-dsh-question ()
  "dsh questions use the question form; a declined plan carries feedback."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (written nil))
     (cl-letf (((symbol-function 'agent-session-write) (lambda (_ object) (push object written)))
               ((symbol-function 'read-string) (lambda (&rest _) "再细一点")))
       (agent-session-backend-handle
        'dsh session
        '(:id "dsh-2" :method "question"
          :params (:questions [(:id "review" :question "Approve?" :detail "# Plan"
                                :options [(:label "Approve") (:label "Keep planning")]
                                :intent (:kind "plan-review" :approve "Approve"))])))
       (should (string-search "批准这个计划" (agent-session-test--footer)))
       (agent-session-deny)
       (should (equal (car written)
                      '(:jsonrpc "2.0" :id "dsh-2"
                        :result (:answers [(:id "review" :selected ["Keep planning"]
                                                :custom "再细一点")]))))
       ;; Other questions: multiple choice and typed answers
       (agent-session-backend-handle
        'dsh session
        '(:id "dsh-3" :method "question"
          :params (:questions [(:id "q1" :question "Which?" :multiSelect t
                                :options [(:label "a") (:label "b")])
                               (:id "q2" :question "Why?" :options [(:label "x")])])))
       (should (string-search "? 1. Which?（可多选）\n ? 2. Why?\n" (agent-session-test--footer)))
       (agent-session-test--answering '(("b" "再细一点") "")
         (agent-session-approve))
       (should (equal (car written)
                      '(:jsonrpc "2.0" :id "dsh-3"
                        :result (:answers [(:id "q1" :selected ["b"] :custom "再细一点")
                                           (:id "q2" :selected [])]))))
       ;; Declining answers nothing
       (agent-session-backend-handle
        'dsh session '(:id "dsh-4" :method "question"
                       :params (:questions [(:id "q1" :question "Which?"
                                             :options [(:label "a")])])))
       (agent-session-deny)
       (should (equal (car written)
                      '(:jsonrpc "2.0" :id "dsh-4"
                        :result (:answers [(:id "q1" :selected [])]))))))))
;;; Questions

(defmacro agent-session-test--answering (replies &rest body)
  "Run BODY with the minibuffer answering REPLIES in order.
A list reply answers a `completing-read-multiple'; once REPLIES run out,
the user quits."
  (declare (indent 1))
  `(let ((replies ,replies)
         (prompts nil))
     (cl-letf* ((reply (lambda (prompt &rest _)
                        (push prompt prompts)
                        (if replies (pop replies) (signal 'quit nil))))
                ((symbol-function 'completing-read) reply)
                ((symbol-function 'completing-read-multiple) reply)
                ((symbol-function 'read-string) reply)
                ((symbol-function 'read-number) reply)
                ((symbol-function 'read-passwd) reply))
       ,@body)
     (should-not replies)
     (nreverse prompts)))

(ert-deftest agent-session-test-questions ()
  "Questions wait in one footer line and are answered in the minibuffer.
Typed text besides the options is a custom answer, empty input leaves a
question unanswered, and quitting halfway keeps the answers so far."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (answers :none))
     (agent-session-tool session "t1" :kind 'question :title "选方案" :status 'running)
     (agent-session-ask-questions
      session :tool "t1"
      :questions '((:question "用哪种认证？" :header "认证" :detail "影响登录页"
                    :options (("OAuth" . "第三方登录") ("JWT")) :other t)
                   (:question "要哪些功能？" :options (("A") ("B") ("C")) :multi t :other t)
                   (:question "名字？")
                   (:question "几页？" :range (1 10 "页"))
                   (:question "备注？"))
      :callback (lambda (value) (setq answers value)))
     ;; Every question shows, the keys on a line of their own
     (should (string-search (concat " ? 1. [认证] 用哪种认证？\n"
                                    " ? 2. 要哪些功能？（可多选）\n"
                                    " ? 3. 名字？\n ? 4. 几页？\n ? 5. 备注？\n"
                                    "   C-c C-y 回答 · C-c C-n 不回答\n")
                            (agent-session-test--footer)))
     (should-not (string-search "OAuth" (agent-session-test--footer)))
     (should (string-match-p "选方案.*等待回答" (agent-session-test--transcript)))
     (should (string-match-p "等待回答" (agent-session-test--mode-line)))
     ;; Options keep their order and show their descriptions
     (let ((table (agent-session--option-table '(("OAuth" . "第三方登录") ("JWT")))))
       (should (equal (all-completions "" table) '("OAuth" "JWT")))
       (let ((metadata (cdr (funcall table "" nil 'metadata))))
         (should (equal (funcall (alist-get 'annotation-function metadata) "OAuth")
                        "  第三方登录"))
         (should-not (funcall (alist-get 'annotation-function metadata) "JWT"))))
     ;; Quit after the first two questions
     (let ((prompts (agent-session-test--answering '("OAuth" ("B" "A" "D"))
                      (should (eq (condition-case nil (agent-session-approve) (quit 'quit))
                                  'quit)))))
       (should (string-search "影响登录页\n[认证] 用哪种认证？（1/5）" (car prompts)))
       (should (string-search "要哪些功能？（可多选，逗号分隔）（2/5）" (cadr prompts))))
     (should (eq answers :none))
     (should (string-search (concat " ? 1. [认证] 用哪种认证？  → OAuth\n"
                                    " ? 2. 要哪些功能？（可多选）  → A、B、D\n"
                                    " ? 3. 名字？\n")
                            (agent-session-test--footer)))
     (should (string-search "C-c C-y 继续回答" (agent-session-test--footer)))
     ;; Sending the empty input area goes on from there; a number must lie in
     ;; its range
     (goto-char (point-max))
     (agent-session-test--answering '("  小明 " 0 12 3 "")
       (agent-session-send-input))
     (should (equal answers '((:selected ("OAuth")) (:selected ("A" "B") :custom "D")
                              (:selected nil :custom "小明") (:selected nil :custom "3")
                              nil)))
     (should-not (agent-session--pending-asks session))
     (should (string-match-p "选方案.*已回答" (agent-session-test--transcript)))
     ;; A single question notes its answer; declining gives `cancel'
     (agent-session-ask-questions session :tool "t1" :questions '((:question "Q" :options (("x"))))
                                  :callback (lambda (value) (setq answers value)))
     (agent-session-test--answering '("x") (agent-session-answer-questions))
     (should (string-match-p "选方案.*x" (agent-session-test--transcript)))
     (agent-session-ask-questions session :questions '((:question "Q1") (:question "Q2"))
                                  :callback (lambda (value) (setq answers value)))
     (agent-session-deny)
     (should (eq answers 'cancel))
     (should-not (agent-session--pending-asks session)))))

(ert-deftest agent-session-test-claude-ask-user-question ()
  "Claude's AskUserQuestion is answered in the footer.
The answers go back keyed by question text, beside the original input."
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (written nil)
          (line (json-serialize
                 '(:type "control_request" :request_id "r1"
                   :request (:subtype "can_use_tool" :tool_name "AskUserQuestion"
                             :tool_use_id "tu1"
                             :input (:questions
                                     [(:question "Which?" :header "Lib" :multiSelect :false
                                       :options [(:label "a" :description "first")
                                                 (:label "b" :description "second")])
                                      (:question "Features?" :header "Feat" :multiSelect t
                                       :options [(:label "x" :description "") (:label "y" :description "")])
                                      (:question "Why?" :header "Why" :multiSelect :false
                                       :options [(:label "p" :description "") (:label "q" :description "")])])))
                 :false-object :false)))
     (cl-letf (((symbol-function 'agent-session-write) (lambda (_ object) (push object written))))
       (let ((agent-session-raw-message line))
         (agent-session-backend-handle
          'claude session (json-parse-string line :object-type 'plist :null-object nil
                                             :false-object nil)))
       (should (string-search "? 1. [Lib] Which?\n ? 2. [Feat] Features?（可多选）\n"
                              (agent-session-test--footer)))
       (agent-session-test--answering '("b" ("y" "z") "")
         (agent-session-approve))
       (let* ((response (plist-get (plist-get (car written) :response) :response))
              (input (plist-get response :updatedInput))
              (answers (gethash "answers" input)))
         (should (equal (plist-get response :behavior) "allow"))
         ;; The questions shown are sent back untouched
         (should (equal (json-serialize (gethash "questions" input) :false-object :false)
                        (let ((agent-session-raw-message line))
                          (json-serialize (agent-session-raw-json "request" "input" "questions")
                                          :false-object :false))))
         (should (equal (gethash "Which?" answers) "b"))
         (should (equal (gethash "Features?" answers) ["y" "z"]))
         (should (eq (gethash "Why?" answers 'none) 'none))))
     (should (equal (plist-get (agent-claude--tool-view session "AskUserQuestion"
                                                        '(:questions [(:question "Which?")]))
                               :title)
                    "Which?")))))

(ert-deftest agent-session-test-codex-user-input ()
  "Codex's request_user_input is answered keyed by question id."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (written nil))
     (cl-letf (((symbol-function 'agent-session-write) (lambda (_ object) (push object written))))
       (agent-session-backend-handle
        'codex session
        '(:id 7 :method "item/tool/requestUserInput"
          :params (:itemId "i1" :questions [(:id "q1" :header "H" :question "Pick?" :isOther t
                                             :options [(:label "a" :description "da")])
                                            (:id "q2" :header "T" :question "Token?" :isSecret t)])))
       (should (string-search "? 1. [H] Pick?\n ? 2. [T] Token?\n" (agent-session-test--footer)))
       (agent-session-test--answering '("a" "s3cret")
         (agent-session-approve))
       (let ((result (plist-get (car written) :result)))
         (should (equal (plist-get (car written) :id) 7))
         (should (equal (gethash "q1" (plist-get result :answers)) '(:answers ["a"])))
         (should (equal (gethash "q2" (plist-get result :answers)) '(:answers ["s3cret"])))))
     ;; The secret isn't shown back
     (should-not (string-search "s3cret" (buffer-string))))))

;;; Remote projects

(ert-deftest agent-session-test-remote-paths ()
  "Agents of a remote project see and name paths on its host."
  (should (equal (agent-session-process-directory "/ssh:dev:/srv/proj/") "/srv/proj/"))
  (should (equal (agent-session-process-directory "/tmp/proj/") "/tmp/proj/"))
  (should (equal (agent-session-expand-file-name "/srv/proj/a.rs" "/ssh:dev:/srv/proj/")
                 "/ssh:dev:/srv/proj/a.rs"))
  (should (equal (agent-session-expand-file-name "src/a.rs" "/ssh:dev:/srv/proj/")
                 "/ssh:dev:/srv/proj/src/a.rs"))
  (should (equal (agent-session-expand-file-name "src/a.rs" "/tmp/proj/") "/tmp/proj/src/a.rs"))
  (should (equal (agent-session-expand-file-name "/etc/hosts" "/tmp/proj/") "/etc/hosts")))

(ert-deftest agent-session-test-claude-project-dir ()
  "Claude history is read where the CLI files it: locally or on the host."
  (should (equal (agent-claude--project-dir "/tmp/my.proj/")
                 (expand-file-name "~/.claude/projects/-tmp-my-proj")))
  (should (equal (agent-claude--project-dir "/ssh:dev:/srv/my.proj/")
                 "/ssh:dev:~/.claude/projects/-srv-my-proj")))

(ert-deftest agent-session-test-worktree-dirs ()
  "Sessions of a project may run in the other git worktrees of its repository."
  (let ((worktrees (agent-session--parse-worktrees "\
worktree /src/emacs.d
HEAD 1111
branch refs/heads/main

worktree /src/emacs.d/.claude/worktrees/telega-ed2ff9
HEAD 2222
branch refs/heads/claude/telega-ed2ff9

worktree /src/emacs.d-feature
HEAD 3333
detached
")))
    (should (equal worktrees '("/src/emacs.d" "/src/emacs.d/.claude/worktrees/telega-ed2ff9"
                               "/src/emacs.d-feature")))
    (should (equal (agent-session-worktree-dirs "/src/emacs.d/" worktrees)
                   '(("/src/emacs.d/")
                     ("/src/emacs.d/.claude/worktrees/telega-ed2ff9/" . "telega-ed2ff9")
                     ("/src/emacs.d-feature/" . "emacs.d-feature"))))
    ;; From a worktree, the main checkout is a worktree too.
    (should (equal (agent-session-worktree-dirs "/src/emacs.d-feature/" worktrees)
                   '(("/src/emacs.d-feature/")
                     ("/src/emacs.d/" . "emacs.d")
                     ("/src/emacs.d/.claude/worktrees/telega-ed2ff9/" . "telega-ed2ff9"))))
    ;; A subdirectory of a repository is not one of its worktrees.
    (should (equal (agent-session-worktree-dirs "/src/emacs.d/lisp/" worktrees)
                   '(("/src/emacs.d/lisp/"))))
    (should (equal (agent-session-worktree-dirs "/src/emacs.d/" nil) '(("/src/emacs.d/"))))))

;; Claude Desktop runs sessions in worktrees under .claude/worktrees.
(ert-deftest agent-session-test-claude-worktree-dirs ()
  "Claude history covers the project's worktrees, removed Desktop ones too."
  (should (equal (agent-claude--history-dirs
                  '(("/src/emacs.d/")
                    ("/src/emacs.d/.claude/worktrees/telega-ed2ff9/" . "telega-ed2ff9")
                    ("/src/emacs.d-feature/" . "emacs.d-feature"))
                  '("-src-emacs-d" "-src-emacs-d--claude-worktrees-telega-ed2ff9"
                    "-src-emacs-d--claude-worktrees-gone-1a2b3c" "-src-other"))
                 '(("-src-emacs-d" "/src/emacs.d/" nil)
                   ("-src-emacs-d--claude-worktrees-telega-ed2ff9"
                    "/src/emacs.d/.claude/worktrees/telega-ed2ff9/" "telega-ed2ff9")
                   ("-src-emacs-d-feature" "/src/emacs.d-feature/" "emacs.d-feature")
                   ;; Removed: no longer listed by git, still filed by the CLI
                   ("-src-emacs-d--claude-worktrees-gone-1a2b3c"
                    "/src/emacs.d/.claude/worktrees/gone-1a2b3c/" "gone-1a2b3c")))))

(ert-deftest agent-session-test-codex-worktree-history ()
  "Codex threads of another worktree carry it; the project's own don't."
  (let ((items (agent-codex--history-items
                (vector (list :id "t1" :name "主仓库" :updatedAt 3000 :cwd "/src/p")
                        (list :id "t2" :preview "工作树里的\n第二行" :updatedAt 2000
                              :cwd "/Users/me/.codex/worktrees/ab12/p"))
                '(("/src/p/") ("/Users/me/.codex/worktrees/ab12/p/" . "p")))))
    (should (equal items '((:id "t1" :title "主仓库" :time 3000)
                           (:id "t2" :title "工作树里的" :time 2000
                                :root "/Users/me/.codex/worktrees/ab12/p/" :worktree "p")))))
  ;; A remote project lists only its root, by its path on the host.
  (should (equal (agent-codex--cwd "/ssh:dev:/srv/p/") "/srv/p")))

(ert-deftest agent-session-test-claude-worktree-history ()
  "Sessions of all worktrees merge newest first; worktree ones carry their root."
  (let* ((main (make-temp-file "agent-claude-main-" t))
         (tree (make-temp-file "agent-claude-tree-" t))
         (write (lambda (dir id text time)
                  (let ((file (expand-file-name (concat id ".jsonl") dir))
                        (coding-system-for-write 'no-conversion))
                    (with-temp-file file
                      (insert (json-serialize
                               (list :type "user" :message (list :role "user" :content text)))
                              "\n"))
                    (set-file-times file (seconds-to-time time))))))
    (unwind-protect
        (progn
          (funcall write main "a" "旧的" 1000)
          (funcall write tree "b" "工作树里的" 2000)
          (funcall write main "c" "新的" 3000)
          (let ((items (agent-claude--history-items
                        (list (list main "/src/p/" nil)
                              (list tree "/src/p/.claude/worktrees/t/" "t")
                              (list (expand-file-name "missing" main) "/x/" "x")))))
            (should (equal (mapcar (lambda (item) (plist-get item :id)) items) '("c" "b" "a")))
            (should (equal (nth 1 items) '(:id "b" :title "工作树里的" :time 2000.0
                                           :root "/src/p/.claude/worktrees/t/" :worktree "t")))
            (should-not (plist-member (car items) :root)))
          (should (equal (length (agent-claude--history-items (list (list main "/src/p/" nil)) 1))
                         1)))
      (delete-directory main t)
      (delete-directory tree t))))

(ert-deftest agent-session-test-list-worktree-history ()
  "A worktree session is labeled in the list and resumes in its worktree."
  (let ((root (file-name-as-directory (make-temp-file "agent-list-root-" t)))
        (agent-session-list--history (make-hash-table :test #'equal)))
    (unwind-protect
        (with-temp-buffer
          (puthash (cons root 'claude)
                   (list (list :id "wt-1" :title "维护状态" :time (float-time)
                               :root (expand-file-name ".claude/worktrees/gone/" root)
                               :worktree "gone"))
                   agent-session-list--history)
          (agent-session-list-mode)
          (setq agent-session-list--root root)
          (agent-session-list--render)
          (should (string-match-p "\\[gone\\] 维护状态" (buffer-string)))
          (goto-char (point-min))
          (search-forward "维护状态")
          (should (equal (plist-get (get-text-property (point) 'agent-session-entry) :root)
                         (expand-file-name ".claude/worktrees/gone/" root)))
          ;; The worktree was removed: say so instead of starting the CLI there.
          (let ((err (should-error (agent-session-list-open) :type 'user-error)))
            (should (string-match-p "已不存在" (cadr err))))
          (should-not (seq-find (lambda (b) (equal (agent-session-resume-id
                                                    (buffer-local-value 'agent-session--current b))
                                                   "wt-1"))
                                (agent-session-buffers))))
      (delete-directory root t))))

(ert-deftest agent-session-test-remote-mcp-commands ()
  "Remote agents reach emx through the relay; local ones run emx directly."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (setf (agent-session-root session) "/ssh:dev:/srv/proj/")
     (cl-letf (((symbol-function 'agent-remote-bridge) (lambda (_root) "/run/emx.sock"))
               ((symbol-function 'agent-session-skills-dir) #'ignore))
       (let* ((command (agent-claude--command session))
              (config (json-parse-string (cadr (member "--mcp-config" command))
                                         :object-type 'plist))
              (emacs (plist-get (plist-get config :mcpServers) :emacs))
              (args (plist-get emacs :args)))
         (should (equal (plist-get emacs :command) "python3"))
         (should (equal (aref args 2) "/run/emx.sock"))
         (should (equal (aref args 3) (buffer-name))))
       (let ((command (string-join (agent-codex--command session) " ")))
         (should (string-search "mcp_servers.emacs.command=\"python3\"" command))
         (should (string-search "\"/run/emx.sock\"" command))
         (should-not (string-search "mcp_servers.emacs.env" command)))))))

(ert-deftest agent-session-test-remote-codex-images ()
  "Images for a remote codex are uploaded to the host and named by that path."
  (cl-letf (((symbol-function 'agent-session-message-images) (lambda (_) '("/tmp/a.png")))
            ((symbol-function 'agent-session-message-text) (lambda (_) "看"))
            ((symbol-function 'agent-remote-upload)
             (lambda (root file) (concat (file-remote-p root 'localname) "up/" (file-name-nondirectory file)))))
    (should (equal (agent-codex--input "msg" "/ssh:dev:/srv/proj/")
                   (vector '(:type "text" :text "看")
                           '(:type "localImage" :path "/srv/proj/up/a.png"))))
    (should (equal (aref (agent-codex--input "msg" "/tmp/proj/") 1)
                   '(:type "localImage" :path "/tmp/a.png")))))

(ert-deftest agent-session-test-codex-toml-string ()
  "TOML strings escape quotes, backslashes and control characters."
  (should (equal (agent-codex--toml-string "a\"b\\c\nd\te") "\"a\\\"b\\\\c\\nd\\te\"")))

(ert-deftest agent-session-test-native-subagents-off ()
  "The CLIs don't start subagents of their own; Emacs runs subagents."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (cl-letf (((symbol-function 'agent-session-skills-dir) #'ignore))
       (should (equal (cadr (member "--disallowedTools" (agent-claude--command session)))
                      "Agent,Workflow,SendMessage,ListAgents"))
       (let ((agent-claude-disallowed-tools nil))
         (should-not (member "--disallowedTools" (agent-claude--command session))))
       (should (member "agents.enabled=false" (agent-codex--command session)))
       (let ((agent-codex-native-subagents t))
         (should-not (member "agents.enabled=false" (agent-codex--command session))))
       (let ((command (agent-dsh--command default-directory)))
         (should (equal (seq-filter (lambda (arg) (string-suffix-p ".yml" arg)) command)
                        (list agent-dsh--patch
                              (expand-file-name "no-subagents.yml"
                                                (file-name-directory agent-dsh--patch)))))
         (should (file-exists-p (car (last command)))))
       (let ((agent-dsh-native-subagents t))
         (should (equal (last (agent-dsh--command default-directory) 2)
                        (list "--patch" agent-dsh--patch))))))))

(ert-deftest agent-session-test-codex-foreign-thread ()
  "Notifications of another thread on the connection, such as a Codex
subagent's, neither end the turn nor show in the transcript."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-codex--set session :thread "parent")
     (agent-session-backend-handle
      'codex session '(:method "turn/started" :params (:threadId "parent" :turn (:id "t1"))))
     ;; A child's turn doesn't replace the one an interrupt goes to.
     (agent-session-backend-handle
      'codex session '(:method "turn/started" :params (:threadId "child" :turn (:id "t2"))))
     (should (equal (agent-codex--state session :turn) "t1"))
     (agent-session-backend-handle
      'codex session '(:method "item/agentMessage/delta"
                       :params (:threadId "child" :itemId "c1" :delta "from the child")))
     (agent-session-backend-handle
      'codex session '(:method "turn/completed" :params (:threadId "child" :turn (:id "t2"))))
     (should (eq (agent-session-status session) 'running))
     (should-not (string-search "from the child" (agent-session-test--transcript)))
     (agent-session-backend-handle
      'codex session '(:method "item/agentMessage/delta"
                       :params (:threadId "parent" :itemId "p1" :delta "from the parent")))
     (should (string-search "from the parent" (agent-session-test--transcript)))
     (agent-session-backend-handle
      'codex session '(:method "turn/completed" :params (:threadId "parent" :turn (:id "t1"))))
     (should (eq (agent-session-status session) 'idle)))))

(ert-deftest agent-session-test-skills ()
  "Skills Emacs gives are copied for the agent and replace the ones they supersede."
  (agent-session-test--with-session
   (let* ((home (make-temp-file "agent-skill-home-" t))
          (source (make-temp-file "agent-skill-src-" t))
          (process-environment (cons (concat "HOME=" home) process-environment))
          (agent-session-skills nil)
          (session agent-session--current))
     (unwind-protect
         (let ((skill (expand-file-name "SKILL.md" source))
               (target (expand-file-name
                        ".cache/emacs-agent/skills/.claude/skills/new-skill/SKILL.md" home)))
           (with-temp-file skill (insert "v1"))
           (agent-session-add-skill "new-skill" source "old-skill")
           (should (equal (agent-session-superseded-skills) '("old-skill")))
           ;; Copied under .claude/skills/ of the directory returned.
           (should (equal (file-truename (agent-session-skills-dir session))
                          (file-truename (expand-file-name ".cache/emacs-agent/skills/" home))))
           (should (equal (with-temp-buffer (insert-file-contents target) (buffer-string)) "v1"))
           ;; An up-to-date copy is not written again; a changed one is.
           (set-file-times target '(0 0))
           (agent-session-skills-dir session)
           (should (time-equal-p (file-attribute-modification-time (file-attributes target))
                                 '(0 0)))
           (with-temp-file skill (insert "v2"))
           (agent-session-skills-dir session)
           (should (equal (with-temp-buffer (insert-file-contents target) (buffer-string)) "v2"))
           ;; Once up to date, the host is not checked again until the skills
           ;; change: each check is a round trip for a remote project.
           (cl-letf (((symbol-function 'file-exists-p)
                      (lambda (_) (error "Checked the host again"))))
             (should (agent-session-skills-dir session)))
           ;; Claude adds the directory and turns the superseded skill off.
           (let ((command (agent-claude--command session)))
             (should (equal (file-truename (cadr (member "--add-dir" command)))
                            (file-truename (expand-file-name ".cache/emacs-agent/skills/" home))))
             (should (equal (json-parse-string (cadr (member "--settings" command))
                                               :object-type 'alist)
                            '((skillOverrides (old-skill . "off"))))))
           ;; Codex turns it off by name.
           (should (member "skills.config=[{name=\"old-skill\",enabled=false}]"
                           (agent-codex--command session)))
           ;; Without access to the host the agent starts without them.
           (cl-letf (((symbol-function 'agent-session--copy-skills)
                      (lambda (_) (error "No route to host"))))
             (should-not (agent-session-skills-dir session))))
       (delete-directory home t)
       (delete-directory source t)))))

(ert-deftest agent-session-test-remote-bridge-local-end ()
  "A relay connection is piped to an emx started for the session it names."
  (agent-session-test--with-session
   (let* ((dir (make-temp-file "agent-remote-test-" t))
          (socket (expand-file-name "emx.sock" dir))
          (server (agent-remote--listen socket))
          (status nil))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-session-emx-command) (lambda () '("cat"))))
           (cl-flet ((relay (name input)
                       ;; The relay's stderr is part of the output: it must
                       ;; stay quiet.
                       (let* ((output "")
                              (process (make-process
                                        :name "agent-remote-test-relay"
                                        :command (list "python3" "-c" agent-remote--relay socket name)
                                        :connection-type 'pipe :noquery t
                                        :filter (lambda (_p s) (setq output (concat output s))))))
                         ;; Like an agent: send a request and wait for the
                         ;; reply (or the connection to drop) before quitting.
                         (process-send-string process input)
                         (let ((deadline (+ (float-time) 5)))
                           (while (and (process-live-p process) (string-empty-p output)
                                       (< (float-time) deadline))
                             (accept-process-output nil 0.05)))
                         (setq status (and (not (process-live-p process))
                                           (process-exit-status process)))
                         (delete-process process)
                         output)))
             (should (equal (relay (buffer-name) "{\"ping\":1}\n") "{\"ping\":1}\n"))
             ;; A connection naming no session is dropped, possibly while the
             ;; relay still writes; it exits quietly.
             (should (equal (relay "*no such session*" "x\n") ""))
             (should (eql status 0))
             ;; The emx of a remote agent offers the config_* methods.
             (cl-letf (((symbol-function 'agent-session-emx-command)
                        (lambda () '("sh" "-c" "read _; echo \"$EMX_REMOTE_AGENT\""))))
               (should (equal (relay (buffer-name) "{}\n") "1\n")))))
       (delete-process server)
       (delete-directory dir t)))))

(ert-deftest agent-session-test-file-written-by-emx ()
  "emx writes a file only without unsaved edits, then its buffer is reverted."
  (let* ((file (make-temp-file "agent-ui-test-" nil ".txt" "old\n"))
         (buffer (find-file-noselect file)))
    (unwind-protect
        (progn
          (should-not (agent-ui-file-modified-p file))
          (should-not (agent-ui-file-modified-p (concat file ".missing")))
          (with-temp-file file (insert "new\n"))
          (agent-ui-file-written file)
          (should (equal (with-current-buffer buffer (buffer-string)) "new\n"))
          (with-current-buffer buffer (insert "edit"))
          (should (agent-ui-file-modified-p file))
          ;; A buffer with unsaved edits is left alone.
          (agent-ui-file-written file)
          (should (equal (with-current-buffer buffer (buffer-string)) "editnew\n")))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)
      (delete-file file))))

;;; Sessions asking for attention

(ert-deftest agent-session-test-alert ()
  "An agent's alert raises its entry, flashes it, and keeps it pink until opened."
  (agent-session-test--with-session
   (let* ((list-buffer (generate-new-buffer " *alert-list*"))
          (timers nil)
          (seen nil)
          (first-entry (lambda ()
                         "The buffer and alert face of the first live entry."
                         (with-current-buffer list-buffer
                           (goto-char (point-min))
                           (agent-session-list-next)
                           (let ((faces (ensure-list (get-text-property (point) 'face))))
                             (list (plist-get (get-text-property (point) 'agent-session-entry) :buffer)
                                   (cond ((memq 'agent-session-list-alert-flash faces) 'flash)
                                         ((memq 'agent-session-list-alert faces) 'pink))))))))
     (unwind-protect
         (cl-letf (((symbol-function 'run-with-timer)
                    (lambda (_delay _repeat fn &rest _) (setq timers (append timers (list fn)))))
                   ((symbol-function 'agent-session-list--refresh)
                    (lambda () (with-current-buffer list-buffer (agent-session-list--render))))
                   ((symbol-function 'agent-session-list--seen-p) (lambda (_) seen)))
           (agent-session-test-echo t)
           (with-current-buffer list-buffer
             (agent-session-list-mode)
             (setq agent-session-list--root temporary-file-directory))
           (agent-session-list--refresh)
           (let* ((target (seq-find (lambda (b) (not (eq b (car (funcall first-entry)))))
                                    (agent-session-buffers)))
                  (first (lambda () (with-current-buffer list-buffer (agent-session-list--render))
                           (funcall first-entry))))
             ;; Only the calling session's entry: the method takes no target.
             (should (eq (agent-session-test--call "alert" target :reason "测试跑完了") t))
             ;; It rises to the top, pink, before it flashes.
             (should (equal (funcall first-entry) (list target 'pink)))
             (should (= (length timers) 4))
             ;; Red, pink, red, pink, and it stays pink at the top.
             (should (equal (mapcar (lambda (timer) (funcall timer) (cadr (funcall first-entry)))
                                    timers)
                            '(flash pink flash pink)))
             (should (eq (car (funcall first-entry)) target))
             (with-current-buffer list-buffer
               (should (string-prefix-p "测试跑完了" (get-text-property (point) 'help-echo))))
             ;; Opening the session clears it, and it stays on top: it is now
             ;; the most recently used.
             (switch-to-buffer target)
             (with-current-buffer target
               (run-hook-with-args 'window-buffer-change-functions (selected-window)))
             (should (equal (funcall first) (list target nil)))
             (should-not (buffer-local-value 'agent-session-list--alert target))
             ;; Typing in it clears it too.
             (setq timers nil)
             (agent-session-list-alert target)
             (mapc #'funcall timers)
             (should (equal (funcall first-entry) (list target 'pink)))
             (with-current-buffer target (run-hooks 'post-command-hook))
             (should (equal (funcall first) (list target nil)))
             ;; Someone already looking at the session only sees the flash.
             (setq timers nil seen t)
             (agent-session-list-alert target)
             (mapc #'funcall timers)
             (should (equal (funcall first-entry) (list target nil))))
           ;; Callers that aren't sessions can't ask.
           (should-error (agent-session-test--call "alert" nil)))
       (kill-buffer list-buffer)))))

;;; Sessions working with each other (agent-collab)

(defun agent-session-test--call (method caller &rest params)
  "Call agent-ui METHOD with PARAMS as the agent of session buffer CALLER."
  (let ((agent-ui-caller (and caller (list :agent_buffer (buffer-name caller)))))
    (funcall (plist-get (alist-get method agent-ui--methods nil nil #'equal) :function)
             params)))

(defun agent-session-test--poll (pending)
  "Poll the deferred result PENDING once."
  (agent-ui--poll (cadr pending) nil))

(ert-deftest agent-session-test-handles ()
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (other (buffer-local-value 'agent-session--current (agent-session-test-echo t))))
     ;; Placeholder names are the agent's, made unique.
     (should (equal (agent-session-handle session) "test-echo"))
     (should (equal (agent-session-handle other) "test-echo-2"))
     (should (equal (agent-session-set-handle other "test-echo") "test-echo-2"))
     (should (equal (agent-session-set-handle other "cfi-meaning") "cfi-meaning"))
     (should (eq (agent-session-find "@cfi-meaning") other))
     (should (eq (agent-session-find "cfi-meaning") other))
     (should (eq (agent-session-find (buffer-name buffer)) session))
     (should-not (agent-session-find "@nothing"))
     (with-current-buffer buffer
       (should (string-match-p "@test-echo\\'" (agent-session-test--mode-line))))
     ;; @ completion offers the other sessions, not this one.
     (should (equal (mapcar #'car (agent-session--mention-candidates session))
                    '("cfi-meaning")))
     ;; Mentions get a note for the agent; the transcript keeps the user's text.
     (should (string-match-p "(@cfi-meaning is the Echo session"
                             (agent-collab--mention-note session "看下 @cfi-meaning 的结论")))
     (should (equal (agent-collab--mention-note session "mail me@cfi-meaning or @test-echo")
                    "mail me@cfi-meaning or @test-echo")))))

(ert-deftest agent-session-test-handle-names ()
  (should (equal (agent-collab--clean-handle "  CFI-Meaning\n") "cfi-meaning"))
  (should (equal (agent-collab--clean-handle "Sure!\n**Perf Tuning**") "perf-tuning"))
  (should-not (agent-collab--clean-handle "42"))
  (should-not (agent-collab--clean-handle ""))
  (agent-session-test--with-session
   (let ((session agent-session--current))
     ;; The agent's own command first, then the global one; missing ones are skipped.
     (let ((agent-collab-agent-handle-commands '((test-echo "sh" "-c" "own")))
           (agent-collab-handle-command '("sh" "-c" "global")))
       (should (equal (agent-collab--handle-commands session)
                      '(("sh" "-c" "own") ("sh" "-c" "global")))))
     (let ((agent-collab-agent-handle-commands '((codex "sh" "-c" "codex")))
           (agent-collab-handle-command '("sh" "-c" "global")))
       (should (equal (agent-collab--handle-commands session) '(("sh" "-c" "global")))))
     (let ((agent-collab-agent-handle-commands '((test-echo "no-such-program-x")))
           (agent-collab-handle-command nil))
       (should-not (agent-collab--handle-commands session))))))

(ert-deftest agent-session-test-handle-commands-run ()
  "Naming commands get a closed stdin, and one that hangs gives way to the next."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (agent-collab-handle-timeout 0.5))
     (cl-flet ((wait-for (handle)
                 (with-timeout (10 nil)
                   (while (not (equal (agent-session-handle session) handle))
                     (accept-process-output nil 0.05)))
                 (agent-session-handle session)))
       ;; Like `codex exec', read stdin to its end before answering.
       (agent-collab--name session "hi" '(("sh" "-c" "cat >/dev/null; echo Stdin Closed")))
       (should (equal (wait-for "stdin-closed") "stdin-closed"))
       (agent-collab--name session "hi" '(("sleep" "30") ("sh" "-c" "echo fallback")))
       (should (equal (wait-for "fallback") "fallback"))))))

(ert-deftest agent-session-test-session-read ()
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-set-handle session "reader")
     (agent-session-test--type "第一个问题")
     (agent-session-test--type "第二个问题")
     (agent-session-test--type "hold 第三个")
     (agent-session-tool session "t1" :kind 'command :title "make test" :status 'error
                         :output "boom")
     (agent-session-text session "thinking-1" "想一想" 'thinking)
     (let ((out (agent-session-test--call "session_read" nil :session "@reader")))
       (should (string-match-p "Turns 2-3 of 3\\. Earlier turns: call again with before=2\\." out))
       (should (string-match-p "## Turn 3 (in progress)" out))
       (should (string-match-p "- \\$ make test (failed)" out))
       (should (string-match-p "收到：第二个问题" out))
       (should-not (string-match-p "User:\n第一个问题" out))
       (should-not (string-match-p "想一想" out)))
     (let ((out (agent-session-test--call "session_read" nil :session "@reader"
                                          :before 2 :last 5 :tools "none")))
       (should (string-match-p "Turns 1-1 of 3\\.\n" out))
       (should (string-match-p "User:\n第一个问题" out)))
     (let ((out (agent-session-test--call "session_read" nil :session "@reader"
                                          :last 1 :tools "full")))
       (should (string-match-p "Tool \\$ make test (failed)\nboom" out)))
     (should-error (agent-session-test--call "session_read" nil :session "@reader"
                                             :tools "all"))
     (should-error (agent-session-test--call "session_read" nil :session "@nobody")))))

(ert-deftest agent-session-test-session-ask ()
  (agent-session-test--with-session
   ;; Test the confirmation regardless of the default and the user's setting.
   (let* ((agent-collab-confirm t)
          (session agent-session--current)
          (pending (progn (agent-session-open 'test-echo2 default-directory)
                          (agent-session-test--call "session_ask" buffer
                                                    :prompt "帮我看看这个 diff"
                                                    :session "@test-echo2"))))
     (should (eq (car pending) :agent-ui-pending))
     ;; Nothing is sent before the user confirms in the caller's footer.
     (should (eq (car (agent-session-test--poll pending)) :agent-ui-pending))
     (should (string-match-p "向 @test-echo2 发送消息" (agent-session-test--footer)))
     (agent-session-approve)
     (let ((reply (agent-session-test--poll pending)))
       (should (string-match-p "\\`Reply from @test-echo2 (Echo2):\n\n收到：帮我看看这个 diff" reply))
       (should (string-match-p "Sent by the Echo agent of session \"@test-echo\" through session_ask"
                               reply))
       (should-not (string-match-p "is the Echo session" reply)))
     (let ((listed (agent-session-test--call "sessions" buffer)))
       (should-not (plist-member listed :agents))
       (should (equal (sort (seq-map (lambda (s) (list (plist-get s :id) (plist-get s :yours)))
                                     (plist-get listed :sessions))
                            :key #'car)
                      '(("@test-echo" t) ("@test-echo2" :false)))))
     ;; Agents ask open sessions only: they can't start one or ask their own.
     (should-error (agent-session-test--call "session_ask" buffer :prompt "x"))
     (should-error (agent-session-test--call "session_ask" buffer :prompt "x"
                                             :session "@test-echo"))
     (should (= (length (agent-session-buffers)) 2))
     ;; Follow-ups go to the same session.
     (let ((agent-collab-confirm nil))
       (should (string-match-p
                "收到：再看看"
                (agent-session-test--poll
                 (agent-session-test--call "session_ask" buffer :prompt "再看看"
                                           :session "@test-echo2")))))
     ;; Declined: the agent gets an error.
     (let ((pending (agent-session-test--call "session_ask" buffer :prompt "第三次"
                                              :session "@test-echo2")))
       (agent-session-deny)
       (should-error (agent-session-test--poll pending) :type 'error))
     ;; Timed out before the user answered: the request closes.
     (let ((pending (agent-session-test--call "session_ask" buffer :prompt "第四次"
                                              :session "@test-echo2" :wait 1)))
       (plist-put (gethash (cadr pending) agent-ui--deferred) :deadline 0)
       (should-error (agent-session-test--poll pending))
       (should-not (agent-session--pending-asks session))))))

(ert-deftest agent-session-test-subagent-relations ()
  "A session started by another session's agent is linked to it: listed
under it, named in sessions and the mode line, and its messages show who
sent them."
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (child-buffer (agent-session-open 'test-echo2 default-directory nil nil
                                            (list :parent buffer)))
          (child (buffer-local-value 'agent-session--current child-buffer))
          (peer (buffer-local-value 'agent-session--current (agent-session-test-echo t)))
          (list-buffer (generate-new-buffer " *subagent-list*")))
     (unwind-protect
         (progn
           (should (eq (agent-session-parent child) session))
           (should-not (agent-session-parent session))
           (should (equal (agent-session-children session) (list child)))
           (should-not (agent-session-children peer))
           (with-current-buffer child-buffer
             (should (string-search "↖ @test-echo" (agent-session-test--mode-line))))
           (with-current-buffer buffer
             (should-not (string-search "↖" (agent-session-test--mode-line))))
           (let ((listed (seq-map (lambda (s) (list (plist-get s :id) (plist-get s :parent)
                                                    (plist-get s :children)))
                                  (plist-get (agent-session-test--call "sessions" buffer)
                                             :sessions))))
             (should (member '("@test-echo" :null ["@test-echo2"]) listed))
             (should (member '("@test-echo2" "@test-echo" []) listed)))
           ;; The child follows its parent in the session list, indented.
           (with-current-buffer list-buffer
             (agent-session-list-mode)
             (setq agent-session-list--root temporary-file-directory)
             (agent-session-list--render)
             (let ((text (buffer-string)))
               (should (string-match-p "\n  ○.*@test-echo  ×.*\n.*\n    ↳ .*@test-echo2  ×" text))
               (should (= (length (split-string text "@test-echo2  ×")) 2))))
           ;; A message from another session's agent names it, in the
           ;; transcript and for agents reading the session.
           (let ((agent-collab-confirm nil))
             (agent-session-test--poll
              (agent-session-test--call "session_ask" buffer :prompt "检查一下"
                                        :session (concat "@" (agent-session-handle peer)))))
           (with-current-buffer (agent-session-buffer peer)
             (should (string-search "▍ @test-echo\n" (agent-session-test--transcript)))
             (should-not (string-search "▍ 你" (agent-session-test--transcript))))
           (should (string-search "Message from @test-echo:"
                                  (agent-session-test--call
                                   "session_read" nil
                                   :session (concat "@" (agent-session-handle peer))))))
       (kill-buffer list-buffer)))))

(defmacro agent-session-test--with-profiles (&rest body)
  "Run BODY in a fake session, with test profiles and no confirmations."
  `(agent-session-test--with-session
    (let ((agent-collab-profiles
           '((worker :agent test-echo2 :model "big" :mode full :cost low
                     :description "Test worker.")
             (gone :agent no-such-agent :description "Not enabled.")))
          (agent-collab-confirm nil))
      ,@body)))

(defun agent-session-test--first-message (session)
  "Text of the first user message in SESSION's transcript."
  (seq-some (pcase-lambda (`(,_ . ,block))
              (and (eq (plist-get block :type) 'user) (plist-get block :text)))
            (agent-session--blocks-in-order session)))

(ert-deftest agent-session-test-session-start ()
  "An agent starts a session from a profile: under its own, named after the
profile, its mode capped by the caller's, the task last in its message."
  (agent-session-test--with-profiles
   (let ((session agent-session--current))
     (agent-session-configure session :mode 'edits)
     ;; The tool lists the enabled profiles.
     (let ((description (plist-get (seq-find (lambda (m) (equal (plist-get m :name) "session_start"))
                                             (agent-session-test--call "describe" buffer))
                                   :description)))
       (should (string-search "- worker: Echo2 big, low cost.  Test worker." description))
       (should-not (string-search "gone" description)))
     (should-error (agent-session-test--call "session_start" buffer :profile "gone" :prompt "x"))
     (should-error (agent-session-test--call "session_start" buffer :prompt "x"))
     (should-error (agent-session-test--call "session_start" buffer :profile "worker"
                                             :prompt "x" :context "fork"))
     ;; By default it returns at once.
     (let ((started (agent-session-test--poll
                     (agent-session-test--call "session_start" buffer :profile "worker"
                                               :prompt "实现 X" :title "实现 X"))))
       (should (string-match-p "\\`Started @worker (Echo2 big, fresh)" started)))
     (let ((child (agent-session-find "@worker")))
       (should (eq (agent-session-parent child) session))
       (should (equal (agent-session-display-title child) "实现 X"))
       (should (equal (agent-session-setting child :model) "big"))
       (should (eq (agent-session-setting child :mode) 'edits))
       (let ((message (agent-session-test--first-message child)))
         (should (string-prefix-p "Your task:\n实现 X\n\n(From the Echo agent of session \"@test-echo\""
                                  message))
         (should (string-suffix-p "You can't start sessions yourself.)" message)))
       (with-current-buffer (agent-session-buffer child)
         (should (string-search "▍ @test-echo\n" (agent-session-test--transcript))))
       ;; Its tools are exactly its parent's (forks keep the prompt cache).
       (should (equal (json-serialize (agent-session-test--call "describe"
                                                                (agent-session-buffer child)))
                      (json-serialize (agent-session-test--call "describe" buffer))))
       ;; It can't start sessions itself.
       (should-error (agent-session-test--call "session_start" (agent-session-buffer child)
                                               :profile "worker" :prompt "y")))
     ;; With wait, the final reply.
     (let ((reply (agent-session-test--poll
                   (agent-session-test--call "session_start" buffer :profile "worker"
                                             :prompt "实现 Y" :wait 30))))
       (should (string-match-p "\\`Reply from @worker-2 (Echo2):\n\n收到：Your task:\n实现 Y" reply)))
     ;; Only so many at work at once.
     (let ((agent-collab-max-active 2))
       (dolist (child (agent-session-children session))
         (agent-session-set-status child 'running))
       (should-error (agent-session-test--call "session_start" buffer :profile "worker"
                                               :prompt "z"))))))

(ert-deftest agent-session-test-session-start-confirm ()
  "A profile may ask the user first; declining starts nothing."
  (agent-session-test--with-profiles
   (let* ((agent-collab-profiles '((pricey :agent test-echo2 :confirm t :cost high)))
          (pending (agent-session-test--call "session_start" buffer :profile "pricey"
                                             :prompt "大任务")))
     (should (eq (car (agent-session-test--poll pending)) :agent-ui-pending))
     (should (string-match-p "启动子会话 pricey" (agent-session-test--footer)))
     (should-not (agent-session-find "@pricey"))
     (agent-session-deny)
     (should-error (agent-session-test--poll pending))
     (should-not (agent-session-find "@pricey"))
     (let ((pending (agent-session-test--call "session_start" buffer :profile "pricey"
                                              :prompt "大任务")))
       (agent-session-approve)
       (should (string-prefix-p "Started @pricey" (agent-session-test--poll pending)))))))

(ert-deftest agent-session-test-session-start-handoff ()
  "A handoff carries the caller's conversation before the task, the latest
turns that fit and the first; sessions started in one turn share it."
  (agent-session-test--with-profiles
   (let ((session agent-session--current))
     (dotimes (i 6) (agent-session-test--type (format "问题%d %s" i (make-string 300 ?x))))
     ;; An agent starts sessions during its turn.
     (agent-session-set-status session 'running)
     (let* ((agent-collab-handoff-limit 1500)
            (start (lambda ()
                     (agent-session-test--poll
                      (agent-session-test--call "session_start" buffer :profile "worker"
                                                :context "handoff" :prompt "接着做"))))
            (first (progn (funcall start)
                          (agent-session-test--first-message (agent-session-find "@worker")))))
       (should (string-prefix-p "Conversation handed over from session \"@test-echo\"" first))
       ;; The first message without its reply, the latest turn whole.
       (should (string-match-p "## Turn 1\nUser:\n问题0 x+\n\n(Turns 2-5 left out; read them \
with session_read.)\n\n## Turn 6 (in progress)\nUser:\n问题5 x+\n\nAssistant:\n收到：问题5" first))
       (should-not (string-search "收到：问题0" first))
       (should-not (string-search "问题3" first))
       (should (string-match-p "---\n\nYour task:\n接着做\n\n(From the Echo agent" first))
       (should (<= (length first) 2200))
       ;; A second session from the same turn gets the same history.
       (funcall start)
       (should (equal (agent-session-test--first-message (agent-session-find "@worker-2"))
                      first))
       ;; After another turn, the history moves on.
       (agent-session-set-status session 'idle)
       (agent-session-test--type "问题6")
       (funcall start)
       (should (string-search "问题6" (agent-session-test--first-message
                                       (agent-session-find "@worker-3"))))))))

(defun agent-session-test--last-user (session)
  "The last user block of SESSION, as (ID . BLOCK)."
  (seq-find (pcase-lambda (`(,_ . ,block)) (eq (plist-get block :type) 'user))
            (reverse (agent-session--blocks-in-order session))))

(ert-deftest agent-session-test-subagent-no-persistence ()
  "Every backend keeps the sessions agents start out of its saved history."
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (child (buffer-local-value 'agent-session--current
                                     (agent-session-open 'test-echo2 default-directory nil nil
                                                         (list :parent buffer))))
          sent restarted)
     (cl-letf (((symbol-function 'agent-session-skills-dir) #'ignore)
               ((symbol-function 'agent-codex--request)
                (lambda (_ method params &rest _) (push (cons method params) sent)))
               ((symbol-function 'agent-dsh--request)
                (lambda (_ method params &rest _) (push (cons method params) sent)))
               ((symbol-function 'agent-session-start-process) #'ignore)
               ((symbol-function 'agent-session-restart-process)
                (lambda (s) (push s restarted))))
       (should (member "--no-session-persistence" (agent-claude--command child)))
       (should-not (member "--no-session-persistence" (agent-claude--command session)))
       (agent-codex--start-thread-with-instructions child "/p" nil)
       (agent-codex--start-thread-with-instructions session "/p" nil)
       (should (eq (plist-get (cdr (assoc "thread/start" (reverse sent))) :ephemeral) t))
       (should-not (plist-member (cdr (assoc "thread/start" sent)) :ephemeral))
       (setq sent nil)
       (agent-session-backend-start 'dsh child)
       (should (equal (plist-get (cdr (assoc "initialize" sent)) :parent) "emacs"))
       (setq sent nil)
       (agent-session-backend-start 'dsh session)
       (should-not (plist-member (cdr (assoc "initialize" sent)) :parent))
       ;; Without a saved transcript Claude can't restart to change the effort.
       (agent-session-backend-apply-settings 'claude child '(:effort))
       (should-not restarted)
       (agent-session-backend-apply-settings 'claude session '(:effort))
       (should (equal restarted (list session)))))))

(ert-deftest agent-session-test-subagent-close-with-parent ()
  "Closing a session closes those it started, asking first if one works."
  (agent-session-test--with-profiles
   (let* ((child-of (lambda (parent)
                      (buffer-local-value 'agent-session--current
                                          (agent-session-open 'test-echo2 default-directory nil
                                                              nil (list :parent parent)))))
          (child (funcall child-of buffer))
          (answer nil)
          (asked nil))
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (prompt) (setq asked prompt) answer)))
       (agent-session-set-status child 'running)
       ;; Declined: both stay.
       (should-not (kill-buffer buffer))
       (should (string-match-p "@test-echo2 还在运行" asked))
       (should (buffer-live-p buffer))
       (should (buffer-live-p (agent-session-buffer child)))
       ;; Accepted: both go.
       (setq answer t)
       (should (kill-buffer buffer))
       (should-not (buffer-live-p (agent-session-buffer child)))
       ;; An idle child goes without asking.
       (setq buffer (agent-session-test-echo t) asked nil)
       (let ((idle (funcall child-of buffer)))
         (kill-buffer buffer)
         (should-not asked)
         (should-not (buffer-live-p (agent-session-buffer idle))))))))

(ert-deftest agent-session-test-subagent-mailbox ()
  "Replies the caller didn't wait for reach its agent once it is idle, in
one message, naming who sent them."
  (agent-session-test--with-profiles
   (let ((session agent-session--current))
     (agent-session-set-status session 'running)
     (should (string-match-p "will reach you as a message"
                             (agent-session-test--poll
                              (agent-session-test--call "session_start" buffer :profile "worker"
                                                        :prompt "任务一"))))
     ;; The child replied at once, but its parent is busy.
     (should (eq (plist-get (cdr (agent-session-test--last-user session)) :origin) nil))
     (agent-session-set-status session 'idle)
     (let ((mail (cdr (agent-session-test--last-user session))))
       ;; Mail neither titles nor names the session it goes to.
       (should (equal (agent-session-display-title session) "新会话"))
       (should (equal (agent-session-handle session) "test-echo"))
       (should (equal (plist-get mail :origin) "@worker"))
       (should (string-prefix-p "(Replies to messages you sent to other sessions, delivered \
by Emacs; not from the user.)" (plist-get mail :text)))
       (should (string-search "Reply from @worker (Echo2):\n\n收到：Your task:\n任务一"
                              (plist-get mail :text)))
       (should (string-search "See what it did with session_read session=@worker."
                              (plist-get mail :text))))
     ;; Several replies come together.
     (agent-session-set-status session 'running)
     (dolist (task '("任务二" "任务三"))
       (agent-session-test--poll
        (agent-session-test--call "session_start" buffer :profile "worker" :prompt task)))
     (agent-session-set-status session 'idle)
     (let ((mail (cdr (agent-session-test--last-user session))))
       (should (equal (plist-get mail :origin) "会话回复"))
       (should (string-search "任务二" (plist-get mail :text)))
       (should (string-search "任务三" (plist-get mail :text))))
     ;; A child closed before replying.
     (cl-letf (((symbol-function 'agent-session-backend-send) #'ignore))
       (agent-session-set-status session 'running)
       (agent-session-test--poll
        (agent-session-test--call "session_start" buffer :profile "worker" :prompt "任务四"))
       (kill-buffer (agent-session-buffer (agent-session-find "@worker-4")))
       (accept-process-output nil 0.05)
       (agent-session-set-status session 'idle))
     (should (string-search "@worker-4 ended without replying: @worker-4 was closed before \
it replied" (plist-get (cdr (agent-session-test--last-user session)) :text))))))

(ert-deftest agent-session-test-subagent-wait ()
  "A caller waiting for a child gets its reply, or a note once the child waits
for the user, and then the reply later as a message."
  (agent-session-test--with-profiles
   (let ((session agent-session--current))
     (agent-session-set-status session 'running)
     (let ((reply (agent-session-test--poll
                   (agent-session-test--call "session_start" buffer :profile "worker"
                                             :prompt "等我" :wait 30))))
       (should (string-prefix-p "Reply from @worker (Echo2)" reply)))
     ;; Answered through the wait: nothing more comes.
     (agent-session-set-status session 'idle)
     (should-not (plist-get (cdr (agent-session-test--last-user session)) :origin))
     (agent-session-set-status session 'running)
     (let* ((pending (cl-letf (((symbol-function 'agent-session-backend-send) #'ignore))
                       (agent-session-test--call "session_start" buffer :profile "worker"
                                                 :prompt "要确认" :wait 30)))
            (child (agent-session-find "@worker-2")))
       (should (eq (car (agent-session-test--poll pending)) :agent-ui-pending))
       (agent-session-ask child :title "运行 make" :choices '((allow "允许") (deny "拒绝"))
                          :callback #'ignore)
       (should (string-match-p "waiting for the user to confirm"
                               (agent-session-test--poll pending)))
       (agent-session-text child "r1" "确认后做完了")
       (agent-session-set-status child 'idle)
       (agent-session-set-status session 'idle)
       (should (string-search "确认后做完了"
                              (plist-get (cdr (agent-session-test--last-user session)) :text)))))))

(ert-deftest agent-session-test-subagent-limits ()
  "Children take no messages and send none; a parent may stop its own."
  (agent-session-test--with-profiles
   (let* ((session agent-session--current)
          (peer-buffer (agent-session-open 'test-echo2 default-directory))
          (peer (buffer-local-value 'agent-session--current peer-buffer)))
     (agent-session-test--poll
      (agent-session-test--call "session_start" buffer :profile "worker" :prompt "x"))
     (let ((child (agent-session-find "@worker")))
       (should-error (agent-session-test--call "session_ask" buffer :session "@worker"
                                               :prompt "再做点"))
       (should-error (agent-session-test--call "session_ask" (agent-session-buffer child)
                                               :session (concat "@" (agent-session-handle peer))
                                               :prompt "帮我"))
       (should-error (agent-session-test--call "session_stop" peer-buffer :session "@worker"))
       (should (equal (agent-session-test--call "session_stop" buffer :session "@worker")
                      "Stopped and closed @worker."))
       (should-not (buffer-live-p (agent-session-buffer child))))
     ;; Between the user's sessions, wait 0 sends and the reply comes as a message.
     (agent-session-set-status session 'running)
     (should (string-match-p "will reach you as a message"
                             (agent-session-test--poll
                              (agent-session-test--call "session_ask" buffer
                                                        :session (concat "@" (agent-session-handle peer))
                                                        :prompt "看看" :wait 0))))
     (agent-session-set-status session 'idle)
     (should (string-search "收到：看看"
                            (plist-get (cdr (agent-session-test--last-user session)) :text))))))

(ert-deftest agent-session-test-rpc-deferred ()
  (let* ((polls 0)
         (agent-ui--methods
          (cons (list "test_wait" :function
                      (lambda (_params)
                        (agent-ui-defer (lambda () (and (> (cl-incf polls) 1) (list "done"))))))
                agent-ui--methods))
         (dir (make-temp-file "agent-ui-rpc-" t))
         (req (expand-file-name "req.json" dir))
         (res (expand-file-name "res.json" dir)))
    (unwind-protect
        (cl-flet ((rpc (method &optional params)
                    (with-temp-file req
                      (insert (json-serialize (list :method method
                                                    :params (or params (make-hash-table))))))
                    (agent-ui-rpc req res)
                    (with-temp-buffer
                      (insert-file-contents res)
                      (json-parse-buffer :object-type 'plist))))
          (let ((id (plist-get (rpc "test_wait") :pending)))
            (should (stringp id))
            (should (equal (plist-get (rpc "_poll" (list :id id)) :pending) id))
            (should (equal (rpc "_poll" (list :id id)) '(:ok t :result "done")))
            (should (eq (plist-get (rpc "_poll" (list :id id)) :ok) :false))))
      (delete-directory dir t))))

(ert-deftest agent-session-test-dsh-history-worktrees ()
  "dsh sessions of another worktree resume there and carry its label."
  (should (equal (agent-dsh--history-items
                  '((:id "a" :cwd "/p" :title "修复\n细节" :time 2)
                    (:id "b" :cwd "/p/.claude/worktrees/x" :title "试验" :time 1))
                  '(("/p/") ("/p/.claude/worktrees/x/" . "x")))
                 '((:id "a" :title "修复" :time 2)
                   (:id "b" :title "试验" :time 1
                        :root "/p/.claude/worktrees/x/" :worktree "x")))))

(defmacro agent-session-test--with-fake-remote (&rest body)
  "Run BODY with /rpc:dev: paths treated as remote, on host paths after the prefix.
File name handlers are off, so tramp never tries to reach the host."
  `(cl-letf* ((file-name-handler-alist nil)
              (real (symbol-function 'file-remote-p))
              ((symbol-function 'file-remote-p)
               (lambda (file &optional identification connected)
                 (if (and (stringp file) (string-prefix-p "/rpc:dev:" file))
                     (pcase identification
                       ('localname (substring file (length "/rpc:dev:")))
                       (_ "/rpc:dev:"))
                   (funcall real file identification connected)))))
     ,@body))

(ert-deftest agent-session-test-dsh-remote ()
  "A remote dsh session uses host paths, the emx relay and an uploaded plugin."
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (local-root (agent-session-root session)))
     (agent-session-test--with-fake-remote
      (unwind-protect
          (progn
            (setf (agent-session-root session) "/rpc:dev:/home/u/p/")
            ;; Tool paths the agent reports are on the host
            (should (equal (agent-dsh--relative session "/home/u/p/src/a.rs") "src/a.rs"))
            ;; History asks for and matches host directories
            (should (equal (agent-dsh--host-dir "/rpc:dev:/home/u/p/") "/home/u/p"))
            (should (equal (agent-dsh--history-items
                            '((:id "a" :cwd "/home/u/p/.w/x" :title "t" :time 1))
                            '(("/rpc:dev:/home/u/p/") ("/rpc:dev:/home/u/p/.w/x/" . "x")))
                           '((:id "a" :title "t" :time 1
                                  :root "/rpc:dev:/home/u/p/.w/x/" :worktree "x"))))
            ;; emx is reached through the relay, which needs no environment
            (cl-letf (((symbol-function 'agent-remote-mcp-command)
                       (lambda (_) '("python3" "-c" "relay" "/sock" "buf"))))
              (let ((server (aref (agent-dsh--mcp-servers session) 0)))
                (should (equal (plist-get server :command) "python3"))
                (should (equal (plist-get server :args) ["-c" "relay" "/sock" "buf"]))
                (should-not (plist-member server :env))))
            ;; The plugin is uploaded once per content, the patch last
            (let (copied)
              (cl-letf (((symbol-function 'file-exists-p) (lambda (_) nil))
                        ((symbol-function 'make-directory) #'ignore)
                        ((symbol-function 'copy-file)
                         (lambda (from to &rest _) (push (cons (file-name-nondirectory from) to) copied))))
                (let ((patch (agent-dsh--patch-file "/rpc:dev:/home/u/p/")))
                  (should (string-match-p "\\`~/\\.cache/emacs-agent/dsh/[0-9a-f]\\{16\\}/emacs\\.yml\\'"
                                          patch))
                  (should (equal (mapcar #'car (reverse copied))
                                 '("emacs-bridge.mjs" "no-subagents.yml" "emacs.yml")))
                  (should (equal (file-name-directory (cdar copied))
                                 (file-name-directory (cdadr copied))))))
              ;; The second patch is named next to the first, in the host's terms
              (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t)))
                (let ((command (agent-dsh--command "/rpc:dev:/home/u/p/")))
                  (should (string-match-p
                           "\\`~/\\.cache/emacs-agent/dsh/[0-9a-f]\\{16\\}/no-subagents\\.yml\\'"
                           (car (last command))))))
              (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
                        ((symbol-function 'copy-file) (lambda (&rest _) (error "Copied again"))))
                (agent-dsh--patch-file "/rpc:dev:/home/u/p/"))))
        (setf (agent-session-root session) local-root))))))

(provide 'agent-session-test)
;;; agent-session-test.el ends here
