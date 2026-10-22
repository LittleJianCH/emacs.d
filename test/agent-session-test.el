;;; agent-session-test.el --- Tests for agent-session -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests the session UI with a fake backend (echoes immediately) instead of a real agent.
;; Layout modeled on telega: conversation | footer (separator, aux line, prompt) | input.
;; Run:
;;   emacs --batch -L lisp/agent -L lisp/agent/backend
;;     -l test/agent-session-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'agent-session)
(require 'agent-session-list)
(require 'agent-claude)
(require 'agent-codex)
(require 'agent-dsh)
(require 'agent-ui)
(require 'agent-collab)


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
(defvar agent-session-test--missing-program "agent-session-test-no-such-program")
(agent-session-define-agent test-missing :title "Missing" :backend test-echo
  :executable agent-session-test--missing-program)

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

(ert-deftest agent-session-test-root-survives-home-change ()
  "A local session retains its expanded root when subprocess HOME changes."
  (agent-session-test--with-session
   (let* ((root (expand-file-name "~/"))
          (buffer (agent-session-open 'test-echo "~/"))
          (session (buffer-local-value 'agent-session--current buffer))
          (process-environment (cons "HOME=/nonexistent-test-home" process-environment)))
     (should (equal (agent-session-root session) root))
     (should (equal (buffer-local-value 'default-directory buffer) root))
     (should (equal (agent-session-process-directory (agent-session-root session)) root)))))

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
   (cl-letf (((symbol-function 'agent-emx-history)
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

(ert-deftest agent-session-test-background-tasks ()
  "Running background tasks show a compact indicator while some run."
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (buffer (current-buffer)))
     (should-not (string-match-p "后台" (agent-session-test--mode-line)))
     (agent-session-set-info
      session :backgroundTasks
      (vector '(:id "a" :description "cargo test" :type "bash")
              '(:id "b" :description "npm run build" :type "bash")))
     (should (string-match-p "后台 2" (agent-session-test--mode-line)))
     (let* ((line (agent-session--mode-line session))
            (help (get-text-property (string-match "后台" line) 'help-echo line)))
       (should (string-match-p "cargo test" help))
       (should (string-match-p "npm run build" help)))
     ;; The sidebar shows it next to the status with the same tooltip.
     (with-temp-buffer
       (agent-session-list--insert-live buffer "  ")
       (let ((text (buffer-string)))
         (should (string-match-p "空闲.*后台 2.*Echo" text))
         (should (string-match-p "cargo test"
                                 (get-text-property (string-match "后台" text)
                                                    'help-echo text)))))
     (agent-session-set-info session :backgroundTasks (vector))
     (should-not (string-match-p "后台" (agent-session-test--mode-line))))))

(ert-deftest agent-session-test-model-short-name ()
  "Model names and ids shrink to a short name for the session list."
  (pcase-dolist (`(,name ,title ,short)
                 '(("Opus 5.5" "Claude" "Opus 5.5")
                   ("GPT-6.1-Sol" "Codex" "GPT 6.1 Sol")
                   ("MiMo-V2.6-Pro" "Pi" "MiMo V2.6 Pro")
                   ("DeepSeek V4 Pro (New)" "Pi" "DS V4 Pro")
                   ("opencode-go/deepseek-v4.1-flash" "Pi" "DS V4.1 Flash")
                   ("opencode-go/qwen3.8-max" "Pi" "Qwen3.8 Max")
                   ("claude-opus-5-5" "Claude" "Opus 5.5")
                   ("claude-haiku-4-5-20251001" "Claude" "Haiku 4.5")
                   ;; Another agent's Claude keeps its vendor.
                   ("Claude Haiku 5.5" "Pi" "Claude Haiku 5.5")
                   ("Claude" "Claude" "Claude")))
    (should (equal (agent-session-model-short-name name title) short))))

(ert-deftest agent-session-test-list-shows-model ()
  "The session list names the model a session runs, not just its agent."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (buffer (current-buffer))
         (line (lambda ()
                 (with-temp-buffer
                   (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 100)))
                     (agent-session-list--insert-live buffer "  "))
                   (buffer-string)))))
     ;; Nothing known about the model yet: the agent's title.
     (should (string-match-p "空闲  Echo · " (funcall line)))
     (agent-session-set-info session :model "opencode-go/deepseek-v4.1-flash")
     (should (string-match-p "空闲  DS V4.1 Flash · " (funcall line)))
     ;; A chosen model wins, and the tooltip names agent and model in full.
     (agent-session-configure session :model "big")
     (let ((text (funcall line)))
       (should (string-match-p "空闲  Big · " text))
       (should (equal (get-text-property (string-match "Big" text) 'help-echo text)
                      "Echo · Big"))))))

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

(ert-deftest agent-session-test-autonomous-turn ()
  "A turn that starts with a notice folds, marks unread and keeps its reply."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-set-status session 'running)
     (agent-session-notice session "后台任务完成：测试" 'agent-session-dim
                           "task-done" :turn-start t)
     (agent-session-tool session "c1" :kind 'command :title "cargo test" :status 'ok)
     (agent-session-text session "a1" "全部通过。")
     (agent-session-text-done session "a1")
     ;; The session isn't displayed: the finished turn is marked unread.
     (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
       (agent-session-set-status session 'idle))
     (should (eq (agent-session-status session) 'idle))
     (should (plist-get (agent-session-info session) :unread))
     (let ((visible (agent-session-test--visible-transcript)))
       (should (string-match-p "后台任务完成：测试" visible))
       (should (string-match-p "执行了 1 个操作" visible))
       (should (string-match-p "全部通过。" visible))
       (should-not (string-match-p "cargo test" visible)))
     ;; Expanding the notice's summary shows the folded step.
     (goto-char (point-min))
     (search-forward "执行了")
     (push-button (button-start (button-at (point))))
     (should (string-match-p "cargo test" (agent-session-test--visible-transcript))))))

(ert-deftest agent-session-test-autonomous-turn-after-idle-replay ()
  "An autonomous turn replayed as idle before its reply still folds later."
  (agent-session-test--with-session
   (let ((session agent-session--current))
     ;; Reconnect in the wake gap: the notice arrives, then the idle status.
     (agent-session-notice session "后台任务完成：测试" 'agent-session-dim
                           "task-done" :turn-start t)
     (agent-session-set-status session 'idle)
     (should (eq (plist-get (agent-session--block session "task-done") :fold) 'none))
     (agent-session-set-status session 'running)
     (agent-session-tool session "c1" :kind 'command :title "cargo test" :status 'ok)
     (agent-session-text session "a1" "全部通过。")
     (agent-session-text-done session "a1")
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should (string-match-p "执行了 1 个操作" visible))
       (should-not (string-match-p "cargo test" visible))))))

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

(ert-deftest agent-session-test-diagnostics-does-not-open-files ()
  "A read-only query never loads a file or runs its mode/local-variable hooks."
  (let ((file (make-temp-file "agent-diagnostics-")))
    (unwind-protect
        (cl-letf (((symbol-function 'find-file-noselect)
                   (lambda (&rest _) (ert-fail "Diagnostics opened a file"))))
          (should-error (agent-ui--method-diagnostics (list :path file)))
          (with-temp-buffer
            (setq buffer-file-name file buffer-file-truename (file-truename file))
            (cl-letf (((symbol-function 'flymake-diagnostics) (lambda (&rest _) nil)))
              (should (equal (agent-ui--method-diagnostics (list :path file)) [])))))
      (delete-file file))))

(ert-deftest agent-session-test-diagnostics-symlink ()
  "Diagnostics recognizes an already visited file through a symlink."
  (let* ((dir (make-temp-file "agent-diagnostic-link-" t))
         (file (expand-file-name "actual" dir))
         (link (expand-file-name "alias" dir)))
    (unwind-protect
        (progn
          (write-region "text" nil file nil 'silent)
          (make-symbolic-link file link)
          (with-temp-buffer
            (setq buffer-file-name file buffer-file-truename (file-truename file))
            (cl-letf (((symbol-function 'find-file-noselect)
                       (lambda (&rest _) (ert-fail "Visited a file")))
                      ((symbol-function 'flymake-diagnostics) (lambda (&rest _) nil)))
              (should (equal (agent-ui--method-diagnostics (list :path link)) [])))))
      (delete-directory dir t))))

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

(ert-deftest agent-session-test-handles ()
  (agent-session-test--with-session
   (let* ((agent-emx-config--value
           '(:collab (:prompts (:mention "(@%s is the %s session \"%s\"; read it with session_read.)"))))
          (session agent-session--current)
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

(ert-deftest agent-session-test-subagent-ask-mirror ()
  "A child's confirmations and questions also wait in its parent's footer,
named after the child; answering either settles both."
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          (child-buffer (agent-session-open 'test-echo2 default-directory nil nil
                                            (list :parent buffer)))
          (child (buffer-local-value 'agent-session--current child-buffer))
          (answers nil))
     ;; Approved in the parent.
     (agent-session-ask child :title "运行 make" :choices '((allow "允许") (deny "拒绝"))
                        :callback (lambda (key) (push key answers)))
     (should (string-search "@test-echo2：运行 make" (agent-session-test--footer)))
     (agent-session-approve)
     (should (equal answers '(allow)))
     (should-not (agent-session--pending-asks child))
     (should-not (agent-session--pending-asks session))
     ;; Denied in the child: the copy closes.
     (agent-session-ask child :title "删除文件" :choices '((allow "允许") (deny "拒绝"))
                        :callback (lambda (key) (push key answers)))
     (should (agent-session--pending-asks session))
     (with-current-buffer child-buffer (agent-session-deny))
     (should (equal answers '(deny allow)))
     (should-not (agent-session--pending-asks session))
     ;; Questions answered in the parent reach the child.
     (agent-session-ask-questions child :questions '((:question "用哪个库？" :options (("a") ("b"))))
                                  :callback (lambda (result) (push result answers)))
     (let ((prompts (agent-session-test--answering '("b") (agent-session-answer-questions))))
       (should (string-match-p "\\[@test-echo2\\] 用哪个库？" (car prompts))))
     (should (equal (car answers) '((:selected ("b")))))
     (should-not (agent-session--pending-asks child))
     ;; Closing the child closes what it left in the parent.
     (agent-session-ask child :title "推送" :choices '((allow "允许")) :callback #'ignore)
     (should (agent-session--pending-asks session))
     (agent-session-kill-quietly child-buffer)
     (should-not (agent-session--pending-asks session)))))

(ert-deftest agent-session-test-hidden-note ()
  "A note for the agent goes with a message but isn't shown, even when the
message waited in the queue, which keeps its sender."
  (agent-session-test--with-session
   (let ((session agent-session--current)
         sent)
     (cl-letf (((symbol-function 'agent-session-backend-send)
                (lambda (_ _ text) (push text sent))))
       (agent-session-set-status session 'running)
       (agent-session-submit session "查一下" "@other" "(Note for the agent.)")
       (should-not sent)
       (agent-session-set-status session 'idle)
       (should (equal sent '("查一下\n\n(Note for the agent.)")))
       (should (string-search "▍ @other\n查一下" (agent-session-test--transcript)))
       (should-not (string-search "Note for the agent" (agent-session-test--transcript)))))))

(ert-deftest agent-session-test-agent-message-fold ()
  "A long message from another session's agent shows its first lines until
expanded; the user's own messages stay whole."
  (agent-session-test--with-session
   (let* ((session agent-session--current)
          ;; hold: the fake agent doesn't echo it back.
          (long (concat "hold\n" (mapconcat (lambda (i) (format "第 %d 行" i))
                                            (number-sequence 2 10) "\n")))
          (id (agent-session-submit session long "@other")))
     (should (string-search "第 4 行\n  ▸ 还有 6 行，展开" (agent-session-test--transcript)))
     (should-not (string-search "第 5 行" (agent-session-test--transcript)))
     (should (string-search "▸ 还有 6 行，展开" (agent-session-test--transcript)))
     (agent-session--update session id :collapsed nil)
     (should (string-search "第 10 行" (agent-session-test--transcript)))
     (should (string-search "▾ 收起" (agent-session-test--transcript)))
     ;; Short ones and the user's own aren't folded.
     (agent-session-submit session "两行\n就够了" "@other")
     (agent-session-submit session (concat long "\n自己写的"))
     (should (string-search "自己写的" (agent-session-test--transcript)))
     (let ((transcript (agent-session-test--transcript)))
       (with-temp-buffer
         (insert transcript)
         (should (= 0 (how-many "▸ 还有" (point-min) (point-max))))
         (should (= 1 (how-many "▾ 收起" (point-min) (point-max))))))
     (agent-session-set-status session 'idle))))

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

(provide 'agent-session-test)
;;; agent-session-test.el ends here
