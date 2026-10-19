;;; agent-usage.el --- Usage and quota of the agents Emacs runs -*- lexical-binding: t; -*-

;;; Commentary:

;; What the agents started from this Emacs consume, and what their accounts
;; have left.
;;
;; Usage: backends report each turn's tokens with
;; `agent-usage-record', one record per turn and model.  Records are
;; appended to `agent-usage-file', one plist per line, so only work done
;; from Emacs is counted: other clients of the same accounts (Claude
;; Desktop, a terminal) are not.  Subagents are sessions of their own and
;; are counted like any other.
;;
;; Quota: backends pass what an agent reports about its account to
;; `agent-usage-set-quota': rate-limit windows (Claude, Codex) or a balance
;; (DeepSeek).  It comes with the agents' own traffic; nothing is polled.
;; The latest of each is kept in `agent-usage-quota-file' and shown in the
;; echo area while it is idle (`agent-usage-echo-mode').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-session)

(declare-function my/var "init-base")

(defgroup agent-usage nil
  "Usage and quota of the agents Emacs runs."
  :group 'agent-session)

(defun agent-usage--var (name)
  "Path of NAME under the runtime directory var/."
  (if (fboundp 'my/var) (my/var name) (locate-user-emacs-file (concat "var/" name))))

(defcustom agent-usage-file (agent-usage--var "agent-usage.eld")
  "File the usage records are appended to, one plist per line."
  :type 'file)

(defcustom agent-usage-quota-file (agent-usage--var "agent-quota.eld")
  "File keeping the latest quota reported by each agent."
  :type 'file)

(defface agent-usage-low '((t :inherit warning))
  "Quota running low.")
(defface agent-usage-out '((t :inherit error))
  "Quota (nearly) used up.")

;;; Records

(defvar agent-usage--records nil
  "Usage records read from `agent-usage-file', newest first.
`agent-usage--loaded' is nil until the file has been read.")
(defvar agent-usage--loaded nil
  "Non-nil once `agent-usage-file' has been read into `agent-usage--records'.")

(defconst agent-usage--counters '(:input :cache-read :cache-write :output)
  "Token counters of a record.
:input counts input tokens that were neither read from nor written to the
prompt cache, so the four add up to the tokens of the requests.")

(defun agent-usage-records ()
  "All usage records, newest first, read from `agent-usage-file' once."
  (unless agent-usage--loaded
    (setq agent-usage--records nil
          agent-usage--loaded t)
    (when (file-readable-p agent-usage-file)
      (with-temp-buffer
        (insert-file-contents agent-usage-file)
        (goto-char (point-min))
        (while (not (eobp))
          ;; Each line on its own: one cut short by a crash is skipped
          ;; without taking the next ones with it.
          (when-let* ((record (ignore-errors
                                (car (read-from-string
                                      (buffer-substring-no-properties
                                       (point) (line-end-position))))))
                      ((plistp record)))
            (push record agent-usage--records))
          (forward-line 1)))))
  agent-usage--records)

(defun agent-usage--write-record (record)
  "Append RECORD to `agent-usage-file'; return nil if that failed.
A failure is reported once in a while, never signaled: it must not stop
the turn that is ending."
  (condition-case err
      (let ((coding-system-for-write 'utf-8-unix)
            (print-length nil)
            (print-level nil)
            (file agent-usage-file))
        (make-directory (file-name-directory file) t)
        (write-region (concat
                       ;; After a line cut short, start a line of our own.
                       (when-let* ((size (file-attribute-size (file-attributes file)))
                                   ((> size 0))
                                   ((not (equal (with-temp-buffer
                                                  (set-buffer-multibyte nil)
                                                  (insert-file-contents-literally
                                                   file nil (1- size) size)
                                                  (buffer-string))
                                                "\n"))))
                         "\n")
                       (prin1-to-string record) "\n")
                      nil file t 'silent)
        t)
    (error
     (message "用量记录写入失败：%s" (error-message-string err))
     nil)))

(defun agent-usage-clear ()
  "Delete every usage record, after confirming in the minibuffer.
Quotas are kept.  The file goes to the trash when
`delete-by-moving-to-trash' is set.  Deliberately bound to no key."
  (interactive)
  (let ((count (length (agent-usage-records))))
    (unless (yes-or-no-p (format "清空全部 %d 条用量记录（%s）？此操作不能撤销 "
                                 count (abbreviate-file-name agent-usage-file)))
      (user-error "已取消"))
    (when (file-exists-p agent-usage-file)
      (delete-file agent-usage-file t))
    (setq agent-usage--records nil
          agent-usage--loaded t)
    (run-hooks 'agent-usage-change-functions)
    (message "已清空 %d 条用量记录" count)))

(defvar agent-usage-change-functions nil
  "Functions called with no arguments after a record or quota is added.")

(defun agent-usage-record (session &rest props)
  "Record the usage PROPS of one turn of SESSION.
PROPS: :model, the token counters :input :cache-read :cache-write
:output, and :turns, the number of turns counted (default 1; 0 for
another model the same turn used).  A record without tokens is dropped."
  (when (cl-some (lambda (key) (> (or (plist-get props key) 0) 0)) agent-usage--counters)
    (let ((record (append (list :time (float-time)
                                :agent (agent-session-agent session)
                                :root (abbreviate-file-name (agent-session-root session))
                                :session (agent-session-handle session))
                          (when (agent-session-child-p session) (list :child t))
                          (list :turns (or (plist-get props :turns) 1))
                          (cl-loop for (key value) on props by #'cddr
                                   unless (or (eq key :turns) (null value))
                                   append (list key value)))))
      (agent-usage--write-record record)
      (when agent-usage--loaded (push record agent-usage--records))
      (run-hooks 'agent-usage-change-functions)
      record)))

;; Agents report usage in two ways: Claude's totals grow over the life of a
;; process, Codex and DeepSeek report each model call.  Both are turned
;; into one record per turn and model.  The state lives in the session's
;; state plist, under keys of this module.

(defun agent-usage--state (session key)
  "Value of KEY in SESSION's state plist."
  (plist-get (agent-session-state session) key))

(defun agent-usage--set-state (session key value)
  "Set KEY in SESSION's state plist to VALUE."
  (setf (agent-session-state session) (plist-put (agent-session-state session) key value)))

(defun agent-usage--add (a b)
  "Sum of the counters of the plists A and B."
  (cl-loop for key in agent-usage--counters
           append (list key (+ (or (plist-get a key) 0) (or (plist-get b key) 0)))))

(defun agent-usage--subtract (a b)
  "Counters of plist A minus those of B."
  (cl-loop for key in agent-usage--counters
           for value = (plist-get a key)
           when value append (list key (- value (or (plist-get b key) 0)))))

(defun agent-usage-forget-totals (session)
  "Forget the running totals last reported by SESSION's agent.
For a conversation others added to: a process resuming it may carry on
with totals that count their usage too."
  (agent-usage--set-state session :usage-base nil))

(defun agent-usage-totals-known-p (session)
  "Non-nil if SESSION's process has reported its running totals before."
  (eq (agent-usage--state session :usage-process) (agent-session-process session)))

(defun agent-usage--deltas (totals base)
  "What TOTALS add to BASE, per model: ((MODEL . PLIST) ...)."
  (cl-loop for (model . total) in totals
           collect (cons model (agent-usage--subtract
                                total (alist-get model base nil nil #'equal)))))

(defun agent-usage--sum (alist)
  "Tokens of all the plists in ALIST ((KEY . PLIST) ...)."
  (cl-loop for (_ . plist) in alist sum (agent-usage-tokens plist)))

(defun agent-usage-totals (session totals turn)
  "Turn the running TOTALS of SESSION's process into what is new.
TOTALS is an alist (MODEL . PLIST) of counters.  Return the
alist of what each model added since the totals last reported, or
`unknown'.

Within one process that is the difference.  A new process may start
from zero or carry on with totals it restored, which can be older than
the last ones reported, so its first report must prove which: TURN, a
plist of what the turn just ended used of all models, as reported apart
from the totals, settles it.  Totals equal to TURN started from zero;
totals exceeding the last known ones by at least TURN carried on from
them; anything else is `unknown'."
  (let* ((known (agent-usage-totals-known-p session))
         (base (agent-usage--state session :usage-base))
         (deltas (agent-usage--deltas totals base))
         (turn-tokens (agent-usage-tokens turn)))
    (agent-usage--set-state session :usage-process (agent-session-process session))
    (agent-usage--set-state session :usage-base totals)
    (cond ((or known
               (and base
                    (cl-every (lambda (delta)
                                (cl-every (lambda (key) (>= (or (plist-get (cdr delta) key) 0) 0))
                                          agent-usage--counters))
                              deltas)
                    (>= (agent-usage--sum deltas) turn-tokens)))
           (cl-remove-if-not (lambda (delta)
                               (cl-some (lambda (key) (> (or (plist-get (cdr delta) key) 0) 0))
                                        agent-usage--counters))
                             deltas))
          ((= (agent-usage--sum totals) turn-tokens) totals)
          (t 'unknown))))

(defun agent-usage-add-call (session model usage)
  "Add the USAGE of one model call by MODEL to SESSION's current turn.
USAGE is a plist of counters; `agent-usage-end-turn' records the
sum.  Calls reported outside a turn, such as usage replayed when a thread
is resumed, should not be passed here."
  (let* ((pending (agent-usage--state session :usage-pending))
         (cell (assoc model pending)))
    (if cell
        (setcdr cell (agent-usage--add (cdr cell) usage))
      (agent-usage--set-state session :usage-pending
                              (append pending (list (cons model usage)))))))

(defun agent-usage--flush (session)
  "Record what SESSION's turn used so far, if its process is gone."
  (when (agent-usage--state session :usage-pending)
    (agent-usage-end-turn session)))

(defun agent-usage--on-status (session _previous)
  "Keep the usage of a turn SESSION's process didn't live to end."
  (when (eq (agent-session-status session) 'exited)
    (agent-usage--flush session)))

(defun agent-usage--on-kill ()
  "Keep the usage of the running turn of a session buffer being killed."
  (when-let* ((session (bound-and-true-p agent-session--current)))
    (agent-usage--flush session)))

(add-hook 'agent-session-status-functions #'agent-usage--on-status)
(add-hook 'kill-buffer-hook #'agent-usage--on-kill)

(defun agent-usage-end-turn (session)
  "Record what SESSION's turn used, as added by `agent-usage-add-call'.
The first model counts the turn."
  (let ((pending (agent-usage--state session :usage-pending))
        (turns 1))
    (agent-usage--set-state session :usage-pending nil)
    (pcase-dolist (`(,model . ,usage) pending)
      (when (apply #'agent-usage-record session :model model :turns turns usage)
        (setq turns 0)))))

;;; Summaries

(defun agent-usage-since (range)
  "Start time of RANGE: `today', `week' (7 days), `month' (30 days) or `all'."
  (let ((midnight (let ((now (decode-time)))
                    (float-time (encode-time (list 0 0 0 (decoded-time-day now)
                                                   (decoded-time-month now)
                                                   (decoded-time-year now)
                                                   nil -1 (decoded-time-zone now)))))))
    (pcase range
      ('today midnight)
      ('week (- midnight (* 6 86400)))
      ('month (- midnight (* 29 86400)))
      (_ 0))))

(defun agent-usage-tokens (sum &optional without-cache)
  "Tokens counted in SUM, a record or summary.
WITHOUT-CACHE leaves out those read from or written to the prompt cache."
  (cl-loop for key in (if without-cache '(:input :output) agent-usage--counters)
           sum (or (plist-get sum key) 0)))

(defun agent-usage--accumulate (sum record)
  "Add RECORD to SUM: the counters, :turns and :child-turns (of subagents)."
  (let ((turns (or (plist-get record :turns) 0)))
    (append (cl-loop for key in agent-usage--counters
                     append (list key (+ (or (plist-get sum key) 0)
                                         (or (plist-get record key) 0))))
            (list :turns (+ turns (or (plist-get sum :turns) 0))
                  :child-turns (+ (if (plist-get record :child) turns 0)
                                  (or (plist-get sum :child-turns) 0))))))

(defun agent-usage-summarize (records key &optional without-cache)
  "Sum RECORDS grouped by the value of KEY (:model, :agent, :root...).
Return ((VALUE . SUM) ...), the most tokens first (WITHOUT-CACHE: not
counting the prompt cache), and the total of all as a last element
\(t . SUM).  See `agent-usage--accumulate' for SUM."
  (let (groups total)
    (dolist (record records)
      (let* ((value (plist-get record key))
             (cell (assoc value groups)))
        (unless cell
          (setq cell (list value))
          (push cell groups))
        (setcdr cell (agent-usage--accumulate (cdr cell) record))
        (setq total (agent-usage--accumulate total record))))
    (append (cl-sort groups #'> :key (lambda (group)
                                       (agent-usage-tokens (cdr group) without-cache)))
            (list (cons t total)))))

(defun agent-usage-series (records start step count)
  "RECORDS summed into COUNT buckets of STEP seconds from time START.
Return a vector of summaries (nil for an empty bucket), oldest first."
  (let ((result (make-vector count nil)))
    (dolist (record records)
      (let ((index (floor (- (plist-get record :time) start) step)))
        (when (and (>= index 0) (< index count))
          (aset result index (agent-usage--accumulate (aref result index) record)))))
    result))

(defun agent-usage-filter (records &rest criteria)
  "RECORDS matching CRITERIA: :since TIME and any record key with a value."
  (let ((since (plist-get criteria :since)))
    (cl-remove-if-not
     (lambda (record)
       (and (or (null since) (>= (plist-get record :time) since))
            (cl-loop for (key value) on criteria by #'cddr
                     always (or (eq key :since) (equal (plist-get record key) value)))))
     records)))

;;; Quota

(defvar agent-usage--quotas 'unloaded
  "Latest quota of each agent: alist ((AGENT . HOST) . PLIST).
HOST is nil for this machine, else the remote host the agent runs on.
PLIST has :time, :windows, a list of (:id ID :label LABEL :used FRACTION
:resets TIME), and :balance, a list of (:amount NUMBER :currency STRING).")

(defun agent-usage-quotas ()
  "The latest quota of each agent, read from `agent-usage-quota-file' once."
  (when (eq agent-usage--quotas 'unloaded)
    (setq agent-usage--quotas
          (or (and (file-readable-p agent-usage-quota-file)
                   (ignore-errors
                     (with-temp-buffer
                       (insert-file-contents agent-usage-quota-file)
                       (read (current-buffer)))))
              nil)))
  agent-usage--quotas)

(defun agent-usage--save-quotas ()
  "Write the quotas to `agent-usage-quota-file'."
  (make-directory (file-name-directory agent-usage-quota-file) t)
  (let ((coding-system-for-write 'utf-8-unix)
        (print-length nil)
        (print-level nil))
    (write-region (prin1-to-string agent-usage--quotas) nil agent-usage-quota-file nil 'silent)))

(defun agent-usage--merge-windows (old new)
  "Windows OLD updated by NEW, matched by :id, in NEW's order then OLD's."
  (append new (cl-remove-if (lambda (window)
                              (cl-find (plist-get window :id) new
                                       :key (lambda (w) (plist-get w :id)) :test #'equal))
                            old)))

(defun agent-usage-set-quota (session &rest props)
  "Note what the account of SESSION's agent has left.
PROPS: :windows, rate-limit windows (:id ID :label LABEL :used FRACTION
:resets TIME), merged into the known ones by :id; :balance, a list of
(:amount NUMBER :currency STRING), shown in the echo area; others, such
as :plan or :credits, shown on the usage page.  A nil value keeps the
known one."
  (let* ((key (cons (agent-session-agent session)
                    (file-remote-p (agent-session-root session) 'host)))
         (quotas (agent-usage-quotas))
         (new (copy-sequence (cdr (assoc key quotas)))))
    (cl-loop for (prop value) on props by #'cddr
             do (setq new (plist-put new prop
                                     (if (eq prop :windows)
                                         (agent-usage--merge-windows (plist-get new :windows)
                                                                     value)
                                       (or value (plist-get new prop))))))
    (setq new (plist-put new :time (float-time)))
    (setq agent-usage--quotas (cons (cons key new) (assoc-delete-all key quotas)))
    (agent-usage--save-quotas)
    (run-hooks 'agent-usage-change-functions)))

(defun agent-usage-window-label (minutes)
  "Label of a rate-limit window lasting MINUTES."
  (cond ((null minutes) "限额")
        ((= minutes 10080) "周")
        ((= minutes 1440) "日")
        ((zerop (% minutes 60)) (format "%dh" (/ minutes 60)))
        (t (format "%dm" minutes))))

(defun agent-usage--window-left (window)
  "Fraction of WINDOW left, or nil once it has reset since it was reported."
  (let ((resets (plist-get window :resets)))
    (unless (and resets (< resets (float-time)))
      (max 0.0 (- 1.0 (or (plist-get window :used) 0))))))

(defun agent-usage--left-face (left)
  "Face of a quota with fraction LEFT."
  (cond ((null left) 'agent-session-dim)
        ((< left 0.05) 'agent-usage-out)
        ((< left 0.2) 'agent-usage-low)))

(defun agent-usage-money (amount currency)
  "AMOUNT of CURRENCY as text, e.g. $1.20 or ¥3.40."
  (pcase currency
    ("USD" (format "$%.2f" amount))
    ("CNY" (format "¥%.2f" amount))
    (_ (format "%.2f %s" amount (or currency "")))))

(defun agent-usage--duration (seconds)
  "SECONDS as a short Chinese duration, e.g. 2 时 13 分 or 3 天 4 时."
  (let ((minutes (max 0 (round seconds 60))))
    (cond ((< minutes 60) (format "%d 分" minutes))
          ((< minutes 1440) (format "%d 时 %d 分" (/ minutes 60) (% minutes 60)))
          (t (format "%d 天 %d 时" (/ minutes 1440) (/ (% minutes 1440) 60))))))

(defun agent-usage-window-help (window)
  "One line describing WINDOW for tooltips and pages."
  (let ((left (agent-usage--window-left window))
        (resets (plist-get window :resets)))
    (if (null left)
        (format "%s 窗口：已重置（%s）" (plist-get window :label)
                (format-time-string "%m-%d %H:%M" resets))
      (concat (format "%s 窗口：已用 %d%%，剩余 %d%%" (plist-get window :label)
                      (round (* 100 (or (plist-get window :used) 0))) (round (* 100 left)))
              (when resets
                (format "，%s后重置（%s）" (agent-usage--duration (- resets (float-time)))
                        (format-time-string "%m-%d %H:%M" resets)))))))

;;; Echo area line

(defcustom agent-usage-echo-windows '("5h" "周")
  "Labels of the rate-limit windows shown in the echo area."
  :type '(repeat string))

(defun agent-usage--agent-title (agent host)
  "Display name of AGENT running on HOST (nil for this machine)."
  (concat (or (agent-session--get agent :title) (symbol-name agent))
          (when host (concat "@" host))))

(defun agent-usage--quota-text (agent host quota)
  "Echo-area text for the QUOTA of AGENT on HOST."
  (let* ((windows (cl-remove-if-not (lambda (w) (member (plist-get w :label)
                                                        agent-usage-echo-windows))
                                    (plist-get quota :windows)))
         (parts
          (append
           (mapcar (lambda (window)
                     (let ((left (agent-usage--window-left window)))
                       (propertize (format "%s %s" (plist-get window :label)
                                           (if left (format "%d%%" (round (* 100 left)))
                                             "已重置"))
                                   'face (agent-usage--left-face left)
                                   'help-echo (agent-usage-window-help window))))
                   (cl-sort (copy-sequence windows) #'<
                            :key (lambda (w) (cl-position (plist-get w :label)
                                                          agent-usage-echo-windows
                                                          :test #'equal))))
           (mapcar (lambda (balance)
                     (propertize (concat "余额 " (agent-usage-money (plist-get balance :amount)
                                                                  (plist-get balance :currency)))
                                 'help-echo (format-time-string "余额更新于 %m-%d %H:%M"
                                                                (plist-get quota :time))))
                   (plist-get quota :balance)))))
    (when parts
      (concat (propertize (agent-usage--agent-title agent host) 'face 'bold)
              " " (string-join parts " · ")))))

(defun agent-usage--account (quota)
  "What identifies the account of QUOTA: its windows' reset times.
Two hosts signed in to one account report the same windows."
  (and (plist-get quota :windows)
       (sort (mapcar (lambda (window) (cons (plist-get window :id) (plist-get window :resets)))
                     (plist-get quota :windows))
             (lambda (a b) (string< (car a) (car b))))))

(defun agent-usage-shown-quotas ()
  "The quotas to show: ((AGENT . HOST) . QUOTA) in display order.
Agents come in the order they were registered, this machine first; a
remote host on an account already shown is left out."
  (let ((order (reverse (mapcar #'car agent-session-agents)))
        shown)
    (dolist (entry (cl-sort (copy-sequence (agent-usage-quotas)) #'<
                            :key (lambda (entry)
                                   (+ (if (cdar entry) 100 0)
                                      (or (cl-position (caar entry) order) 99)))))
      (let ((account (agent-usage--account (cdr entry))))
        (unless (and (cdar entry) account
                     (cl-find-if (lambda (other)
                                   (and (eq (caar other) (caar entry))
                                        (equal (agent-usage--account (cdr other)) account)))
                                 shown))
          (push entry shown))))
    (nreverse shown)))

(defun agent-usage-echo-text ()
  "The quota line shown in the echo area, or nil if nothing is known."
  (let (parts)
    (dolist (entry (agent-usage-shown-quotas))
      (when-let* ((text (agent-usage--quota-text (caar entry) (cdar entry) (cdr entry))))
        (push text parts)))
    (when parts
      (propertize (string-join (nreverse parts) "    ")
                  'mouse-face 'highlight
                  'keymap (define-keymap "<mouse-1>" #'agent-usage)
                  'help-echo "点击查看用量"))))

(defconst agent-usage--echo-buffer " *Minibuf-0*"
  "Buffer the echo area shows while there is no message.")

(defvar agent-usage--echo-timer nil
  "Timer redrawing the echo line when the next window resets.")

(defun agent-usage--next-reset ()
  "The earliest time a known window resets, if any is still ahead."
  (let ((now (float-time)))
    (cl-loop for (_ . quota) in (agent-usage-quotas)
             append (cl-loop for window in (plist-get quota :windows)
                             for resets = (plist-get window :resets)
                             when (and resets (> resets now)) collect resets)
             into times
             finally return (and times (apply #'min times)))))

(defvar agent-usage-echo-mode)

(defun agent-usage-echo-refresh ()
  "Redraw the quota line in the echo area."
  (when-let* ((buffer (get-buffer agent-usage--echo-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (text (and agent-usage-echo-mode (agent-usage-echo-text))))
        (erase-buffer)
        (when text
          ;; Right-aligned, like the right half of the mode lines above.
          (insert (propertize " " 'display `(space :align-to (- right ,(1+ (string-width text)))))
                  text)))))
  ;; Local data only: a window that resets turns into "已重置" on time.
  (when (timerp agent-usage--echo-timer) (cancel-timer agent-usage--echo-timer))
  (setq agent-usage--echo-timer
        (when-let* ((agent-usage-echo-mode)
                    (next (agent-usage--next-reset)))
          (run-at-time (- (+ next 1) (float-time)) nil #'agent-usage-echo-refresh))))

;;;###autoload
(define-minor-mode agent-usage-echo-mode
  "Show what the agents' accounts have left in the echo area while idle."
  :global t
  (if agent-usage-echo-mode
      (add-hook 'agent-usage-change-functions #'agent-usage-echo-refresh)
    (remove-hook 'agent-usage-change-functions #'agent-usage-echo-refresh))
  (agent-usage-echo-refresh))

;;; Usage page
;;
;; Modeled on magpie's usage page (github.com/yetone/magpie): the accounts'
;; allowances first, then the period's headline numbers, its timeline, and
;; the usage split by harness, model and project, each row with its share
;; of the tokens.  A row filters the page to it.

;; The theme (init-theme.el) gives these the colors of its palette.
(defface agent-usage-bar '((t :inherit link :underline nil))
  "Filled part of the bars on the usage page.")
(defface agent-usage-track
  '((((background dark)) :foreground "#3B4252")
    (t :foreground "#ECEFF1"))
  "Empty part of the bars on the usage page.")
(defface agent-usage-big '((t :inherit bold :height 1.4))
  "Headline numbers of the usage page.")
(defface agent-usage-heading '((t :inherit (bold shadow)))
  "Section headings of the usage page.")

(defconst agent-usage--buffer "*agent-usage*"
  "Name of the usage page buffer.")

(defconst agent-usage--ranges
  '((today . "今天") (week . "7 天") (month . "30 天") (all . "全部"))
  "Periods the usage page offers, with their labels.")

(defvar-local agent-usage--range 'week
  "Period the usage page shows, a key of `agent-usage--ranges'.")
(defvar-local agent-usage--filter nil
  "Plist of record keys and values: the page shows only matching records.")
(defvar-local agent-usage--without-cache nil
  "Non-nil if the page's token totals leave out the prompt cache.")

(defvar agent-usage-refresh-functions nil
  "Functions called with no arguments to ask the agents for their quota.
The usage page's refresh calls them; they should only ask agents already
running, never start one.")

(defun agent-usage--width ()
  "Width of the window showing the usage page, in columns.
Not the selected window's: the page is also redrawn from elsewhere."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window)
    80))

(defun agent-usage--count (n)
  "Token count N in short form: 980, 12.3k, 4.5M."
  (cond ((>= n 1e9) (format "%.1fB" (/ n 1e9)))
        ((>= n 1e6) (format "%.1fM" (/ n 1e6)))
        ((>= n 1e4) (format "%.0fk" (/ n 1e3)))
        ((>= n 1e3) (format "%.1fk" (/ n 1e3)))
        (t (format "%d" n))))

(defun agent-usage--bar (fraction width &optional face)
  "A horizontal bar WIDTH cells wide, filled to FRACTION, in FACE."
  (let* ((eighths (round (* (max 0.0 (min 1.0 fraction)) width 8)))
         (full (/ eighths 8))
         (part (% eighths 8))
         (face (or face 'agent-usage-bar)))
    (concat (propertize (make-string full ?█) 'face face)
            (when (> part 0)
              (propertize (string (aref "▏▎▍▌▋▊▉" (1- part)))
                          'face (list face (list :background
                                                 (face-foreground 'agent-usage-track nil t)))))
            (propertize (make-string (- width full (if (> part 0) 1 0)) ?█)
                        'face 'agent-usage-track))))

(defun agent-usage--align (column)
  "Whitespace reaching COLUMN, measured in canonical characters."
  (propertize " " 'display `(space :align-to ,column)))

(defun agent-usage--align-right (text)
  "Whitespace placing TEXT against the right edge."
  (propertize " " 'display `(space :align-to (- right ,(1+ (string-width text))))))

(defun agent-usage--button (label action &optional selected help)
  "A clickable LABEL running ACTION; SELECTED draws it as the current choice."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] action)
    (define-key map (kbd "RET") action)
    (propertize label 'face (if selected 'agent-session-button 'agent-session-dim)
                'mouse-face (list 'highlight) 'keymap map
                'help-echo help 'agent-usage-button t)))

(defun agent-usage--project-name (root)
  "Short name of project ROOT: its directory, @host when remote."
  (concat (file-name-nondirectory (directory-file-name (or (file-remote-p root 'localname) root)))
          (when-let* ((host (file-remote-p root 'host))) (concat "@" host))))

(defun agent-usage--group-name (key value)
  "Display name of the group whose KEY is VALUE."
  (pcase key
    (:agent (agent-usage--agent-title value nil))
    (:root (agent-usage--project-name value))
    (_ (or value "未知模型"))))

;;;; Allowances

(defun agent-usage--pace (window)
  "How far WINDOW's use is ahead of an even pace, in percent, or nil.
Positive: at this rate it runs out before it resets."
  (when-let* ((minutes (plist-get window :minutes))
              (resets (plist-get window :resets))
              (start (- resets (* 60 minutes)))
              (now (float-time))
              ((< start now resets)))
    (round (* 100 (- (or (plist-get window :used) 0)
                     (/ (- now start) (* 60.0 minutes)))))))

(defun agent-usage--insert-window (window)
  "Insert the line of rate-limit WINDOW."
  (let* ((left (agent-usage--window-left window))
         (resets (plist-get window :resets))
         (pace (and left (agent-usage--pace window)))
         (width (max 10 (min 30 (- (agent-usage--width) 60)))))
    (insert "    " (plist-get window :label) (agent-usage--align 12)
            (agent-usage--bar (or left 1) width
                              (or (agent-usage--left-face left) 'agent-usage-bar))
            "  "
            (propertize (if left (format "%d%%" (round (* 100 left))) "已重置")
                        'face (or (agent-usage--left-face left) 'bold)))
    (when (and left resets)
      (insert (agent-usage--align (+ 22 width))
              (propertize (format "%s后重置" (agent-usage--duration (- resets (float-time))))
                          'face 'agent-session-dim
                          'help-echo (format-time-string "%m-%d %H:%M 重置" resets))))
    (when pace
      (insert (propertize " · " 'face 'agent-session-dim)
              (propertize (cond ((> pace 0) (format "超速 %d%%" pace))
                                ((< pace 0) (format "有余 %d%%" (- pace)))
                                (t "匀速"))
                          'face (if (> pace 0) 'agent-usage-low 'agent-session-dim)
                          'help-echo
                          (concat "已用比例减去窗口已过时间的比例。"
                                  (if (> pace 0)
                                      (format "比匀速多用了 %d%%：照这个速度会在重置前用完" pace)
                                    (format "比匀速少用了 %d%%：照这个速度能撑到重置" (- pace)))))))
    (insert "\n")))

(defun agent-usage--age (time)
  "How long ago TIME was, as text."
  (let ((seconds (- (float-time) time)))
    (if (< seconds 60) "刚刚" (concat (agent-usage--duration seconds) "前"))))

(defun agent-usage--insert-quotas ()
  "Insert the allowances section."
  (insert (propertize "额度" 'face 'agent-usage-heading) "\n")
  (let ((quotas (agent-usage-shown-quotas)))
    (if (null quotas)
        (insert (propertize "    还没有 agent 报告过额度：用一次 Claude、Codex 或 DeepSeek 后这里就有了\n"
                            'face 'agent-session-dim))
      (dolist (entry quotas)
        (let ((quota (cdr entry))
              (title (agent-usage--agent-title (caar entry) (cdar entry))))
          (insert "  " (propertize title 'face 'bold)
                  (if-let* ((plan (plist-get quota :plan)))
                      (propertize (format " · %s" plan) 'face 'agent-session-dim)
                    ""))
          (let ((age (concat "更新于 " (agent-usage--age (plist-get quota :time)))))
            (insert (agent-usage--align-right age) (propertize age 'face 'agent-session-dim) "\n"))
          (mapc #'agent-usage--insert-window
                (cl-sort (copy-sequence (plist-get quota :windows)) #'<
                         :key (lambda (w) (or (plist-get w :minutes) 0))))
          (dolist (balance (plist-get quota :balance))
            (insert "    余额" (agent-usage--align 12)
                    (propertize (agent-usage-money (plist-get balance :amount)
                                                   (plist-get balance :currency))
                                'face 'bold)
                    "\n"))
          (when-let* ((credits (plist-get quota :credits)))
            (insert "    credits" (agent-usage--align 12)
                    (propertize (cond ((not (numberp credits)) "不限")
                                      ((= credits (round credits)) (format "%d" credits))
                                      (t (format "%.2f" credits)))
                                'face 'bold)
                    "\n")))))))

;;;; Headline and timeline

(defun agent-usage--insert-tiles (tiles)
  "Insert TILES side by side: each a list of a number, a label and a note."
  (let ((width (/ (- (agent-usage--width) 2) (max 1 (length tiles)))))
    (cl-loop for line from 0 below 3
             do (cl-loop for tile in tiles
                         for index from 0
                         for text = (nth line tile)
                         do (insert (agent-usage--align (+ 2 (* index width)))
                                    (pcase line
                                      (0 (propertize (or text "—") 'face 'agent-usage-big))
                                      (1 (propertize (or text "") 'face 'bold))
                                      (_ (propertize (or text "") 'face 'agent-session-dim)))))
             (insert "\n"))))

(defun agent-usage--insert-headline (total)
  "Insert the headline numbers of TOTAL, the period's summary."
  (let* ((prompt (+ (plist-get total :input) (plist-get total :cache-read)
                    (plist-get total :cache-write)))
         (cache (+ (plist-get total :cache-read) (plist-get total :cache-write))))
    (agent-usage--insert-tiles
     (list (list (agent-usage--count (agent-usage-tokens total agent-usage--without-cache))
                 (if agent-usage--without-cache "token（不含缓存）" "token（含缓存）")
                 (if agent-usage--without-cache
                     (format "另有缓存 %s" (agent-usage--count cache))
                   (format "其中缓存 %s" (agent-usage--count cache))))
           (list (agent-usage--count (plist-get total :output)) "输出"
                 (format "输入 %s（不含缓存）" (agent-usage--count (plist-get total :input))))
           (list (agent-usage--count (plist-get total :cache-read)) "缓存读取"
                 (if (> prompt 0)
                     (format "命中率 %d%%" (round (* 100.0 (plist-get total :cache-read)) prompt))
                   ""))
           (list (format "%d" (plist-get total :turns)) "轮次"
                 (if (> (plist-get total :child-turns) 0)
                     (format "子 agent %d 轮" (plist-get total :child-turns))
                   ""))))))

(defun agent-usage--buckets (records)
  "Buckets of the timeline for RECORDS: (START STEP COUNT LABEL-FORMAT)."
  (let ((today (agent-usage-since 'today)))
    (pcase agent-usage--range
      ('today (list today 3600 24 "%H"))
      ('week (list (agent-usage-since 'week) 86400 7 "%m-%d"))
      ('month (list (agent-usage-since 'month) 86400 30 "%m-%d"))
      (_ (let* ((first (if records
                           (cl-loop for record in records minimize (plist-get record :time))
                         today))
                (days (1+ (floor (- today first) 86400))))
           (if (<= days 60)
               (list (- today (* 86400 (max 6 (1- days)))) 86400 (max 7 days) "%m-%d")
             (let ((weeks (min 52 (ceiling days 7.0))))
               (list (- today (* 86400 7 (1- weeks)) (* 86400 6)) (* 86400 7) weeks "%m-%d"))))))))

(defun agent-usage--insert-timeline (records)
  "Insert the bar chart of RECORDS' tokens over the period."
  (pcase-let* ((`(,start ,step ,count ,label-format) (agent-usage--buckets records))
               (series (agent-usage-series records start step count))
               (values (cl-map 'list (lambda (sum)
                                       (if sum (agent-usage-tokens sum agent-usage--without-cache) 0))
                               series))
               (peak (max 1 (apply #'max values)))
               (height 5)
               (indent 8)
               (cell (max 1 (min 6 (/ (- (agent-usage--width) indent 2) count))))
               (bar (max 1 (1- cell)))
               ;; A label is at most 5 characters and a space.
               (every (max 1 (ceiling 6.0 cell))))
    (insert (propertize (if (eq agent-usage--range 'today) "按时段" "每日趋势")
                        'face 'agent-usage-heading)
            "\n")
    (dotimes (row height)
      ;; The peak's label takes the indentation of the first row: exactly
      ;; as wide, or the tops of the bars would stand askew.
      (insert (if (zerop row)
                  (propertize (format (format "%%%ds " (1- indent)) (agent-usage--count peak))
                              'face 'agent-session-dim)
                (make-string indent ?\s)))
      (cl-loop for value in values
               for index from 0
               for sum = (aref series index)
               for eighths = (round (* 8.0 height value) peak)
               for level = (- eighths (* 8 (- height row 1)))
               for char = (cond ((>= level 8) ?█)
                                ((<= level 0) (if (and (= row (1- height)) (zerop value)) ?▁ ?\s))
                                (t (aref "▁▂▃▄▅▆▇" (1- level))))
               do (insert (propertize
                           (concat (make-string bar char) (make-string (- cell bar) ?\s))
                           'face (if (zerop value) 'agent-usage-track 'agent-usage-bar)
                           'help-echo
                           (concat (format-time-string (if (eq agent-usage--range 'today)
                                                           "%H:00" "%m-%d")
                                                       (+ start (* index step)))
                                   (if sum
                                       (format " · %s token · %d 轮"
                                               (agent-usage--count value)
                                               (plist-get sum :turns))
                                     " · 没有用量")))))
      (insert "\n"))
    (insert (make-string indent ?\s))
    (let ((labels (make-string (* cell count) ?\s)))
      (cl-loop for index from 0 below count by every
               for label = (format-time-string label-format (+ start (* index step)))
               for column = (* index cell)
               when (<= (+ column (length label)) (length labels))
               do (store-substring labels column label))
      (insert (propertize labels 'face 'agent-session-dim) "\n"))))

;;;; Groups

(defun agent-usage--insert-group (heading key records)
  "Insert section HEADING: RECORDS summed by KEY, one row per value."
  (let* ((groups (agent-usage-summarize records key agent-usage--without-cache))
         (total (max 1 (agent-usage-tokens (cdar (last groups)) agent-usage--without-cache)))
         (width (agent-usage--width))
         (bar (max 8 (min 20 (- width 70))))
         (share-column 30)
         (tokens-column (+ share-column bar 7)))
    (insert (propertize heading 'face 'agent-usage-heading) "\n")
    (pcase-dolist (`(,value . ,sum) (butlast groups))
      (let* ((tokens (agent-usage-tokens sum agent-usage--without-cache))
             (share (/ (float tokens) total))
             (prompt (+ (plist-get sum :input) (plist-get sum :cache-read)
                        (plist-get sum :cache-write)))
             (start (point)))
        (insert "  " (truncate-string-to-width (agent-usage--group-name key value)
                                               (- share-column 4) nil nil "…")
                (agent-usage--align share-column)
                (agent-usage--bar share bar)
                (propertize (format " %3d%%" (round (* 100 share))) 'face 'agent-session-dim)
                (agent-usage--align tokens-column)
                (propertize (agent-usage--count tokens) 'face 'bold)
                "\n"
                "    "
                (propertize (concat (format "%d 轮" (plist-get sum :turns))
                                    (if (> (plist-get sum :child-turns) 0)
                                        (format " · 子 agent %d 轮" (plist-get sum :child-turns))
                                      ""))
                            'face 'agent-session-dim)
                (agent-usage--align tokens-column)
                (propertize (concat (format "输入 %s · 输出 %s"
                                            (agent-usage--count (plist-get sum :input))
                                            (agent-usage--count (plist-get sum :output)))
                                    (if (> (plist-get sum :cache-read) 0)
                                        (format " · 缓存 %s · 命中 %d%%"
                                                (agent-usage--count (plist-get sum :cache-read))
                                                (round (* 100.0 (plist-get sum :cache-read)) prompt))
                                      ""))
                            'face 'agent-session-dim)
                "\n")
        (add-text-properties start (point)
                             (list 'agent-usage-select (cons key value)
                                   'mouse-face (list 'highlight)
                                   'help-echo (concat (if (eq key :root) (concat value "\n") "")
                                                      "RET 只看这一项")))))
    (insert "\n")))

;;;; The page

(defun agent-usage--records-shown ()
  "Records of the page's period that match its filter."
  (apply #'agent-usage-filter (agent-usage-records)
         :since (agent-usage-since agent-usage--range)
         agent-usage--filter))

(defun agent-usage--insert-header ()
  "Insert the title line: periods, cache toggle, filter."
  (insert (propertize "用量" 'face 'agent-usage-big) "   ")
  (pcase-dolist (`(,range . ,label) agent-usage--ranges)
    (insert (agent-usage--button label (lambda () (interactive) (agent-usage-set-range range))
                                 (eq range agent-usage--range))
            " "))
  (insert "  " (agent-usage--button (if agent-usage--without-cache "不含缓存" "含缓存")
                                    #'agent-usage-toggle-cache nil
                                    "token 汇总是否计入缓存读取与写入（c）"))
  (cl-loop for (key value) on agent-usage--filter by #'cddr
           do (insert "  " (agent-usage--button
                            (format "%s ×" (agent-usage--group-name key value))
                            (lambda () (interactive) (agent-usage-unfilter key))
                            t "取消这个筛选（u）")))
  (insert "\n\n"))

(defun agent-usage--render ()
  "Draw the usage page in the current buffer, keeping point's line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (records (agent-usage--records-shown)))
    (erase-buffer)
    (agent-usage--insert-header)
    (agent-usage--insert-quotas)
    (insert "\n")
    (if (null records)
        (insert (propertize (format "%s没有用量。从 Emacs 启动的 agent 会话，每一轮都会记在这里。\n"
                                    (if (eq agent-usage--range 'all) "还" "这段时间"))
                            'face 'agent-session-dim))
      (agent-usage--insert-headline (cdar (last (agent-usage-summarize records :agent))))
      (insert "\n")
      (agent-usage--insert-timeline records)
      (insert "\n")
      (agent-usage--insert-group "Harness" :agent records)
      (agent-usage--insert-group "模型" :model records)
      (agent-usage--insert-group "项目" :root records))
    (insert (propertize (format "只统计从这个 Emacs 启动的会话（含子 agent），按各 agent 报告的用量记录 · %s\n"
                                (abbreviate-file-name agent-usage-file))
                        'face 'agent-session-dim))
    (goto-char (point-min))
    (forward-line (1- line))))

(defvar agent-usage--redraw-timer nil
  "Idle timer redrawing the usage page after a change.")

(defun agent-usage--schedule-redraw ()
  "Redraw the usage page soon if it is on screen."
  (when-let* ((buffer (get-buffer agent-usage--buffer))
              ((get-buffer-window buffer t))
              ((not (timerp agent-usage--redraw-timer))))
    (setq agent-usage--redraw-timer
          (run-with-idle-timer
           0.5 nil
           (lambda ()
             (setq agent-usage--redraw-timer nil)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (let* ((windows (get-buffer-window-list buffer nil t))
                        (starts (mapcar #'window-start windows)))
                   (agent-usage--render)
                   (cl-mapc #'set-window-start windows starts)))))))))

(add-hook 'agent-usage-change-functions #'agent-usage--schedule-redraw)

(defun agent-usage--theme-changed (&rest _)
  "Redraw what blends the theme's colors when it changes."
  (agent-usage--schedule-redraw))

;; The partly filled cell of a bar takes the track color as background.
(add-hook 'enable-theme-functions #'agent-usage--theme-changed)

(defun agent-usage-set-range (range)
  "Show the period RANGE, a key of `agent-usage--ranges'."
  (setq agent-usage--range range)
  (agent-usage--render))

(defun agent-usage-cycle-range ()
  "Show the next period."
  (interactive)
  (let ((ranges (mapcar #'car agent-usage--ranges)))
    (agent-usage-set-range (or (cadr (memq agent-usage--range ranges)) (car ranges)))))

(defun agent-usage-today () "Show today's usage." (interactive) (agent-usage-set-range 'today))
(defun agent-usage-week () "Show the last 7 days." (interactive) (agent-usage-set-range 'week))
(defun agent-usage-month () "Show the last 30 days." (interactive) (agent-usage-set-range 'month))
(defun agent-usage-all () "Show all usage." (interactive) (agent-usage-set-range 'all))

(defun agent-usage-toggle-cache ()
  "Count the prompt cache in the token totals, or leave it out."
  (interactive)
  (setq agent-usage--without-cache (not agent-usage--without-cache))
  (agent-usage--render))

(defun agent-usage-select ()
  "Show only the usage of the row at point; on a button, press it."
  (interactive)
  (if-let* ((map (get-text-property (point) 'keymap))
            (action (lookup-key map (kbd "RET"))))
      (call-interactively action)
    (if-let* ((selection (get-text-property (point) 'agent-usage-select)))
        (progn (setq agent-usage--filter (plist-put agent-usage--filter
                                                    (car selection) (cdr selection)))
               (agent-usage--render)
               (goto-char (point-min)))
      (user-error "这里没有可以筛选的行"))))

(defun agent-usage-unfilter (&optional key)
  "Drop the filter on KEY, or the latest one."
  (interactive)
  (unless agent-usage--filter (user-error "没有筛选"))
  (let ((key (or key (car (last agent-usage--filter 2)))))
    (setq agent-usage--filter (cl-loop for (k v) on agent-usage--filter by #'cddr
                                       unless (eq k key) append (list k v))))
  (agent-usage--render))

(defun agent-usage--move (direction)
  "Move to the next row or button in DIRECTION (1 or -1)."
  (let ((here (point)))
    (forward-line direction)
    (while (and (not (if (> direction 0) (eobp) (bobp)))
                (not (get-text-property (point) 'agent-usage-select)))
      (forward-line direction))
    (unless (get-text-property (point) 'agent-usage-select)
      (goto-char here))
    ;; A row has two lines: stay on its first.
    (when (and (> direction 0)
               (equal (get-text-property (point) 'agent-usage-select)
                      (get-text-property (line-beginning-position 0) 'agent-usage-select))
               (not (eq (point) here)))
      (agent-usage--move 1))))

(defun agent-usage-next ()
  "Move to the next row."
  (interactive)
  (agent-usage--move 1))

(defun agent-usage-previous ()
  "Move to the previous row."
  (interactive)
  (agent-usage--move -1)
  (while (and (not (bobp))
              (get-text-property (line-beginning-position 0) 'agent-usage-select)
              (equal (get-text-property (line-beginning-position 0) 'agent-usage-select)
                     (get-text-property (point) 'agent-usage-select)))
    (forward-line -1)))

(defun agent-usage-refresh (&rest _)
  "Read the records again and ask the running agents for their quota."
  (interactive)
  (setq agent-usage--loaded nil)
  (run-hooks 'agent-usage-refresh-functions)
  (agent-usage--render))

(defvar-keymap agent-usage-mode-map
  :doc "Keys of the usage page."
  :parent special-mode-map
  "RET" #'agent-usage-select
  "u" #'agent-usage-unfilter
  "r" #'agent-usage-cycle-range
  "d" #'agent-usage-today
  "w" #'agent-usage-week
  "m" #'agent-usage-month
  "a" #'agent-usage-all
  "c" #'agent-usage-toggle-cache
  "n" #'agent-usage-next
  "p" #'agent-usage-previous)

(define-derived-mode agent-usage-mode special-mode "Agent-Usage"
  "What the agents started from Emacs used, and what their accounts have left.
\\{agent-usage-mode-map}"
  (setq-local revert-buffer-function #'agent-usage-refresh
              truncate-lines t)
  (add-hook 'window-size-change-functions
            (lambda (_) (agent-usage--schedule-redraw)) nil t))

;;;###autoload
(defun agent-usage ()
  "Show the usage page."
  (interactive)
  (let ((buffer (get-buffer-create agent-usage--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-usage-mode) (agent-usage-mode)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer (agent-usage--render))))

(provide 'agent-usage)
;;; agent-usage.el ends here
