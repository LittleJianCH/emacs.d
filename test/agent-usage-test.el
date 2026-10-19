;;; agent-usage-test.el --- Tests for agent-usage -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests usage records, quota merging and the echo-area line.  Every test
;; uses fresh temporary files, so the real var/ files are never touched.
;; Run:
;;   emacs --batch --init-directory=. --eval '(setq my/use-evil nil)'
;;     -l init.el -l test/agent-usage-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-session)
(require 'agent-usage)
(require 'agent-claude)
(require 'agent-codex)

;; Load tramp-rpc before ERT redirects the native-compilation cache for
;; `ert-run-tests-batch-and-exit': otherwise the first /rpc: name in the
;; quota test compiles the package into the throwaway cache, which is slow.
(require 'tramp-rpc nil t)

(defmacro agent-usage-test--with-files (&rest body)
  "Run BODY with fresh usage files and clean module state."
  (declare (indent 0) (debug t))
  `(let* ((agent-usage-file (make-temp-file "agent-usage-test-" nil ".eld"))
          (agent-usage-quota-file
           (make-temp-file "agent-quota-test-" nil ".eld"))
          (agent-usage--records nil)
          (agent-usage--loaded nil)
          (agent-usage--quotas 'unloaded)
          (agent-usage-change-functions nil))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-file agent-usage-file))
       (ignore-errors (delete-file agent-usage-quota-file)))))

(defun agent-usage-test--session (&optional agent)
  "Make a local test session for AGENT, claude by default."
  (agent-session--make
   :agent (or agent 'claude)
   :backend (or agent 'claude)
   :root "/tmp/proj/"
   :info (list :handle "h1" :model "claude-opus-5-5")))

(defun agent-usage-test--records ()
  "Read the test usage records back from the file, newest first."
  (setq agent-usage--loaded nil)
  (agent-usage-records))

(defun agent-usage-test--records-of (model)
  "Records of MODEL in the test file, newest first."
  (seq-filter (lambda (record) (equal (plist-get record :model) model))
              (agent-usage-test--records)))

(defun agent-usage-test--approx (a b)
  "Non-nil if A and B are the same number up to rounding."
  (and (numberp a) (numberp b) (< (abs (- a b)) 1e-9)))

(defun agent-usage-test--quota (agent &optional host)
  "The quota of AGENT on HOST, as stored by `agent-usage-set-quota'."
  (cdr (assoc (cons agent host) (agent-usage-quotas))))

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

(ert-deftest agent-usage-test-quota-merge ()
  "Quotas merge windows by id, keep balances and persist per host."
  ;; Window ids are strings made afresh by each report: they must be
  ;; compared with `equal', or every sparse update adds a duplicate.
  (agent-usage-test--with-files
    (let* ((session (agent-usage-test--session 'claude))
           (later (+ (float-time) 3600))
           (later-2 (+ (float-time) 86400))
           (balance '((:amount 12.3 :currency "CNY"))))
      (agent-usage-set-quota
       session
       :windows (list (list :id "five_hour" :label "5h"
                            :used 0.6 :resets later)
                      (list :id "seven_day" :label "周"
                            :used 0.13 :resets later-2))
       :balance balance)
      ;; A sparse update changes one window and keeps the other.
      (agent-usage-set-quota
       session
       :windows (list (list :id "seven_day" :label "周"
                            :used 0.4 :resets later-2)))
      (let* ((quota (agent-usage-test--quota 'claude))
             (windows (plist-get quota :windows)))
        (should (agent-usage-test--approx
                 (plist-get (seq-find (lambda (window)
                                        (equal (plist-get window :id)
                                               "five_hour"))
                                      windows)
                            :used)
                 0.6))
        (should (agent-usage-test--approx
                 (plist-get (seq-find (lambda (window)
                                        (equal (plist-get window :id)
                                               "seven_day"))
                                      windows)
                            :used)
                 0.4)))
      ;; Omitting the balance or passing nil keeps the known one.
      (agent-usage-set-quota session :plan "max")
      (should (equal (plist-get (agent-usage-test--quota 'claude) :balance)
                     balance))
      (agent-usage-set-quota session :plan "pro" :balance nil)
      (should (equal (plist-get (agent-usage-test--quota 'claude) :balance)
                     balance))
      (should (equal (plist-get (agent-usage-test--quota 'claude) :plan)
                     "pro"))
      ;; The quota file is written and read back.
      (let ((saved (copy-sequence (agent-usage-quotas))))
        (setq agent-usage--quotas 'unloaded)
        (should (equal (agent-usage-quotas) saved)))
      ;; A remote project's quota is filed under its host.
      (let ((remote (agent-session--make
                     :agent 'claude :backend 'claude
                     :root "/rpc:host1:/x/"
                     :info (list :handle "h2" :model "claude-opus-5-5"))))
        (agent-usage-set-quota
         remote
         :windows (list (list :id "five_hour" :label "5h"
                              :used 0.2 :resets later)))
        (should (agent-usage-test--quota 'claude "host1"))
        (let ((window (car (plist-get (agent-usage-test--quota 'claude "host1")
                                      :windows))))
          (should (equal (list (plist-get window :id) (plist-get window :used)
                               (plist-get window :resets))
                         (list "five_hour" 0.2 later))))
        ;; The local quota is still there under its own key.
        (should (agent-usage-test--quota 'claude)))
      ;; A sparse update must leave exactly the two windows, not a stale
      ;; copy of the one it updated.  This fails while the bug above is there.
      (should (= (length (plist-get (agent-usage-test--quota 'claude)
                                    :windows))
                 2)))))

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
    ;; Newest registration first, as `agent-session-define-agent' pushes.
    (let ((agent-session-agents '((dsh :title "DeepSeek")
                                  (codex :title "Codex")
                                  (claude :title "Claude")))
          (future (+ (float-time) 3600))
          (later (+ (float-time) 86400))
          (past (- (float-time) 60)))
      (let ((claude (agent-usage-test--session 'claude))
            (codex (agent-usage-test--session 'codex))
            (dsh (agent-usage-test--session 'dsh)))
        (agent-usage-set-quota
         claude
         :windows (list (list :id "five_hour" :label "5h"
                              :used 0.6 :resets future)
                        (list :id "seven_day" :label "周"
                              :used 0.85 :resets later)))
        (agent-usage-set-quota
         codex
         :windows (list (list :id "five_hour" :label "5h"
                              :used 0.3 :resets past)))
        (agent-usage-set-quota
         dsh :balance '((:amount 12.3 :currency "CNY")))
        ;; A remote host on the same account reports the same windows: it is
        ;; left out; one on another account is shown after this machine's.
        (let ((same (agent-usage-test--session 'claude))
              (other (agent-usage-test--session 'claude)))
          (setf (agent-session-root same) "/rpc:dev:/x/"
                (agent-session-root other) "/rpc:box:/x/")
          (agent-usage-set-quota
           same :windows (list (list :id "five_hour" :label "5h" :used 0.6 :resets future)
                               (list :id "seven_day" :label "周" :used 0.85 :resets later)))
          (agent-usage-set-quota
           other :windows (list (list :id "five_hour" :label "5h" :used 0.1
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

(ert-deftest agent-usage-test-record-drops-empty ()
  "A record with no tokens writes nothing and returns nil."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session)))
      (should-not (agent-usage-record session))
      (should-not (agent-usage-record
                   session :model "m" :input 0 :cache-read nil
                   :cache-write 0 :output nil))
      (should (equal (with-temp-buffer
                       (insert-file-contents agent-usage-file)
                       (buffer-string))
                     "")))))

;;; Forecast

(ert-deftest agent-usage-test-forecast ()
  "The pace follows the recent trend, not the average since the window began."
  (let* ((now 1800000000.0)
         (day 86400)
         (weekly (lambda (used resets history)
                   (list :id "seven_day" :minutes 10080 :used used :resets resets
                         :history history))))
    ;; Idle over the weekend, 20% today, four days left: right on pace,
    ;; though by the average since the window began it looked plentiful.
    (let ((forecast (agent-usage-forecast
                     (funcall weekly 0.2 (+ now (* 4 day))
                              `((,(- now (* 3 day)) . 0.0) (,(- now day) . 0.0) (,now . 0.2)))
                     now)))
      (should (< (abs (- (plist-get forecast :rate) 0.2)) 1e-9))
      (should (< (abs (- (plist-get forecast :projected) 1.0)) 1e-9))
      (should-not (plist-get forecast :exhausts)))
    ;; 30% in the last day with 60% left: out in two days, before the reset.
    (let ((forecast (agent-usage-forecast
                     (funcall weekly 0.4 (+ now (* 4 day))
                              `((,(- now (* 2 day)) . 0.05) (,(- now day) . 0.1) (,now . 0.4)))
                     now)))
      (should (< (abs (- (plist-get forecast :projected) 1.6)) 1e-9))
      (should (< (abs (- (plist-get forecast :exhausts) (+ now (* 2 day)))) 1e-3)))
    ;; Readings of a few minutes only: the average since the window began.
    (let ((forecast (agent-usage-forecast
                     (funcall weekly 0.12 (+ now (* 4 day))
                              `((,(- now 600) . 0.1) (,now . 0.12)))
                     now)))
      (should (< (abs (- (plist-get forecast :rate) 0.04)) 1e-9))
      (should (= (plist-get forecast :since) (- now (* 3 day)))))
    ;; A window past its reset has no forecast.
    (should-not (agent-usage-forecast (funcall weekly 0.5 (- now 1) nil) now))))

(ert-deftest agent-usage-test-window-history ()
  "Readings accumulate over a period and start again when it resets."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session 'claude))
          (resets (+ (float-time) 86400)))
      (agent-usage-set-quota session :windows (list (list :id "seven_day" :used 0.1
                                                          :resets resets)))
      (agent-usage-set-quota session :windows (list (list :id "seven_day" :used 0.2
                                                          :resets (+ resets 30))))
      (let ((window (car (plist-get (agent-usage-test--quota 'claude) :windows))))
        (should (equal (mapcar #'cdr (plist-get window :history)) '(0.1 0.2))))
      ;; Another window's update keeps this one's readings.
      (agent-usage-set-quota session :windows (list (list :id "five_hour" :used 0.3
                                                          :resets resets)))
      (let ((window (cl-find "seven_day" (plist-get (agent-usage-test--quota 'claude) :windows)
                             :key (lambda (w) (plist-get w :id)) :test #'equal)))
        (should (= (length (plist-get window :history)) 2)))
      ;; A new period.
      (agent-usage-set-quota session :windows (list (list :id "seven_day" :used 0.01
                                                          :resets (+ resets (* 7 86400)))))
      (let ((window (cl-find "seven_day" (plist-get (agent-usage-test--quota 'claude) :windows)
                             :key (lambda (w) (plist-get w :id)) :test #'equal)))
        (should (equal (mapcar #'cdr (plist-get window :history)) '(0.01)))))))

;;; Robustness

(ert-deftest agent-usage-test-truncated-line ()
  "A line cut short doesn't hide the records after it; appends after it
start a line of their own."
  (agent-usage-test--with-files
    (with-temp-file agent-usage-file
      (insert "(:time 1 :turns 1 :input 2\n(:time 2 :turns 1 :input 3)\n(:time 3 :input 4"))
    (agent-usage-record (agent-usage-test--session) :model "m" :input 5)
    (should (equal (mapcar (lambda (record) (plist-get record :input))
                           (agent-usage-test--records))
                   '(5 3)))))

(ert-deftest agent-usage-test-write-failure ()
  "A ledger that can't be written doesn't stop the turn from ending."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session 'codex)))
      (setq agent-usage--loaded t)
      (agent-usage-add-call session "gpt" '(:input 10 :output 5))
      (cl-letf (((symbol-function 'write-region)
                 (lambda (&rest _) (signal 'file-error '("No space left")))))
        (agent-usage-end-turn session))
      (should-not (plist-get (agent-session-state session) :usage-pending))
      ;; Still counted in this Emacs.
      (should (= (plist-get (car agent-usage--records) :input) 10)))))

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
  "Unlimited credits replace a known balance; a snapshot without any keeps it."
  (agent-usage-test--with-files
    (let ((session (agent-usage-test--session 'codex)))
      (agent-codex--rate-limits session '(:credits (:unlimited nil :balance "42")))
      (should (= (plist-get (agent-usage-test--quota 'codex) :credits) 42))
      (agent-codex--rate-limits session '(:planType "pro"))
      (should (= (plist-get (agent-usage-test--quota 'codex) :credits) 42))
      (agent-codex--rate-limits session '(:credits (:unlimited t :balance nil)))
      (should (eq (plist-get (agent-usage-test--quota 'codex) :credits) 'unlimited)))))

;;; Clearing

(ert-deftest agent-usage-test-clear ()
  "Clearing asks first; declined, nothing goes."
  (agent-usage-test--with-files
    (agent-usage-record (agent-usage-test--session) :model "m" :input 5)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
      (should-error (agent-usage-clear) :type 'user-error))
    (should (= (length (agent-usage-test--records)) 1))
    (let ((delete-by-moving-to-trash nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (agent-usage-clear)))
    (should-not (file-exists-p agent-usage-file))
    (should-not (agent-usage-records))
    ;; Recording starts a new ledger.
    (agent-usage-record (agent-usage-test--session) :model "m" :input 1)
    (should (= (length (agent-usage-test--records)) 1))))

;;; Summaries and the usage page

(defun agent-usage-test--sample-records ()
  "Records of two agents in two projects, this hour."
  (let ((now (float-time)))
    (list (list :time now :agent 'claude :root "~/a/" :model "claude-opus-5-5"
                :turns 1 :input 10 :cache-read 1000 :cache-write 0 :output 90)
          (list :time now :agent 'codex :root "~/b/" :model "gpt-6.1-sol"
                :turns 1 :child t :input 100 :cache-read 0 :cache-write 0 :output 1900)
          (list :time (- now (* 40 86400)) :agent 'codex :root "~/b/" :model "gpt-6.1-sol"
                :turns 1 :input 5 :output 5))))

(ert-deftest agent-usage-test-summarize ()
  "Groups sum their records, the most tokens first and the total last."
  (let* ((records (butlast (agent-usage-test--sample-records)))
         (groups (agent-usage-summarize records :agent))
         (total (cdr (assq t groups))))
    (should (equal (mapcar #'car groups) '(codex claude t)))
    (should (= (plist-get total :turns) 2))
    (should (= (plist-get total :child-turns) 1))
    (should (= (agent-usage-tokens total) 3100))
    ;; Without the cache, Claude's cache reads don't count.
    (should (= (agent-usage-tokens total t) 2100))))

(ert-deftest agent-usage-test-page ()
  "The page shows the period's groups, and RET on a row filters to it."
  (agent-usage-test--with-files
    (setq agent-usage--records (agent-usage-test--sample-records)
          agent-usage--loaded t
          agent-usage--quotas nil)
    (let ((agent-session-agents '((claude :title "Claude") (codex :title "Codex"))))
      (with-temp-buffer
        (agent-usage-mode)
        (cl-letf (((symbol-function 'agent-usage--width) (lambda () 100)))
          (agent-usage--render)
          (should (string-match-p "Harness" (buffer-string)))
          ;; The rows of the timeline, the peak's label included, line up
          ;; their columns: they are all as wide.
          (save-excursion
            (goto-char (point-min))
            (search-forward "每日趋势")
            (forward-line 1)
            (let (widths)
              (dotimes (_ 5)
                (push (string-width (buffer-substring (point) (line-end-position))) widths)
                (forward-line 1))
              (should (= (length (delete-dups widths)) 1))))
          (should-not (string-match-p "[$¥]" (buffer-string)))
          ;; The 40-day-old record is outside the week, inside "all".
          (should-not (string-match-p "2 轮" (buffer-string)))
          (goto-char (point-min))
          (search-forward "  Claude")
          (agent-usage-select)
          (should (equal agent-usage--filter '(:agent claude)))
          (should-not (string-match-p "gpt-6.1-sol" (buffer-string)))
          (agent-usage-unfilter)
          (should (string-match-p "gpt-6.1-sol" (buffer-string)))
          (agent-usage-set-range 'all)
          (should (string-match-p "2 轮 · 子 agent 1 轮" (buffer-string))))))))

(ert-deftest agent-usage-test-echo-refresh ()
  "The quota line is drawn into the idle echo-area buffer, and cleared."
  (agent-usage-test--with-files
    (let* ((agent-usage--echo-buffer " *agent-usage-test-echo*")
           (buffer (get-buffer-create agent-usage--echo-buffer))
           (agent-usage--echo-timer nil)
           (agent-session-agents '((dsh :title "DeepSeek"))))
      (unwind-protect
          (progn
            (setq agent-usage--quotas
                  (list (cons '(dsh) (list :time (float-time)
                                           :balance '((:amount 9.18 :currency "CNY"))))))
            (let ((agent-usage-echo-mode t)) (agent-usage-echo-refresh))
            (should (string-match-p "DeepSeek 余额 ¥9\\.18"
                                    (with-current-buffer buffer (buffer-string))))
            (let ((agent-usage-echo-mode nil)) (agent-usage-echo-refresh))
            (should (equal (with-current-buffer buffer (buffer-string)) "")))
        (kill-buffer buffer)))))

(provide 'agent-usage-test)
;;; agent-usage-test.el ends here
