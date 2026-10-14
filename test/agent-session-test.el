;;; agent-session-test.el --- agent-session 的回归测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; 用一个假后端（立即回显）测试会话界面，不调用真实 agent。
;; 布局参考 telega：对话 | 页脚（分隔线、辅助行、提示符）| 输入区。
;; 运行：
;;   emacs --batch -L lisp/agent -l test/agent-session-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-session)
(require 'agent-session-list)
(require 'agent-claude)
(require 'agent-codex)

(cl-defmethod agent-session-backend-start ((_ (eql test-echo)) session)
  (agent-session-set-status session 'idle))

(cl-defmethod agent-session-backend-send ((_ (eql test-echo)) session text)
  (unless (string-prefix-p "hold" text)
    (agent-session-text session (format "reply-%s" text) (concat "收到：" text))
    (agent-session-set-status session 'idle)))

(cl-defmethod agent-session-backend-stop ((_ (eql test-echo)) _session) nil)

(defvar agent-session-test--steered nil "假后端收到的引导消息。")
(defvar agent-session-test--interrupted nil "假后端是否被中断。")

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
  "在一个新的假会话 buffer 中执行 BODY。"
  `(let ((default-directory temporary-file-directory)
         ;; 每个测试从默认设置开始，互不影响。
         (agent-session-last-settings nil)
         (before (agent-session-buffers))
         (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (agent-session-test-echo t))
           (with-current-buffer buffer
             (goto-char (point-max))
             ,@body))
       ;; 清理本测试新建的所有会话（包括切换 agent 时新开的）。
       (dolist (b (agent-session-buffers))
         (unless (memq b before) (kill-buffer b))))))

(defun agent-session-test--type (string)
  "在输入区末尾输入 STRING 并发送。"
  (goto-char (point-max))
  (insert string)
  (agent-session-send-input))

(defun agent-session-test--transcript ()
  "对话记录部分（页脚之前）的纯文本。"
  (buffer-substring-no-properties (point-min) (agent-session-tail agent-session--current)))

(defun agent-session-test--footer ()
  "页脚（分隔线、辅助行、提示符）的纯文本。"
  (buffer-substring-no-properties (agent-session-tail agent-session--current)
                                  (agent-session-input agent-session--current)))

(defun agent-session-test--mode-line ()
  "状态栏的纯文本（batch 中 `format-mode-line' 不求值 :eval，直接调用生成函数）。"
  (substring-no-properties (agent-session--mode-line agent-session--current)))

(ert-deftest agent-session-test-multiple-messages ()
  "可以连续发送多条消息，对话按顺序追加。"
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (agent-session-test--type "two")
   (should (string-match-p "one\\(.\\|\n\\)*收到：one\\(.\\|\n\\)*two\\(.\\|\n\\)*收到：two"
                           (agent-session-test--transcript)))))

(ert-deftest agent-session-test-transcript-read-only ()
  "对话记录与页脚只读，输入区可编辑。"
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
  "页脚：分隔线、提示符；排队消息与待确认请求显示在辅助行。"
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
  "在对话记录中打字会跳到输入区末尾。"
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (switch-to-buffer (current-buffer))
   (goto-char (point-min))
   (execute-kbd-macro "xy")
   (should (equal (agent-session--input-text agent-session--current) "xy"))))

(ert-deftest agent-session-test-point-out-of-prompt ()
  "光标不会停在提示符内。"
  (agent-session-test--with-session
   (switch-to-buffer (current-buffer))
   (goto-char (point-max))
   (execute-kbd-macro (kbd "x <left> <left> <left>"))
   (should (>= (point) (agent-session-input agent-session--current)))))

(ert-deftest agent-session-test-footer-keeps-input ()
  "重绘页脚（例如状态变化）时保留输入区内容与光标。"
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
  "忙时输入的消息排队，发出时移到对话末尾，记录顺序与实际一致。"
  (agent-session-test--with-session
   (agent-session-test--type "hold")            ; 后端不回应，会话保持运行中
   (agent-session-test--type "q1")
   (agent-session-test--type "q2")
   (should (equal (mapcar #'cdr (agent-session-queue agent-session--current)) '("q1" "q2")))
   (should (string-match-p "排队 2" (agent-session-test--mode-line)))
   (agent-session-set-status agent-session--current 'idle)
   (should-not (agent-session-queue agent-session--current))
   (should (string-match-p "hold\\(.\\|\n\\)*q1\\(.\\|\n\\)*收到：q1\\(.\\|\n\\)*q2\\(.\\|\n\\)*收到：q2"
                           (agent-session-test--transcript)))))

(defun agent-session-test--complete (_session input)
  "在会话输入区输入 INPUT（提示符与输入同一行），返回补全候选，随后清空输入。"
  (goto-char (point-max))
  (insert input)
  (prog1 (pcase-let ((`(,beg ,end ,table . ,_) (agent-session-completion-at-point)))
           (all-completions (buffer-substring-no-properties beg end) table))
    (delete-region (agent-session-input agent-session--current) (point-max))))

(ert-deftest agent-session-test-local-command ()
  "本地命令在 Emacs 中执行，不作为消息发出。"
  (agent-session-test--with-session
   (let ((agent-session-last-settings nil))
     (agent-session-test--type "/model big")
     (should (equal (agent-session-setting agent-session--current :model) "big"))
     (agent-session-test--type "/effort max")
     (should (equal (agent-session-setting agent-session--current :effort) "max"))
     ;; 换到不支持当前强度的模型时，强度恢复默认。
     (agent-session-test--type "/model small")
     (should-not (agent-session-setting agent-session--current :effort))
     (agent-session-test--type "/mode full")
     (should (eq (agent-session-setting agent-session--current :mode) 'full))
     (should-not (agent-session--has-conversation agent-session--current))
     ;; agent 自己的命令照常发出。
     (agent-session-test--type "/compact")
     (should (string-match-p "收到：/compact" (agent-session-test--transcript))))))

(ert-deftest agent-session-test-completion ()
  "/ 补全命令名与参数，@ 不在行首也能触发。"
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (should (member "/model" (agent-session-test--complete session "/mo")))
     (should (member "/compact" (agent-session-test--complete session "/com")))
     (should (equal (sort (agent-session-test--complete session "/model ") #'string<)
                    '("big" "small")))
     (should (equal (agent-session-test--complete session "/effort h") '("high")))
     ;; 第二行行首的 / 同样可以补全。
     (should (member "/model" (agent-session-test--complete session "说明\n/mo"))))))

(ert-deftest agent-session-test-completion-annotation-width ()
  "/ 补全的注释等宽（corfu 右对齐注释，等宽才能对齐成一列），弹窗不超出窗口。"
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
  "没有对话时原地切换 agent；有对话后新开会话并带上草稿。"
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
  "状态栏显示 agent、模型、推理强度、权限模式与状态。"
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
  "待确认的请求只显示在页脚；对话中只在关联的工具上标注等待与结果。"
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
  "思考默认折叠为一行，展开后显示全文。"
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
  "会话列表显示进行中的会话及其标题。"
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
  "防抖重绘的回调只重绘一次，不会再次安排自己（曾导致 Emacs 卡死）。"
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
  "对话记录中可见（未被折叠）的文本。"
  (let ((end (agent-session-tail agent-session--current)) (pos (point-min)) (parts nil))
    (while (< pos end)
      (let ((next (next-single-char-property-change pos 'invisible nil end)))
        (unless (invisible-p pos) (push (buffer-substring-no-properties pos next) parts))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(ert-deftest agent-session-test-fold-turn ()
  "回合结束后，过程折叠成摘要，最终回复保持可见；摘要可展开。"
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")              ; 回合进行中
     (agent-session-tool session "c1" :kind 'command :title "cargo test" :status 'ok)
     (agent-session-text session "mid" "先跑一下测试。")
     (agent-session-text-done session "mid")
     (agent-session-tool session "e1" :kind 'edit :title "a.rs" :status 'ok)
     (agent-session-tool session "e2" :kind 'edit :title "b.rs" :status 'error)
     (agent-session-text session "final" "改好了。")
     (agent-session-text-done session "final")
     ;; 进行中的回合不折叠
     (should (string-match-p "cargo test" (agent-session-test--visible-transcript)))
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should (string-match-p "执行了 3 个操作 · 1 条命令 · 2 次编辑 · 1 个失败 · 用时" visible))
       (should (string-match-p "改好了。" visible))
       (should-not (string-match-p "cargo test\\|先跑一下测试\\|a.rs" visible)))
     ;; 展开
     (goto-char (point-min))
     (search-forward "执行了")
     (push-button (button-start (button-at (point))))
     (should (string-match-p "▾ 执行了.*\\(.\\|\n\\)*cargo test\\(.\\|\n\\)*a.rs"
                             (agent-session-test--visible-transcript)))
     ;; 下一回合：之前的折叠不受影响，新回合结束后同样折叠
     (agent-session-test--type "第二个问题")
     (should (string-match-p "收到：第二个问题" (agent-session-test--visible-transcript))))))

(ert-deftest agent-session-test-fold-skips-queued ()
  "排队中的消息夹在上一回合中间时，不会把上一回合切断。"
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")
     (agent-session-tool session "c1" :kind 'command :title "step-1" :status 'ok)
     (agent-session-test--type "排队消息")          ; 运行中输入，排队
     (agent-session-tool session "c2" :kind 'command :title "step-2" :status 'ok)
     (agent-session-text session "final" "完成。")
     (agent-session-text-done session "final")
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should (string-match-p "执行了 2 个操作" visible))
       (should-not (string-match-p "step-1\\|step-2" visible))
       (should (string-match-p "完成。" visible))
       ;; 排队的消息发出后出现在末尾，并得到回复
       (should (string-match-p "完成。\\(.\\|\n\\)*排队消息\\(.\\|\n\\)*收到：排队消息" visible))))))

(ert-deftest agent-session-test-fold-interrupted-turn ()
  "没有最终回复的回合（例如被打断）只折叠到下一条用户消息为止。"
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")
     (agent-session-tool session "c1" :kind 'command :title "step-1" :status 'ok)
     (agent-session-set-status session 'idle)        ; 以工具调用结束，没有最终回复
     (agent-session-test--type "下一个问题")
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should-not (string-match-p "step-1" visible))
       (should (string-match-p "下一个问题\\(.\\|\n\\)*收到：下一个问题" visible))))))

(ert-deftest agent-session-test-fold-keeps-last-reply ()
  "被打断的回合：最后一段说明保持可见，前后的过程都折叠。"
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")
     (agent-session-tool session "c1" :kind 'command :title "step-1" :status 'ok)
     (agent-session-text session "m1" "我先改配置。")
     (agent-session-text-done session "m1")
     (agent-session-tool session "c2" :kind 'command :title "step-2" :status 'ok)
     (agent-session-set-status session 'idle)        ; 没有最终回复就结束了
     (agent-session-test--type "下一个问题")
     (agent-session-set-status session 'idle)
     (let ((visible (agent-session-test--visible-transcript)))
       (should (string-match-p "执行了 2 个操作" visible))
       (should (string-match-p "我先改配置。" visible))
       (should-not (string-match-p "step-1\\|step-2" visible))
       (should (string-match-p "下一个问题" visible)))
     ;; 展开后两段过程都出现
     (goto-char (point-min))
     (search-forward "执行了")
     (push-button (button-start (button-at (point))))
     (should (string-match-p "step-1\\(.\\|\n\\)*我先改配置。\\(.\\|\n\\)*step-2"
                             (agent-session-test--visible-transcript))))))

(ert-deftest agent-session-test-steer-queued ()
  "排队的消息可以转为引导：立刻送进当前回合，不再排队。"
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
  "M-RET：运行中直接以引导方式发送；空闲时等同普通发送。"
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (agent-session-test--steered nil))
     (goto-char (point-max)) (insert "先别发")
     (agent-session-steer-input)                    ; 空闲：普通发送
     (should (string-match-p "收到：先别发" (agent-session-test--transcript)))
     (should-not agent-session-test--steered)
     (agent-session-test--type "hold")
     (goto-char (point-max)) (insert "顺便加个测试")
     (agent-session-steer-input)
     (should (equal agent-session-test--steered '("顺便加个测试")))
     (should-not (agent-session-queue session)))))

(ert-deftest agent-session-test-steer-fallback ()
  "后端不支持引导时，中断当前回合并把消息排到最前。"
  (agent-session-test--with-session
   (let ((session agent-session--current)
         (agent-session-test--interrupted nil))
     (agent-session-test--type "hold")
     (agent-session-test--type "排在后面")
     (cl-letf (((symbol-function 'agent-session-backend-steer) #'ignore))
       (agent-session-steer session "请先做这个"))
     (should agent-session-test--interrupted)
     (should (equal (mapcar #'cdr (agent-session-queue session)) '("请先做这个" "排在后面")))
     ;; 中断后回合结束：先发引导的消息
     (agent-session-set-status session 'idle)
     (should (string-match-p "收到：请先做这个\\(.\\|\n\\)*收到：排在后面"
                             (agent-session-test--transcript))))))

(ert-deftest agent-session-test-cancel-queued ()
  "撤回排队的消息：从队列与对话中移除，放回输入区。"
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (agent-session-test--type "hold")
     (agent-session-test--type "写错了")
     (agent-session-cancel-queued)
     (should-not (agent-session-queue session))
     (should-not (string-match-p "写错了" (agent-session-test--transcript)))
     (should (equal (agent-session--input-text session) "写错了")))))

(ert-deftest agent-session-test-list-mouse ()
  "会话列表：单击条目打开会话，单击 × 结束会话。"
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
           ;; batch 中没有真实显示，直接构造带位置的鼠标事件。
           (cl-flet ((click (pos)
                       (agent-session-list-mouse-open
                        (list 'mouse-1 (list (selected-window) pos '(0 . 0) 0)))))
             ;; 单击条目的标题处：打开会话
             (goto-char (point-min))
             (search-forward "鼠标测试")
             (let (opened)
               (cl-letf (((symbol-function 'agent-session-display)
                          (lambda (b) (setq opened b) (selected-window))))
                 (click (match-beginning 0)))
               (should (eq opened session-buffer)))
             ;; 单击本会话那一条的 ×：确认后结束会话（列表中可能还有其他会话）
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

;; 回归：所有条目共用同一个 mouse-face 时，悬停会把相邻条目连成一片高亮。
(ert-deftest agent-session-test-list-hover-one-entry ()
  "会话列表：相邻两项的鼠标高亮区域互不相连。"
  (with-temp-buffer
    (agent-session-list--insert-entry '(:id "a") "  第一项\n")
    (agent-session-list--insert-entry '(:id "b") "  第二项\n")
    (goto-char (point-min))
    (let ((first (get-text-property (point) 'mouse-face))
          (second (progn (forward-line 1) (get-text-property (point) 'mouse-face))))
      (should (and first second (not (eq first second)))))
    ;; 行尾的空白伸到窗口右边缘并带高亮（整行高亮），条目最后的换行不带高亮（不溢出到下一行）
    (goto-char (point-min))
    (while (search-forward "\n" nil t)
      (should-not (get-text-property (1- (point)) 'mouse-face))
      (should (get-text-property (- (point) 2) 'mouse-face))
      (should (equal (get-text-property (- (point) 2) 'display) '(space :align-to right))))
    ;; 多行条目：悬停任一行，整个条目连成一片高亮
    (erase-buffer)
    (agent-session-list--insert-entry '(:id "c") "  第一行\n    第二行\n")
    (let ((face (get-text-property (point-min) 'mouse-face)))
      (should (= (next-single-property-change (point-min) 'mouse-face)
                 (1- (point-max))))
      (goto-char (point-max))
      (forward-line -1)
      (should (eq (get-text-property (point) 'mouse-face) face)))))

;; 同一会话在 Claude Desktop 等处同时打开时，显示它们写入会话记录的消息。
(ert-deftest agent-session-test-claude-sync ()
  "会话同步：只显示其他客户端的消息，半行留到下次，标记需要重新载入上下文。"
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
           ;; 最后一行还没写完
           (with-temp-file file
             (insert own orphan desktop-user (substring desktop-reply 0 20)))
           (agent-claude--sync session)
           (let ((text (agent-session-test--transcript)))
             (should-not (string-search "Emacs 里发的" text))
             ;; 没读到调用的工具结果不单独显示
             (should-not (string-search "无主结果" text))
             (should-not (agent-session--block session "t0"))
             (should (string-search "以下来自 Claude Desktop" text))
             (should (string-search "桌面端发的\n[图片]" text))
             (should-not (string-search "桌面端回复" text)))
           (should (agent-claude--state session :external))
           ;; 写完之后再同步：补上回复，来源提示不重复
           (with-temp-file file
             (insert own orphan desktop-user desktop-reply))
           (agent-claude--sync session)
           (let ((text (agent-session-test--transcript)))
             (should (string-search "桌面端回复" text))
             (should (= 1 (how-many "以下来自" (point-min) (point-max)))))
           (should (= (agent-claude--state session :sync-offset)
                      (file-attribute-size (file-attributes file)))))
       (delete-file file)))))

;; 图片：粘贴剪贴板中的图片、插入文件；发送时 Claude 用 base64，Codex 用本地路径。
(ert-deftest agent-session-test-images ()
  "图片附件：剪贴板粘贴、随消息发送、各后端的格式。"
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
           ;; 粘贴：剪贴板图片保存为文件，输入区插入占位
           (goto-char (point-max))
           (insert "看这张图 ")
           (agent-session-yank)
           (let ((file (car (agent-session-message-images (agent-session--input-text session)))))
             (should (file-exists-p file))
             (should (equal (with-temp-buffer (set-buffer-multibyte nil)
                                              (insert-file-contents-literally file) (buffer-string))
                            png))
             (agent-session-send-input)
             ;; 发出的消息带着图片；对话中显示占位
             (should (equal (agent-session-message-images sent) (list file)))
             (should (equal (agent-session-message-text sent) "看这张图"))
             (should (string-search "看这张图 [图片]" (agent-session-test--transcript)))
             ;; Claude：图片在前（base64），文字在后
             (let ((content (agent-claude--content sent)))
               (should (equal (plist-get (aref content 0) :type) "image"))
               (should (equal (base64-decode-string
                               (plist-get (plist-get (aref content 0) :source) :data))
                              png))
               (should (equal (aref content 1) '(:type "text" :text "看这张图"))))
             ;; Codex：文字与本地图片路径
             (should (equal (agent-codex--input sent)
                            (vector '(:type "text" :text "看这张图")
                                    (list :type "localImage" :path file))))
             ;; 没有图片时 Claude 仍发字符串
             (should (equal (agent-claude--content "纯文字") "纯文字")))
           ;; 剪贴板里有文字时按文字粘贴（例如 Finder 复制的文件）
           (cl-letf (((symbol-function 'gui-get-selection)
                      (lambda (_ type) (if (eq type 'TARGETS) [TARGETS STRING image/tiff] png))))
             (should-not (agent-session--clipboard-image))))
       (delete-directory agent-session-image-directory t)))))

(provide 'agent-session-test)
;;; agent-session-test.el ends here
