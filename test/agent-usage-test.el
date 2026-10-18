;;; agent-usage-test.el --- Local usage accounting tests -*- lexical-binding: t; -*-

;;; Commentary:

;; No CLI or network calls: exercise lifecycle hooks and real backend parsers.

;;; Code:

(require 'ert)
(require 'agent-usage)
(require 'agent-ui)
(require 'agent-codex)
(require 'agent-claude)
(require 'agent-dsh)

(defvar agent-usage-test--sent nil)
(cl-defmethod agent-session-backend-send ((_ (eql usage-test)) session text)
  (push (list session text) agent-usage-test--sent))

(defmacro agent-usage-test--with-scope (&rest body)
  "Run BODY with isolated journals and a live-looking fake session."
  (declare (indent 0) (debug t))
  `(let* ((agent-usage-directory (make-temp-file "agent-usage-" t))
          (agent-usage--dirty (make-hash-table :test #'equal))
          (agent-usage--journal-name "test.jsonl")
          (agent-usage--timer nil)
          (agent-usage-enabled t)
          (agent-usage-test--sent nil)
          (buffer (generate-new-buffer " *usage-test*"))
          (session (agent-session--make :agent 'usage-test :backend 'usage-test
					:root "/tmp/project/" :buffer buffer :status 'idle
					:state (list :resume "native")
					:settings '(:model "test-model"))))
     (unwind-protect
         (progn (agent-session--setup-buffer session) ,@body)
       (when (timerp agent-usage--timer) (cancel-timer agent-usage--timer))
       (when (get-buffer "*Agent 用量*") (kill-buffer "*Agent 用量*"))
       (kill-buffer buffer)
       (delete-directory agent-usage-directory t))))

(defun agent-usage-test--record (session)
  "Return SESSION's current usage record."
  (plist-get (agent-usage--state session) :record))

(defun agent-usage-test--codex (session turn total &optional last)
  "Send SESSION a Codex usage snapshot for TURN with TOTAL and LAST."
  (agent-codex--track-usage
   session (list :threadId "native" :turnId turn
                 :tokenUsage (list :total total :last (or last total)))))

(ert-deftest agent-usage-only-delivered-turns ()
  (agent-usage-test--with-scope
   ;; Status changes, history and external activity cannot open a scope.
   (agent-session-set-status session 'running)
   (agent-usage-record session "external" '(:total_tokens 10000))
   (should (zerop (length (plist-get (agent-usage-records) :records))))
   (agent-session-set-status session 'idle)
   (agent-session-send session "first")
   (let ((first (plist-get (agent-usage-test--record session) :id)))
     (agent-usage-record session "request" '(:input_tokens 10 :output_tokens 2))
     (agent-session-send session "second")
     (should (equal first (plist-get (agent-usage-test--record session) :id)))
     (should (= (length agent-usage-test--sent) 1))
     (agent-session-set-status session 'idle)
     (should (= (length agent-usage-test--sent) 2))
     (should-not (equal first (plist-get (agent-usage-test--record session) :id)))
     (agent-usage-record session "request" '(:total_tokens 7))
     (agent-session-set-status session 'idle)
     (let ((total (plist-get (agent-usage-query) :totals)))
       (should (= 2 (plist-get total :turns)))
       (should (= 19 (plist-get total :total_tokens)))))
   (agent-usage-record session "late" '(:total_tokens 9999))
   (should (= 19 (plist-get (plist-get (agent-usage-query) :totals) :total_tokens)))))

(ert-deftest agent-usage-steering-keeps-the-current-scope ()
  (agent-usage-test--with-scope
   (agent-session-send session "first")
   (let ((id (plist-get (agent-usage-test--record session) :id)))
     (cl-letf (((symbol-function 'agent-session-backend-steer) (lambda (&rest _) t)))
       (agent-session-steer session "steer"))
     (should (equal id (plist-get (agent-usage-test--record session) :id)))
     (should (= 1 (plist-get (plist-get (agent-usage-query) :totals) :turns))))))

(ert-deftest agent-usage-disabled-and-unknown ()
  (agent-usage-test--with-scope
   (let ((agent-usage-enabled nil)) (agent-session-send session "disabled"))
   (should-not (agent-usage--state session))
   (agent-session-set-status session 'idle)
   (agent-session-send session "unknown")
   (agent-session-set-status session 'exited)
   (let ((total (plist-get (agent-usage-query) :totals)))
     (should (= 1 (plist-get total :unknown_turns)))
     (should-not (plist-get total :total_tokens))
     (should-not (plist-get total :cost_usd)))))

(ert-deftest agent-usage-send-error-closes-scope ()
  (agent-usage-test--with-scope
   (cl-letf (((symbol-function 'agent-session-backend-send)
              (lambda (&rest _) (error "send failed"))))
     (should-error (agent-session-send session "fail")))
   (should-not (agent-usage--state session))
   (should (eq 'idle (agent-session-status session)))))

(ert-deftest agent-usage-snapshots-subsets-and-partial-updates ()
  (agent-usage-test--with-scope
   (agent-usage-begin session)
   (agent-usage-record session "r1" '(:input_tokens 100 :output_tokens 2
						    :cache_read_tokens 80 :reasoning_tokens 1) t)
   (dotimes (_ 3) (agent-usage-record session "r1" '(:output_tokens 5) t))
   (agent-usage-record session "r2" '(:input_tokens 20 :output_tokens 5))
   (let ((record (agent-usage-test--record session)))
     (should (= 130 (plist-get record :total_tokens)))
     (should (= 120 (plist-get record :input_tokens)))
     (should (= 80 (plist-get record :cache_read_tokens)))
     (should (equal "partial" (plist-get record :coverage))))
   (agent-usage-replace session '(:total_tokens 140 :model "actual"))
   (should (= 140 (plist-get (agent-usage-test--record session) :total_tokens)))
   (should (equal "actual" (plist-get (agent-usage-test--record session) :model)))
   (should (equal "complete" (plist-get (agent-usage-test--record session) :coverage)))))

(ert-deftest agent-usage-journal-restart-and-corruption ()
  (agent-usage-test--with-scope
   (setf (agent-session-root session) "/tmp/中文项目/")
   (agent-usage-begin session)
   (agent-usage-record session "r" '(:total_tokens 10))
   (agent-usage-flush)
   (agent-usage-record session "r" '(:total_tokens 20))
   (agent-usage-finish session 'idle)
   (agent-usage-flush)
   ;; Simulate an interrupted write and a structurally invalid record.
   (let ((coding-system-for-write 'utf-8-unix))
     (write-region "{broken\n{\"id\":\"bad\",\"date\":\"2026-01-01\"}\n"
                   nil (expand-file-name "other.jsonl" agent-usage-directory)))
   (let* ((agent-usage--dirty (make-hash-table :test #'equal))
          (loaded (agent-usage-records))
          (records (plist-get loaded :records)))
     (should (= 1 (length records)))
     (should (= 2 (plist-get loaded :invalid_lines)))
     (should (= 20 (plist-get (car records) :total_tokens)))
     (should (equal "/tmp/中文项目/" (plist-get (car records) :project))))))

(ert-deftest agent-usage-failed-write-is-retained ()
  (agent-usage-test--with-scope
   (agent-usage-begin session)
   (cl-letf (((symbol-function 'write-region) (lambda (&rest _) (error "disk full"))))
     (agent-usage-flush))
   (should (= 1 (hash-table-count agent-usage--dirty)))
   (agent-usage-flush)
   (should (zerop (hash-table-count agent-usage--dirty)))))

(ert-deftest agent-usage-calendar-periods ()
  (cl-letf (((symbol-function 'decode-time)
             (lambda (&rest _) '(0 30 12 1 3 2026 0 nil 0))))
    ;; Sunday March 1: Monday of the same week is in February.
    (should (equal "2026-02-23" (agent-usage--period-start "week")))
    (should (equal "2026-03-01" (agent-usage--period-start "month")))))

(ert-deftest agent-usage-groups-filters-and-remote-projects ()
  (agent-usage-test--with-scope
   (dolist (root '("/tmp/project/" "/ssh:host:/tmp/project/"))
     (setf (agent-session-root session) root)
     (agent-usage-begin session)
     (agent-usage-record session "r" '(:total_tokens 10))
     (agent-usage-finish session 'idle))
   (should (= 2 (length (plist-get (agent-usage-query) :groups))))
   (should (= 1 (length (plist-get (agent-usage-query :group "backend") :groups))))
   (should (= 1 (plist-get (plist-get (agent-usage-query :project "/tmp/project/")
                                      :totals) :turns)))
   (should (= 2 (length (plist-get (agent-usage-query :group "session") :groups))))
   (should (= 0 (plist-get (plist-get (agent-usage-query :backend "claude")
                                      :totals) :turns)))
   (should-error (agent-usage-query :period "bad"))
   (should-error (agent-usage-query :group "bad"))))

(ert-deftest agent-usage-codex-native-turns-and-baselines ()
  (agent-usage-test--with-scope
   (setf (agent-session-backend session) 'codex)
   (agent-codex--set session :thread "native")
   ;; An idle history snapshot is only a baseline, even with a large last count.
   (agent-usage-test--codex session "history" '(:inputTokens 1000 :outputTokens 100
							     :totalTokens 1100))
   (should-not (agent-usage--state session))
   (agent-usage-begin session)
   (agent-codex--set session :usage-turn "own")
   (let ((usage '(:inputTokens 1100 :outputTokens 120 :cachedInputTokens 80
			       :reasoningOutputTokens 10 :totalTokens 1220)))
     (dotimes (_ 3) (agent-usage-test--codex session "own" usage)))
   (should (= 120 (plist-get (agent-usage-test--record session) :total_tokens)))
   (agent-usage-test--codex session "external" '(:inputTokens 1200 :outputTokens 130
							      :totalTokens 1330))
   (should (= 120 (plist-get (agent-usage-test--record session) :total_tokens)))
   (agent-usage-test--codex session "own" '(:inputTokens 1220 :outputTokens 135
							 :totalTokens 1355))
   (should (= 145 (plist-get (agent-usage-test--record session) :total_tokens)))))

(ert-deftest agent-usage-codex-missing-baseline-and-reset ()
  (agent-usage-test--with-scope
   (agent-codex--set session :thread "native")
   (agent-codex--set session :usage-turn "own")
   (agent-usage-begin session)
   (agent-usage-test--codex session "own" '(:totalTokens 10000))
   (should-not (plist-get (agent-usage-test--record session) :total_tokens))
   (agent-usage-test--codex session "own" '(:totalTokens 10020))
   (should (= 20 (plist-get (agent-usage-test--record session) :total_tokens)))
   (should (equal "partial" (plist-get (agent-usage-test--record session) :coverage)))
   (agent-usage-test--codex session "own" '(:totalTokens 0))
   (agent-usage-test--codex session "own" '(:totalTokens 5))
   (should (= 25 (plist-get (agent-usage-test--record session) :total_tokens)))))

(ert-deftest agent-usage-claude-disjoint-input-and-stream-dedup ()
  (agent-usage-test--with-scope
   (agent-usage-begin session)
   (dotimes (_ 2)
     (agent-claude--track-stream-usage
      session '(:event (:type "message_start"
                              :message (:id "r" :model "actual"
					    :usage (:input_tokens 10 :cache_read_input_tokens 70
								  :cache_creation_input_tokens 20 :output_tokens 0))))))
   (agent-claude--track-stream-usage
    session '(:event (:type "message_delta" :usage (:output_tokens 5))))
   (should (= 105 (plist-get (agent-usage-test--record session) :total_tokens)))
   (agent-claude--track-stream-usage
    session '(:parent_tool_use_id "child" :event
				  (:type "message_start" :message
					 (:id "child-r" :usage (:input_tokens 1 :output_tokens 2)))))
   (should (= 108 (plist-get (agent-usage-test--record session) :total_tokens)))))

(ert-deftest agent-usage-claude-result-cumulative-and-children ()
  (agent-usage-test--with-scope
   (agent-claude--set session :usage-models 'empty)
   (agent-claude--set session :usage-cost 0)
   (agent-usage-begin session)
   (let ((message '(:session_id "native" :total_cost_usd 1.0
				:usage (:input_tokens 1 :output_tokens 1)
				:modelUsage (:actual (:inputTokens 10 :outputTokens 5
								   :cacheReadInputTokens 20
								   :cacheCreationInputTokens 5)))))
     (dotimes (_ 2) (agent-claude--track-result-usage session message)))
   ;; A duplicate final result must not replace the turn with a zero delta.
   (should (= 40 (plist-get (agent-usage-test--record session) :total_tokens)))
   (should (= 1.0 (plist-get (agent-usage-test--record session) :cost_usd)))
   (agent-usage-finish session 'idle)
   (agent-usage-begin session)
   (agent-claude--track-result-usage
    session '(:session_id "native" :total_cost_usd 1.5
			  :modelUsage (:actual (:inputTokens 15 :outputTokens 7
							     :cacheReadInputTokens 20
							     :cacheCreationInputTokens 5))))
   (should (= 7 (plist-get (agent-usage-test--record session) :total_tokens)))
   (should (= 0.5 (plist-get (agent-usage-test--record session) :cost_usd)))))

(ert-deftest agent-usage-claude-resume-and-process-restart ()
  (agent-usage-test--with-scope
   (agent-usage-begin session)
   (agent-claude--track-result-usage
    session '(:session_id "native" :total_cost_usd 100.0
			  :usage (:input_tokens 10 :output_tokens 2)
			  :modelUsage (:actual (:inputTokens 10000 :outputTokens 500))))
   (should (= 12 (plist-get (agent-usage-test--record session) :total_tokens)))
   (should-not (plist-get (agent-usage-test--record session) :cost_usd))
   (should (equal "partial" (plist-get (agent-usage-test--record session) :coverage)))
   (agent-usage-finish session 'idle)
   (agent-usage-begin session)
   (agent-claude--track-result-usage
    session '(:session_id "native" :total_cost_usd 101.0
			  :modelUsage (:actual (:inputTokens 10010 :outputTokens 505))))
   (should (= 15 (plist-get (agent-usage-test--record session) :total_tokens)))
   (should (= 1.0 (plist-get (agent-usage-test--record session) :cost_usd)))))

(ert-deftest agent-usage-claude-reset-session ()
  (agent-usage-test--with-scope
   (agent-claude--set session :usage-models '(:old (:inputTokens 1000 :outputTokens 50)))
   (agent-claude--set session :usage-cost 20)
   (agent-claude--set session :usage-session "old")
   (agent-usage-begin session)
   (agent-claude--track-result-usage
    session '(:session_id "new" :total_cost_usd 0.1
			  :modelUsage (:actual (:inputTokens 2 :outputTokens 3))))
   (should (= 5 (plist-get (agent-usage-test--record session) :total_tokens)))
   (should (= 0.1 (plist-get (agent-usage-test--record session) :cost_usd)))))

(ert-deftest agent-usage-dsh-attempt-snapshots ()
  (agent-usage-test--with-scope
   (agent-usage-begin session)
   (let ((params '(:id "attempt" :model "deepseek/model"
                       :usage (:inputTokens 10 :cacheReadTokens 20 :cacheWriteTokens 5
					    :outputTokens 3 :totalTokens 38))))
     (dotimes (_ 3) (agent-dsh--track-usage session params)))
   (agent-dsh--track-usage session '(:id "next" :usage (:inputTokens 1 :outputTokens 2)))
   (should (= 41 (plist-get (agent-usage-test--record session) :total_tokens)))
   ;; An old bridge without a stable attempt id is not safe to accumulate.
   (agent-dsh--track-usage session '(:usage (:totalTokens 99999)))
   (should (= 41 (plist-get (agent-usage-test--record session) :total_tokens)))))

(ert-deftest agent-usage-ui-query-and-page-navigation ()
  (agent-usage-test--with-scope
   (dolist (root '("/tmp/project/" "/tmp/other/"))
     (setf (agent-session-root session) root)
     (agent-usage-begin session)
     (agent-usage-record session "r" '(:total_tokens 10))
     (agent-usage-finish session 'idle))
   (let ((result (agent-ui--method-usage '(:period "all" :group "backend"))))
     (should (equal "emacs" (plist-get result :scope)))
     (should (= 20 (plist-get (plist-get result :totals) :total_tokens)))
     (should (stringp (json-serialize result))))
   (save-window-excursion
     (agent-usage-show)
     (should (derived-mode-p 'agent-usage-mode))
     (should (= 2 (length tabulated-list-entries)))
     (goto-char (point-min))
     (agent-usage-drill-down)
     (should (equal "turn" agent-usage--group))
     (should (= 1 (length tabulated-list-entries)))
     (revert-buffer)
     (should (= 1 (length tabulated-list-entries)))
     (agent-usage-back)
     (should (equal "project" agent-usage--group))
     (should (= 2 (length tabulated-list-entries))))))

(provide 'agent-usage-test)
;;; agent-usage-test.el ends here
