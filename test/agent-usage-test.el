;;; agent-usage-test.el --- Tests for agent-usage -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests what Emacs sends the usage service (records, quota readings),
;; the echo-area line, and, against a real isolated daemon on the fixtures of
;; test/fixtures/usage/, the usage page.  The sums and forecasts themselves
;; are tested in test/emx/usage.test.ts.
;; Run:
;;   emacs --batch --init-directory=. --eval '(setq my/use-evil nil)'
;;     -l init.el -l test/agent-usage-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-session)
(require 'agent-usage)
(require 'agent-emx)
(require 'agent-claude)
(require 'agent-codex)

;; Load tramp-rpc before ERT redirects the native-compilation cache for
;; `ert-run-tests-batch-and-exit': otherwise the first /rpc: name in the
;; quota test compiles the package into the throwaway cache, which is slow.
(require 'tramp-rpc nil t)

(defvar agent-usage-test--sent nil
  "Messages sent to the usage service in a test, newest first: (METHOD . PARAMS).")

(defmacro agent-usage-test--with-files (&rest body)
  "Run BODY capturing what is sent to the usage service, with clean state."
  (declare (indent 0) (debug t))
  `(let ((agent-usage-test--sent nil)
         (agent-usage--snapshot nil)
         (agent-usage-change-functions nil))
     (cl-letf (((symbol-function 'agent-usage--notify)
                (lambda (method params) (push (cons method params) agent-usage-test--sent)))
               ((symbol-function 'agent-usage--request)
                (lambda (method params _callback)
                  (push (cons method params) agent-usage-test--sent))))
       ,@body)))

(defun agent-usage-test--session (&optional agent)
  "Make a local test session for AGENT, claude by default."
  (agent-session--make
   :agent (or agent 'claude)
   :backend (or agent 'claude)
   :root "/tmp/proj/"
   :info (list :handle "h1" :model "claude-opus-5-5")))

(defun agent-usage-test--records ()
  "The records sent in this test, newest first, with Lisp-style keys."
  (cl-loop for (method . params) in agent-usage-test--sent
           when (equal method "record")
           collect (cl-loop for (key value) on (plist-get params :record) by #'cddr
                            append (pcase key
                                     (:cache_read (list :cache-read value))
                                     (:cache_write (list :cache-write value))
                                     (:agent (list :agent (intern value)))
                                     (_ (list key value))))))

(defun agent-usage-test--records-of (model)
  "Records of MODEL sent in this test, newest first."
  (seq-filter (lambda (record) (equal (plist-get record :model) model))
              (agent-usage-test--records)))

(defun agent-usage-test--approx (a b)
  "Non-nil if A and B are the same number up to rounding."
  (and (numberp a) (numberp b) (< (abs (- a b)) 1e-9)))

(defun agent-usage-test--quota (agent &optional host)
  "The latest quota reading sent for AGENT on HOST, windows as a list."
  (cl-loop for (method . params) in agent-usage-test--sent
           when (and (equal method "quota")
                     (equal (plist-get params :agent) (symbol-name agent))
                     (equal (plist-get params :host) (or host :null)))
           return (plist-put (copy-sequence params) :windows
                             (append (plist-get params :windows) nil))))

(ert-deftest agent-usage-test-totals-delta ()
  "Running totals become per-model deltas; a new process proves its start."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session)))
      (setf (agent-session-process session) (make-symbol "process-1"))
      ;; Totals equal to the turn's own usage: the process started at zero.
      (should (equal (agent-usage-totals
                      session '(("opus" :input 100 :output 20)) '(:input 100 :output 20))
                     '(("opus" :input 100 :output 20))))
      (should (equal (agent-usage-totals
                      session '(("opus" :input 150 :output 30)
                                ("haiku" :input 10 :output 5))
                      '(:input 60 :output 15))
                     '(("opus" :input 50 :output 10)
                       ("haiku" :input 10 :output 5))))
      ;; An unchanged model adds no delta.
      (should (equal (agent-usage-totals
                      session '(("opus" :input 150 :output 30)
                                ("haiku" :input 20 :output 8))
                      '(:input 10 :output 3))
                     '(("haiku" :input 10 :output 3))))
      ;; A new process carrying on from the last totals (a resume).
      (setf (agent-session-process session) (make-symbol "process-2"))
      (should (equal (agent-usage-totals
                      session '(("opus" :input 160 :output 31)
                                ("haiku" :input 20 :output 8))
                      '(:input 10 :output 1))
                     '(("opus" :input 10 :output 1))))
      ;; One that restored older totals: below the last ones, so unknown;
      ;; the next report of the same process is a plain difference.
      (setf (agent-session-process session) (make-symbol "process-3"))
      (should (eq (agent-usage-totals session '(("opus" :input 120 :output 25))
                                      '(:input 5 :output 5))
                  'unknown))
      (should (equal (agent-usage-totals session '(("opus" :input 130 :output 26))
                                         '(:input 10 :output 1))
                     '(("opus" :input 10 :output 1))))
      ;; Forgotten totals (others added to the conversation): a process
      ;; that didn't start from zero is unknown.
      (agent-usage-forget-totals session)
      (setf (agent-session-process session) (make-symbol "process-4"))
      (should (eq (agent-usage-totals session '(("opus" :input 900 :output 90))
                                      '(:input 10 :output 1))
                  'unknown)))))

(ert-deftest agent-usage-test-claude-model-usage ()
  "Claude's cumulative modelUsage becomes one record per model and turn."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session 'claude)))
      (agent-claude--model-usage
       session
       (list :modelUsage (list :claude-opus-5-5
             (list :inputTokens 100 :outputTokens 20
                   :cacheReadInputTokens 30
                   :cacheCreationInputTokens 10)
             :claude-haiku-5-5
             (list :inputTokens 5 :outputTokens 2
                   :cacheReadInputTokens 0
                   :cacheCreationInputTokens 0))))
      (agent-claude--model-usage
       session
       (list :modelUsage (list :claude-opus-5-5
             (list :inputTokens 150 :outputTokens 30
                   :cacheReadInputTokens 40
                   :cacheCreationInputTokens 10)
             :claude-haiku-5-5
             (list :inputTokens 8 :outputTokens 3
                   :cacheReadInputTokens 0
                   :cacheCreationInputTokens 0))))
      (let ((opus (agent-usage-test--records-of "claude-opus-5-5"))
            (haiku (agent-usage-test--records-of "claude-haiku-5-5"))
            (all (agent-usage-test--records)))
        (should (= (length opus) 2))
        (should (= (length haiku) 2))
        (should (= (length all) 4))
        ;; Records are newest first: the second call's deltas come first.
        (should (equal (list (plist-get (nth 0 opus) :input)
                             (plist-get (nth 0 opus) :cache-read)
                             (plist-get (nth 0 opus) :cache-write)
                             (plist-get (nth 0 opus) :output))
                       '(50 10 0 10)))
        (should (equal (list (plist-get (nth 1 opus) :input)
                             (plist-get (nth 1 opus) :cache-read)
                             (plist-get (nth 1 opus) :cache-write)
                             (plist-get (nth 1 opus) :output))
                       '(100 30 10 20)))
        (should (equal (list (plist-get (nth 0 haiku) :input)
                             (plist-get (nth 0 haiku) :output))
                       '(3 1)))
        (should (equal (list (plist-get (nth 1 haiku) :input)
                             (plist-get (nth 1 haiku) :output))
                       '(5 2)))
        ;; Only the session's model counts the turn.
        (should (equal (mapcar (lambda (record) (plist-get record :turns)) opus)
                       '(1 1)))
        (should (equal (mapcar (lambda (record)
                                 (plist-get record :turns))
                               haiku)
                       '(0 0)))
        (dolist (record all)
          (should (eq (plist-get record :agent) 'claude))
          (should (equal (plist-get record :root) "/tmp/proj/"))
          (should (equal (plist-get record :session) "h1")))))))

(ert-deftest agent-usage-test-claude-restored-totals ()
  "A resumed CLI's restored totals aren't counted as the turn's usage."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session 'claude))
          (result (lambda (input output)
                    (list :modelUsage (list :claude-opus-5-5
                                            (list :inputTokens input :outputTokens output))
                          :usage (list :input_tokens 7 :output_tokens 3))))
          (inputs (lambda () (mapcar (lambda (record) (plist-get record :input))
                                     (agent-usage-test--records)))))
      ;; Opened from history: the totals the CLI restored are unknown, so
      ;; the first turn counts its own usage.
      (setf (agent-session-process session) (make-symbol "process-1"))
      (agent-claude--model-usage session (funcall result 1000 30))
      (agent-claude--model-usage session (funcall result 1010 33))
      ;; Restarted with --resume, the new process carries on from them.
      (setf (agent-session-process session) (make-symbol "process-2"))
      (agent-claude--model-usage session (funcall result 1017 36))
      ;; A fork of a running parent starts from zero.
      (setf (agent-session-process session) (make-symbol "process-3"))
      (agent-claude--model-usage session (funcall result 7 3))
      (should (equal (funcall inputs) '(7 7 10 7))))))

(ert-deftest agent-usage-test-codex-token-usage ()
  "Codex counts calls inside a turn, converting its input token count."
  (agent-usage-test--with-files
    (let* ((session (agent-usage-test--session 'codex))
           (total-1 (list :inputTokens 1000 :cachedInputTokens 200
                          :cacheWriteInputTokens 50 :outputTokens 100
                          :totalTokens 1350))
           (total-2 (list :inputTokens 2000 :cachedInputTokens 300
                          :cacheWriteInputTokens 50 :outputTokens 150
                          :totalTokens 2500))
           (total-3 (list :inputTokens 3000 :cachedInputTokens 400
                          :cacheWriteInputTokens 50 :outputTokens 200
                          :totalTokens 3650))
           (call-1 (list :tokenUsage
                         (list :last (list :inputTokens 1000
                                           :cachedInputTokens 200
                                           :cacheWriteInputTokens 50
                                           :outputTokens 100
                                           :totalTokens 1350)
                               :total total-1))))
      (agent-session-set-info session :model "gpt-5-codex")
      (agent-codex--set session :turn "t1")
      (agent-codex--token-usage session call-1)
      (let ((pending (plist-get (agent-session-state session) :usage-pending)))
        (should (equal (mapcar #'car pending) '("gpt-5-codex")))
        ;; Codex's input tokens include the cached and written ones.
        (should (equal (cdr (assoc "gpt-5-codex" pending))
                       '(:input 750 :cache-read 200 :cache-write 50
                         :output 100))))
      ;; A notification whose thread total hasn't changed is a repeat.
      (agent-codex--token-usage
       session
       (list :tokenUsage
             (list :last (list :inputTokens 999 :cachedInputTokens 0
                               :cacheWriteInputTokens 0 :outputTokens 0
                               :totalTokens 999)
                   :total total-1)))
      (should (equal (mapcar #'car
                             (plist-get (agent-session-state session)
                                        :usage-pending))
                     '("gpt-5-codex")))
      ;; Another model calls within the same turn.
      (agent-session-set-info session :model "gpt-5-mini")
      (agent-codex--token-usage
       session
       (list :tokenUsage
             (list :last (list :inputTokens 500 :cachedInputTokens 100
                               :cacheWriteInputTokens 0 :outputTokens 50
                               :totalTokens 650)
                   :total total-2)))
      (should (equal (mapcar #'car
                             (plist-get (agent-session-state session)
                                        :usage-pending))
                     '("gpt-5-codex" "gpt-5-mini")))
      ;; Usage outside a turn (a resumed thread) is not added.
      (agent-codex--set session :turn nil)
      (agent-codex--token-usage
       session
       (list :tokenUsage
             (list :last (list :inputTokens 3000 :cachedInputTokens 400
                               :cacheWriteInputTokens 50 :outputTokens 200
                               :totalTokens 3650)
                   :total total-3)))
      (should (= (length (plist-get (agent-session-state session)
                                    :usage-pending))
                 2))
      (agent-usage-end-turn session)
      (should-not (plist-get (agent-session-state session) :usage-pending))
      (let ((records (agent-usage-test--records)))
        (should (= (length records) 2))
        (let ((mini (car (agent-usage-test--records-of "gpt-5-mini")))
              (codex (car (agent-usage-test--records-of "gpt-5-codex"))))
          (should (equal (list (plist-get mini :input)
                               (plist-get mini :cache-read)
                               (plist-get mini :cache-write)
                               (plist-get mini :output))
                         '(400 100 0 50)))
          (should (equal (plist-get mini :turns) 0))
          (should (equal (list (plist-get codex :input)
                               (plist-get codex :cache-read)
                               (plist-get codex :cache-write)
                               (plist-get codex :output))
                         '(750 200 50 100)))
          (should (equal (plist-get codex :turns) 1)))))))

(ert-deftest agent-usage-test-claude-rate-limit ()
  "Claude's unified windows become labelled quota windows."
  (agent-usage-test--with-files
    (let* ((session (agent-usage-test--session 'claude))
           (t1 (+ (float-time) 600))
           (t2 (+ (float-time) 86400)))
      (agent-claude--rate-limit
       session
       (list :unifiedWindows
             (list :five_hour (list :utilization 0.6 :resetsAt t1)
                   :seven_day (list :utilization 0.13 :resetsAt t2))))
      (let* ((quota (agent-usage-test--quota 'claude))
             (windows (plist-get quota :windows)))
        (should (equal (mapcar (lambda (window)
                                 (plist-get window :label))
                               windows)
                       '("5h" "周")))
        (should (agent-usage-test--approx
                 (plist-get (nth 0 windows) :used) 0.6))
        (should (agent-usage-test--approx
                 (plist-get (nth 1 windows) :used) 0.13))
        (should (equal (plist-get (nth 0 windows) :resets) t1))
        (should (equal (plist-get (nth 1 windows) :resets) t2))))))

(ert-deftest agent-usage-test-codex-rate-limits ()
  "A Codex snapshot becomes a weekly window and credits, without a balance."
  (agent-usage-test--with-files
    (let* ((session (agent-usage-test--session 'codex))
           (resets (+ (float-time) 86400)))
      (agent-codex--rate-limits
       session
       (list :primary (list :usedPercent 15 :windowDurationMins 10080
                            :resetsAt resets)
             :secondary nil
             :credits (list :hasCredits t :unlimited nil :balance "62500.0")
             :planType "pro"))
      (let* ((quota (agent-usage-test--quota 'codex))
             (windows (plist-get quota :windows)))
        (should (= (length windows) 1))
        (should (equal (plist-get (car windows) :label) "周"))
        (should (agent-usage-test--approx
                 (plist-get (car windows) :used) 0.15))
        (should (equal (plist-get (car windows) :resets) resets))
        (should (agent-usage-test--approx (plist-get quota :credits) 62500.0))
        (should-not (plist-get quota :balance))
        (should (equal (plist-get quota :plan) "pro"))))))

(ert-deftest agent-usage-test-echo-text ()
  "The echo line shows windows, balances, reset windows and low faces."
  (agent-usage-test--with-files
    (let* ((agent-session-agents '((dsh :title "DeepSeek")
                                   (codex :title "Codex")
                                   (claude :title "Claude")))
           (future (+ (float-time) 3600))
           (later (+ (float-time) 86400))
           (past (- (float-time) 60))
           (claude-windows (list (list :id "five_hour" :label "5h" :used 0.6 :resets future)
                                 (list :id "seven_day" :label "周" :used 0.85
                                       :resets later))))
      ;; As emx pushes it: in display order, a remote host on an account
      ;; already listed marked as a duplicate.
      (setq agent-usage--snapshot
            (list (list :agent "claude" :host nil :time past :windows claude-windows)
                  (list :agent "codex" :host nil :time past
                        :windows (list (list :id "five_hour" :label "5h" :used 0.3
                                             :resets past)))
                  (list :agent "dsh" :host nil :time past
                        :balance (list (list :amount 12.3 :currency "CNY")))
                  (list :agent "claude" :host "dev" :time past :duplicate t
                        :windows claude-windows)
                  (list :agent "claude" :host "box" :time past
                        :windows (list (list :id "five_hour" :label "5h" :used 0.1
                                             :resets (+ future 60))))))
      (let ((text (agent-usage-echo-text)))
        (should text)
        (should (string-match-p "5h 40%" text))
        (should (string-match-p "¥12.30" text))
        (should (string-match-p "Claude .*Codex .*DeepSeek .*Claude@box" text))
        (should-not (string-match-p "@dev" text))
        ;; A window reset since it was reported says so.
        (should (string-match-p "已重置" text))
        ;; 15% left is a low-quota window.
        (let ((pos (string-match "周 15%" text)))
          (should pos)
          (should (eq (get-text-property pos 'face text)
                      'agent-usage-low)))))))

(ert-deftest agent-usage-test-set-quota ()
  "A quota reading goes to emx as JSON: windows in a vector, host or null."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session 'codex))
          (remote (agent-usage-test--session 'codex)))
      (setf (agent-session-root remote) "/rpc:host1:/x/")
      (agent-usage-set-quota session :windows (list (list :id "10080" :label "周"
                                                          :minutes 10080 :used 0.1
                                                          :resets 100))
                             :credits 'unlimited :plan nil)
      (agent-usage-set-quota remote :balance '((:amount 1.5 :currency "CNY")))
      (let ((local (cdar (last agent-usage-test--sent)))
            (host (cdar agent-usage-test--sent)))
        (should (equal (plist-get local :host) :null))
        (should (vectorp (plist-get local :windows)))
        (should (equal (plist-get local :credits) "unlimited"))
        ;; A nil value isn't sent: emx keeps the known one.
        (should-not (plist-member local :plan))
        (should (equal (plist-get host :host) "host1"))
        (should-not (plist-member host :windows))
        ;; Both serialize.
        (should (json-serialize local))
        (should (json-serialize host))))))

(ert-deftest agent-usage-test-record-drops-empty ()
  "A record with no tokens writes nothing and returns nil."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session)))
      (should-not (agent-usage-record session))
      (should-not (agent-usage-record
                   session :model "m" :input 0 :cache-read nil
                   :cache-write 0 :output nil))
      (should-not agent-usage-test--sent))))

(ert-deftest agent-usage-test-flush-on-exit ()
  "Usage of a turn whose process died, or whose buffer was killed, is kept."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session 'codex)))
      (agent-usage-add-call session "gpt" '(:input 10 :output 5))
      (setf (agent-session-status session) 'exited)
      (agent-usage--on-status session 'running)
      (should (= (length (agent-usage-test--records)) 1))
      (agent-usage-add-call session "gpt" '(:input 1 :output 1))
      (with-temp-buffer
        (setq-local agent-session--current session)
        (agent-usage--on-kill))
      (should (= (length (agent-usage-test--records)) 2)))))

(ert-deftest agent-usage-test-codex-unlimited-credits ()
  "Unlimited credits are sent as such; a snapshot without any sends none."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session 'codex)))
      (agent-codex--rate-limits session '(:credits (:unlimited nil :balance "42")))
      (should (= (plist-get (agent-usage-test--quota 'codex) :credits) 42))
      (agent-codex--rate-limits session '(:planType "pro"))
      (should-not (plist-member (agent-usage-test--quota 'codex) :credits))
      (agent-codex--rate-limits session '(:credits (:unlimited t :balance nil)))
      (should (equal (plist-get (agent-usage-test--quota 'codex) :credits) "unlimited")))))

;;; Clearing

(ert-deftest agent-usage-test-clear ()
  "Clearing asks first; declined, nothing is sent."
  (agent-usage-test--with-files
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
      (should-error (agent-usage-clear) :type 'user-error))
    (should-not agent-usage-test--sent)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
      (agent-usage-clear))
    (should (equal (caar agent-usage-test--sent) "clear"))))

;;; The usage page, against a real emx

(defconst agent-usage-test--fixtures
  (expand-file-name "fixtures/usage/" (file-name-directory (or load-file-name buffer-file-name)))
  "Ledger and quota files the page test serves.")

(defun agent-usage-test--wait (predicate)
  "Wait up to 10 s for PREDICATE to hold, reading the service's output."
  (let ((end (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) end))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(ert-deftest agent-usage-test-page ()
  "emx serves a report of the fixtures, and the page draws and filters it."
  (let* ((dir (make-temp-file "agent-usage-test-" t))
         (agent-usage-file (expand-file-name "agent-usage.jsonl" dir))
         (agent-usage-quota-file (expand-file-name "agent-quota.json" dir))
         (agent-usage-poll-interval 0)
         (agent-usage-pollers nil)
         (agent-usage--connection nil)
         (agent-usage--monitoring nil)
         (agent-usage--retry-timer nil)
         (agent-usage--outbox nil)
         (agent-usage--inflight (make-hash-table :test #'equal))
         (agent-emx-var-directory dir)
         (agent-emx--connections (make-hash-table :test #'equal))
         (agent-usage--snapshot nil)
         (agent-usage-change-functions nil)
         (agent-session-agents '((dsh :title "DeepSeek") (codex :title "Codex")
                                 (claude :title "Claude")))
         (process-environment (cons "TZ=Asia/Shanghai" process-environment))
         report)
    (make-directory (expand-file-name "emx" dir) t)
    (with-temp-file (expand-file-name "emx/config.json" dir)
      (insert "{\"collab\":{\"handleCommand\":[],\"agentHandleCommands\":{}},"
              "\"usage\":{\"pollInterval\":0}}"))
    (copy-file (expand-file-name "agent-usage.jsonl" agent-usage-test--fixtures)
               agent-usage-file)
    (copy-file (expand-file-name "agent-quota.json" agent-usage-test--fixtures)
               agent-usage-quota-file)
    (unwind-protect
        (progn
          (agent-usage--start)
          (should (agent-usage-test--wait (lambda () agent-usage--snapshot)))
          ;; The echo line from the pushed quotas: the remote Codex on its own
          ;; account is shown after this machine's agents.
          (should (string-match-p "Claude .*DeepSeek 余额 ¥9.03 .*Codex@dev"
                                  (agent-usage-echo-text)))
          ;; The fixtures' "now": 2026-10-21 12:00 in Shanghai.
          (agent-usage--request "report" (list :range "week" :filter (make-hash-table)
                                               :withoutCache :false :now 1792555200)
                                (lambda (result) (setq report result)))
          (should (agent-usage-test--wait (lambda () report)))
          (should (= (plist-get (plist-get report :total) :tokens) 3710))
          (with-temp-buffer
            (agent-usage-mode)
            (setq agent-usage--report report)
            (cl-letf (((symbol-function 'agent-usage--width) (lambda () 100))
                      ((symbol-function 'agent-usage--fetch) #'ignore))
              (agent-usage--render)
              (let ((page (buffer-string)))
                (should (string-match-p "3.7k" page))
                (should (string-match-p "Harness" page))
                (should (string-match-p "gpt-6.1-sol" page))
                (should (string-match-p "子 agent 1 轮" page))
                (should (string-match-p "Codex@dev" page))
                (should (string-match-p "统计中" page)))
              ;; The rows of the timeline, the peak's label included, line
              ;; up their columns: they are all as wide.
              (save-excursion
                (goto-char (point-min))
                (search-forward "每日趋势")
                (forward-line 1)
                (let (widths)
                  (dotimes (_ 5)
                    (push (string-width (buffer-substring (point) (line-end-position))) widths)
                    (forward-line 1))
                  (should (= (length (delete-dups widths)) 1))))
              ;; RET on a row filters to it and asks for that report.
              (goto-char (point-min))
              (search-forward "Harness")
              (re-search-forward "^  Claude")
              (agent-usage-select)
              (should (equal agent-usage--filter '(:agent "claude")))
              (agent-usage-unfilter)
              (should-not agent-usage--filter))))
      (setq agent-usage--monitoring nil)
      (when (timerp agent-usage--retry-timer) (cancel-timer agent-usage--retry-timer))
      (when (and agent-usage--connection
                 (process-live-p (agent-emx--connection-process agent-usage--connection)))
        (delete-process (agent-emx--connection-process agent-usage--connection)))
      (call-process "node" nil nil nil (expand-file-name "bin/emx" agent-emx--checkout)
                    "daemon" "--var" dir "--stop")
      (delete-directory dir t))))

;;; Service and migration

(ert-deftest agent-usage-test-migrate ()
  "The Lisp files of before become emx's JSON files, once; the old are kept."
  (let* ((dir (make-temp-file "agent-usage-migrate-" t))
         (agent-usage-file (expand-file-name "agent-usage.jsonl" dir))
         (agent-usage-quota-file (expand-file-name "agent-quota.json" dir)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "agent-usage.eld" dir)
            (insert "(:time 1.5 :agent claude :root \"~/a/\" :session \"h\" :child t :turns 1 :model \"m\" :input 2 :cache-read 3 :cache-write 4 :output 5 :cost 0.1)\n"
                    "(:time 2 :agent codex :input 1\n"
                    "(:time 3 :agent dsh :turns 0 :input 7)\n"))
          (with-temp-file (expand-file-name "agent-quota.eld" dir)
            (prin1 '(((claude) :time 9 :windows ((:id "five_hour" :label "5h" :minutes 300 :used 0.5
                                                      :resets 100 :history ((1 . 0.1) (2 . 0.5)))))
                     ((codex . "dev") :time 8 :credits unlimited :plan "pro" :windows nil))
                   (current-buffer)))
          (agent-usage--migrate)
          (let ((records (with-temp-buffer
                           (insert-file-contents agent-usage-file)
                           (mapcar (lambda (line) (json-parse-string line :object-type 'plist))
                                   (split-string (buffer-string) "\n" t))))
                (quotas (json-parse-string (with-temp-buffer
                                             (insert-file-contents agent-usage-quota-file)
                                             (buffer-string))
                                           :object-type 'plist :array-type 'list
                                           :null-object nil)))
            (should (= (length records) 2))
            (should (equal (plist-get (car records) :agent) "claude"))
            (should (equal (list (plist-get (car records) :cache_read)
                                 (plist-get (car records) :cache_write)
                                 (plist-get (car records) :child))
                           '(3 4 t)))
            (should-not (plist-member (car records) :cost))
            (should (equal (plist-get (cadr records) :model) :null))
            (should (equal (plist-get (car (plist-get (car quotas) :windows)) :history)
                           '((1 0.1) (2 0.5))))
            (should (equal (plist-get (cadr quotas) :host) "dev"))
            (should (equal (plist-get (cadr quotas) :credits) "unlimited")))
          (should (file-exists-p (expand-file-name "agent-usage.eld.bak" dir)))
          (should-not (file-exists-p (expand-file-name "agent-usage.eld" dir)))
          ;; Done once: a second run changes nothing.
          (let ((before (file-attribute-modification-time (file-attributes agent-usage-file))))
            (agent-usage--migrate)
            (should (equal before (file-attribute-modification-time
                                   (file-attributes agent-usage-file))))))
      (delete-directory dir t))))

(ert-deftest agent-usage-test-crash-reconnect ()
  "Idle usage monitoring restarts a killed daemon and flushes its outbox."
  (let* ((dir (make-temp-file "usage-crash-" t))
         (agent-emx-var-directory dir)
         (agent-usage-file (expand-file-name "agent-usage.jsonl" dir))
         (agent-usage-quota-file (expand-file-name "agent-quota.json" dir))
         (agent-usage-poll-interval 0)
         (agent-usage-pollers nil)
         (agent-usage--monitoring nil)
         (agent-usage--retry-timer nil)
         (agent-usage--retry-delay 0.05)
         (agent-usage--connection nil)
         (agent-usage--outbox nil)
         (agent-usage--inflight (make-hash-table :test #'equal))
         (agent-emx--connections (make-hash-table :test #'equal))
         pid report)
    (make-directory (expand-file-name "emx" dir) t)
    (with-temp-file (expand-file-name "emx/config.json" dir)
      (insert "{\"collab\":{\"handleCommand\":[],\"agentHandleCommands\":{}},"
              "\"usage\":{\"pollInterval\":0}}"))
    (unwind-protect
        (progn
          (agent-usage--start)
          (should (agent-usage-test--wait
                   (lambda () (and agent-usage--connection
                                   (agent-emx--connection-ready agent-usage--connection)))))
          (agent-emx--request agent-usage--connection "ping" nil
                              (lambda (result) (setq pid (plist-get result :daemon))))
          (should (agent-usage-test--wait (lambda () pid)))
          (setq agent-usage--retry-delay 0.05)
          (signal-process pid 'SIGKILL)
          ;; No submit, page refresh or user input drives recovery.
          (should (agent-usage-test--wait (lambda () (timerp agent-usage--retry-timer))))
          (push '(:id "crash-pending" :method "record"
                  :params (:record (:agent "codex" :input 17))) agent-usage--outbox)
          (should (agent-usage-test--wait (lambda () (null agent-usage--outbox))))
          (agent-usage--request "report" '(:range "all") (lambda (value) (setq report value)))
          (should (agent-usage-test--wait (lambda () report)))
          (should (= (plist-get (plist-get report :total) :tokens) 17))
          (should (= agent-usage--retry-delay 2))
          (should (eq (agent-emx--connection-role agent-usage--connection) 'usage))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "emx/usage.json" dir))
            (should (= (plist-get (json-parse-buffer :object-type 'plist) :pollInterval) 0))))
      (setq agent-usage--monitoring nil)
      (when (timerp agent-usage--retry-timer) (cancel-timer agent-usage--retry-timer))
      (when (and agent-usage--connection
                 (process-live-p (agent-emx--connection-process agent-usage--connection)))
        (delete-process (agent-emx--connection-process agent-usage--connection)))
      (call-process "node" nil nil nil (expand-file-name "bin/emx" agent-emx--checkout)
                    "daemon" "--var" dir "--stop")
      (delete-directory dir t))))

(ert-deftest agent-usage-test-outbox-recovery ()
  "A failed ensure preserves records and latest quotas until id acknowledgments."
  (let ((agent-usage--connection nil)
        (agent-usage--outbox nil)
        (agent-usage--monitoring nil)
        (agent-usage--retry-timer nil)
        (agent-usage--inflight (make-hash-table :test #'equal))
        (connection (agent-emx--make-connection))
        ready delivered replies)
    (cl-letf (((symbol-function 'agent-usage--capable-p) (lambda (_) t))
              ((symbol-function 'agent-usage--service) (lambda () connection))
              ((symbol-function 'agent-emx--local-connection)
               (lambda (callback error &optional role)
                 (when role (should (eq role 'usage)))
                 (if ready (funcall callback connection)
                   (funcall error '(:message "ensure failed")))
                 connection))
              ((symbol-function 'agent-emx--request)
               (lambda (_ method params callback _error)
                 (push (cons method params) delivered)
                 (push (cons callback (plist-get params :id)) replies))))
      (agent-usage--notify "record" '(:record (:input 3)))
      (agent-usage--notify "record" '(:record (:input 5)))
      (agent-usage--notify "quota" '(:agent "codex" :host :null :credits 1))
      (agent-usage--notify "quota" '(:agent "codex" :host :null :credits 2))
      (should (= (length agent-usage--outbox) 3))
      (should-not delivered)
      (setq ready t)
      (agent-usage--flush-outbox connection)
      (should (= (length delivered) 3))
      (let ((ids (mapcar (lambda (x) (plist-get (cdr x) :id)) delivered)))
        (should (= (length (delete-dups (copy-sequence ids))) 3))
        ;; An uncertain delivery keeps every item, with the same ids on retry.
        (clrhash agent-usage--inflight)
        (setq delivered nil replies nil)
        (agent-usage--flush-outbox connection)
        (should (equal ids (mapcar (lambda (x) (plist-get (cdr x) :id)) delivered))))
      (should (= (length agent-usage--outbox) 3))
      (dolist (reply replies) (funcall (car reply) (list :id (cdr reply))))
      (should-not agent-usage--outbox))))

(ert-deftest agent-usage-test-restart-daemon-guard ()
  "The explicit stale-code restart hibernates idle sessions and rejects work."
  (dolist (status '("running" "idle"))
    (let (stopped restarted)
      (cl-letf (((symbol-function 'agent-emx--local-connection)
                 (lambda (callback _error &optional _) (funcall callback 'test)))
                ((symbol-function 'agent-emx--restart-after-stop)
                 (lambda (_ _attempts) (setq restarted t)))
                ((symbol-function 'agent-emx--request)
                 (lambda (_ method params callback &optional _error)
                   (if (equal method "sessions/list")
                       (funcall callback (list :sessions (vector (list :status status))))
                     (should (equal method "daemon/stop"))
                     (should (plist-get params :idleOnly))
                     (setq stopped t)
                     (funcall callback nil)))))
        (agent-emx-restart-daemon)
        (should (eq stopped (equal status "idle")))
        (should (eq restarted stopped))))))

(ert-deftest agent-usage-test-capability-gate ()
  "An old hello cannot consume the usage outbox."
  (let ((agent-usage--outbox nil)
        (agent-usage--inflight (make-hash-table :test #'equal))
        (agent-usage--monitoring nil)
        (connection (agent-emx--make-connection)))
    (cl-letf (((symbol-function 'agent-usage--with-connection) #'ignore)
              ((symbol-function 'agent-emx--request)
               (lambda (&rest _) (ert-fail "Sent usage to an old daemon"))))
      (agent-usage--notify "record" '(:record (:input 3)))
      (agent-usage--connected connection)
      (agent-usage--flush-outbox connection)
      (should (= (length agent-usage--outbox) 1)))))

(ert-deftest agent-usage-test-daemon-transport ()
  "Usage uses its own asynchronous connection and decodes report vectors."
  (let* ((connection (agent-emx--make-connection :capabilities '(:usage 1)))
         (agent-usage--connection connection)
         (agent-usage--outbox nil)
         (agent-usage--inflight (make-hash-table :test #'equal))
         sent result)
    (cl-letf (((symbol-function 'agent-usage--service) (lambda () connection))
              ((symbol-function 'agent-emx--local-connection)
               (lambda (callback _error &optional role)
                 (should (eq role 'usage)) (funcall callback connection)))
              ((symbol-function 'agent-emx--request)
               (lambda (peer method params callback _error)
                 (should (eq peer connection))
                 (if (equal method "usage/record")
                     (progn (setq sent params) (funcall callback (list :id (plist-get params :id))))
                   (should (equal method "usage/report"))
                   (should-not (plist-get (plist-get params :filter) :model))
                   (funcall callback '(:quotas [(:windows [] :duplicate :false)]))))))
      (agent-usage--notify "record" '(:record (:input 1)))
      (should (stringp (plist-get sent :id)))
      (should-not agent-usage--outbox)
      (agent-usage--request "report" '(:filter (:model :null))
                            (lambda (value) (setq result value)))
      (should (equal result '(:quotas ((:windows nil :duplicate nil))))))))

(ert-deftest agent-usage-test-shared-quota-push ()
  "Global pushes update the existing echo/page data without a session."
  (let ((connection (agent-emx--make-connection))
        (agent-usage--snapshot nil)
        (changes 0)
        (agent-usage-change-functions nil))
    (add-hook 'agent-usage-change-functions (lambda () (cl-incf changes)))
    (agent-emx--dispatch connection
                         '(:method "usage/quotas"
                           :params (:quotas [(:agent "codex" :host nil :windows []
                                                     :credits "unlimited" :duplicate :false)])))
    (should (= changes 1))
    (should (equal agent-usage--snapshot
                   '((:agent "codex" :host nil :windows nil :credits "unlimited" :duplicate nil))))
    (agent-emx--dispatch connection '(:method "usage/changed" :params nil))
    (should (= changes 2))))

(ert-deftest agent-usage-test-no-implicit-batch-daemon ()
  "A stale batch connection cannot discover a default daemon."
  (let ((noninteractive t)
        (agent-usage--outbox nil)
        (agent-usage--connection (agent-emx--make-connection)))
    (cl-letf (((symbol-function 'agent-emx--local-connection)
               (lambda (&rest _) (ert-fail "Started an implicit batch daemon"))))
      (should-not (agent-usage--service))
      (agent-usage--notify "record" '(:record (:input 1))))))

(ert-deftest agent-usage-test-fetch-order ()
  "A report arriving after a newer one was asked for is dropped; a group
of no model filters with null."
  (let (asked)
    (cl-letf (((symbol-function 'agent-usage--request)
               (lambda (method params callback) (push (list method params callback) asked)))
              ((symbol-function 'agent-usage--redraw) #'ignore))
      (with-temp-buffer
        (agent-usage-mode)
        (agent-usage--fetch)
        (setq agent-usage--filter (list :model nil))
        (agent-usage--fetch)
        (should (equal (plist-get (nth 1 (car asked)) :filter) '(:model :null)))
        (should (json-serialize (nth 1 (car asked))))
        ;; The newer answer first, then the older one: the newer stays.
        (funcall (nth 2 (car asked)) '(:range "week" :total (:tokens 2)))
        (funcall (nth 2 (cadr asked)) '(:range "week" :total (:tokens 1)))
        (should (equal (plist-get (plist-get agent-usage--report :total) :tokens) 2))))))

(ert-deftest agent-usage-test-codex-window-ids ()
  "A Codex window without a duration is named like emx names it."
  (agent-usage-test--with-files
    (agent-codex--rate-limits (agent-usage-test--session 'codex)
                              '(:primary (:usedPercent 20 :resetsAt 100)))
    (should (equal (plist-get (car (plist-get (agent-usage-test--quota 'codex) :windows)) :id)
                   "primary"))))

(ert-deftest agent-usage-test-echo-refresh ()
  "The quota line is drawn into the idle echo-area buffer, and cleared."
  (agent-usage-test--with-files
    (let* ((agent-usage--echo-buffer " *agent-usage-test-echo*")
           (buffer (get-buffer-create agent-usage--echo-buffer))
           (agent-usage--echo-timer nil)
           (agent-session-agents '((dsh :title "DeepSeek"))))
      (unwind-protect
          (progn
            (setq agent-usage--snapshot
                  (list (list :agent "dsh" :time (float-time)
                              :balance '((:amount 9.18 :currency "CNY")))))
            (let ((agent-usage-echo-mode t)) (agent-usage-echo-refresh))
            (should (string-match-p "DeepSeek 余额 ¥9\\.18"
                                    (with-current-buffer buffer (buffer-string))))
            (let ((agent-usage-echo-mode nil)) (agent-usage-echo-refresh))
            (should (equal (with-current-buffer buffer (buffer-string)) "")))
        (kill-buffer buffer)))))

(ert-deftest agent-usage-test-persistent-producer-sequences ()
  (let* ((agent-emx-var-directory (make-temp-file "emx-editor-outbox-" t))
         (agent-usage--outbox-loaded nil)
         (agent-usage--outbox nil)
         (agent-usage--serial 0)
         (agent-usage--id-prefix "test-producer")
         (agent-usage--inflight (make-hash-table :test #'equal))
         (connection (agent-emx--make-connection))
         sent callbacks)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-usage--with-connection) #'ignore)
                  ((symbol-function 'agent-usage--capable-p) (lambda (_) t))
                  ((symbol-function 'agent-emx--request)
                   (lambda (_ _method params callback _error)
                     (push params sent) (push callback callbacks))))
          (agent-usage--notify "record" '(:record (:input 1)))
          (agent-usage--notify "record" '(:record (:input 2)))
          (agent-usage--flush-outbox connection)
          (let ((first (copy-tree sent)))
            ;; Apply succeeded, but editor and daemon restart before any ack.
            (setq agent-usage--outbox nil agent-usage--outbox-loaded nil
                  agent-usage--id-prefix "new-process" agent-usage--serial 0 sent nil)
            (clrhash agent-usage--inflight)
            (agent-usage--flush-outbox connection)
            (should (equal sent first))
            (funcall (car callbacks) '(:source "test-producer" :sequence 2))
            (should-not agent-usage--outbox)
            (setq agent-usage--outbox-loaded nil)
            (agent-usage--notify "record" '(:record (:input 3)))
            (should (= (plist-get (car agent-usage--outbox) :sequence) 3))
            (should (equal (plist-get (car agent-usage--outbox) :source) "test-producer"))))
      (delete-directory agent-emx-var-directory t))))

(ert-deftest agent-usage-test-sequences-live-legacy-entries ()
  (let* ((agent-emx-var-directory (make-temp-file "emx-live-outbox-" t))
         (agent-usage--outbox-loaded nil)
         (agent-usage--outbox nil)
         (agent-usage--id-prefix "live-producer")
         (agent-usage--serial 0))
    (unwind-protect
        (progn
          (agent-usage--restore-outbox)
          (push '(:id "legacy-live" :method "record" :params (:record (:input 1)))
                agent-usage--outbox)
          (agent-usage--restore-outbox)
          (should (equal (plist-get (car agent-usage--outbox) :source) "live-producer"))
          (should (= (plist-get (car agent-usage--outbox) :sequence) 1)))
      (delete-directory agent-emx-var-directory t))))

(provide 'agent-usage-test)
;;; agent-usage-test.el ends here
