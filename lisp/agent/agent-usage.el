;;; agent-usage.el --- Usage and quota of the agents Emacs runs -*- lexical-binding: t; -*-

;;; Commentary:
;; The daemon owns token accounting and quota polling (emx/usage/).
;; Emacs displays pushed quotas and asynchronous usage reports.  Its durable
;; producer transport retains pending upgrade records and relays host usage.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-session)

(declare-function my/var "init-base")
(declare-function agent-emx--local-connection "agent-emx")
(declare-function agent-emx--request "agent-emx")
(declare-function agent-emx--write "agent-emx")
(declare-function agent-emx--connection-ready "agent-emx")
(declare-function agent-emx--connection-process "agent-emx")
(declare-function agent-emx--connection-var "agent-emx")
(declare-function agent-emx--connection-capabilities "agent-emx")
(defvar agent-emx-var-directory)

(defgroup agent-usage nil
  "Usage and quota of the agents Emacs runs."
  :group 'agent-session)

(defun agent-usage--var (name)
  "Path of NAME under the runtime directory var/."
  (if (fboundp 'my/var) (my/var name) (locate-user-emacs-file (concat "var/" name))))

(defcustom agent-usage-file (agent-usage--var "agent-usage.jsonl")
  "File of the usage records, one JSON object per line, kept by emx."
  :type 'file)

(defcustom agent-usage-quota-file (agent-usage--var "agent-quota.json")
  "File of the latest quota of each agent and its readings, kept by emx."
  :type 'file)

(defface agent-usage-low '((t :inherit warning))
  "Quota running low.")
(defface agent-usage-out '((t :inherit error))
  "Quota (nearly) used up.")

;;; The emx service

(defvar agent-usage--connection nil "The local usage-only daemon connection.")
(defvar agent-usage--outbox nil "Usage entries retained until acknowledged by producer sequence.")
(defvar agent-usage--inflight (make-hash-table :test #'equal)
  "Ids already sent on the current connection.")
(defvar agent-usage--monitoring nil "Non-nil while usage should reconnect.")
(defvar agent-usage--retry-timer nil "Pending asynchronous reconnect timer.")
(defvar agent-usage--retry-delay 2 "Seconds until the next reconnect, at most 60.")
(defvar agent-usage--serial 0 "Sequence for this Emacs's stable usage ids.")
(defvar agent-usage--id-prefix
  (format "%s-%s-%s" (emacs-pid) (float-time) (random most-positive-fixnum))
  "Unique prefix for usage records from this Emacs process.")

(defun agent-usage--capable-p (connection)
  "Whether CONNECTION supports acknowledged usage delivery."
  (>= (or (plist-get (agent-emx--connection-capabilities connection) :usage) 0) 1))

(defun agent-usage--schedule-reconnect ()
  "Retry ensure and connect asynchronously with bounded backoff."
  (when (and agent-usage--monitoring (not (timerp agent-usage--retry-timer)))
    (setq agent-usage--retry-timer
          (run-at-time agent-usage--retry-delay nil
                       (lambda ()
                         (setq agent-usage--retry-timer nil)
                         (when agent-usage--monitoring
                           ;; Timer work must use asynchronous ensure even in tests.
                           (let ((noninteractive nil)) (agent-usage--start))))))
    (setq agent-usage--retry-delay (min 60 (* 2 agent-usage--retry-delay)))))

(defun agent-usage--disconnected (connection)
  "Retain outstanding work and retry after losing usage CONNECTION."
  (when (eq connection agent-usage--connection)
    (clrhash agent-usage--inflight)
    (agent-usage--schedule-reconnect)))

(defvar agent-usage--outbox-loaded nil "File whose durable outbox is loaded.")
(defvar server-name)

(defun agent-usage--outbox-file ()
  "Return this process's durable producer state file."
  (expand-file-name
   (concat "emx/editor-usage-" (secure-hash 'sha256 agent-usage--id-prefix) ".el")
   agent-emx-var-directory))

(defun agent-usage--read-outbox (file)
  "Read producer state from FILE, or nil if another editor recovered it."
  (condition-case nil
      (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
    (file-missing nil)))

(defun agent-usage--save-outbox ()
  "Atomically retain producer identity, sequence and unacknowledged entries."
  (let* ((file (agent-usage--outbox-file))
         (dir (file-name-directory file)))
    (make-directory dir t)
    (let ((temp (make-temp-file (expand-file-name ".editor-usage-" dir))))
      (unwind-protect
          (progn
            (with-temp-file temp
              (let ((print-length nil) (print-level nil))
                (prin1 (list :pid (emacs-pid) :host (system-name)
                             :source agent-usage--id-prefix :sequence agent-usage--serial
                             :entries agent-usage--outbox) (current-buffer))))
            (set-file-modes temp #o600)
            (rename-file temp file t))
        (when (file-exists-p temp) (delete-file temp))))))

(defun agent-usage--restore-outbox ()
  "Restore this producer and recover abandoned pending entries.
Recovery preserves delivery identities, but never adopts another source.
Two editors may recover the same dead producer: delivery is idempotent and
neither editor will allocate new sequence numbers from that producer."
  (let ((file (agent-usage--outbox-file)) changed recovered)
    (unless (equal file agent-usage--outbox-loaded)
      (when-let* ((state (agent-usage--read-outbox file)))
        (setq agent-usage--serial (plist-get state :sequence)
              agent-usage--outbox (append (plist-get state :entries) agent-usage--outbox)))
      (let ((dir (file-name-directory file)))
        (when (file-directory-p dir)
          (dolist (other (directory-files dir t "\\`editor-usage-.*\\.el\\'"))
            (unless (equal other file)
              (when-let* ((state (agent-usage--read-outbox other))
                          ((and (integerp (plist-get state :pid))
                                (equal (plist-get state :host) (system-name))
                                (not (process-attributes (plist-get state :pid))))))
                (setq agent-usage--outbox
                      (append agent-usage--outbox (plist-get state :entries))
                      changed t)
                (push other recovered))))))
      ;; A recovery interrupted after save can leave duplicate pending entries.
      (setq agent-usage--outbox
            (cl-delete-duplicates agent-usage--outbox :key (lambda (e) (plist-get e :id))
                                  :test #'equal)
            agent-usage--outbox-loaded file))
    (when changed
      ;; Save the complete recovery before removing any abandoned file.
      (agent-usage--save-outbox)
      (dolist (other recovered)
        (condition-case nil (delete-file other) (file-missing nil))))))

(defun agent-usage--flush-outbox (connection)
  "Send retained entries to capable CONNECTION; remove only matching acks."
  (agent-usage--restore-outbox)
  (when (agent-usage--capable-p connection)
    (dolist (entry (sort (copy-sequence agent-usage--outbox)
                        (lambda (a b) (< (plist-get a :sequence)
                                         (plist-get b :sequence)))))
      (let ((id (plist-get entry :id)))
        (unless (gethash id agent-usage--inflight)
          (puthash id t agent-usage--inflight)
          (agent-emx--request
           connection (concat "usage/" (plist-get entry :method))
           (agent-usage--nulls
            (append (list :id id :source (plist-get entry :source)
                          :sequence (plist-get entry :sequence)) (plist-get entry :params)))
           (lambda (ack)
             (when (and (equal (plist-get ack :source) (plist-get entry :source))
                        (numberp (plist-get ack :sequence))
                        (>= (plist-get ack :sequence) (plist-get entry :sequence)))
               (remhash id agent-usage--inflight)
               (let ((before (length agent-usage--outbox)))
                 (setq agent-usage--outbox
                     (cl-delete-if
                      (lambda (item)
                        (and (equal (plist-get item :source) (plist-get ack :source))
                             (<= (plist-get item :sequence) (plist-get ack :sequence))))
                      agent-usage--outbox))
                 (unless (= before (length agent-usage--outbox))
                   (agent-usage--save-outbox)))))
           (lambda (error)
             (remhash id agent-usage--inflight)
             (agent-usage--error error))))))))
(defvar agent-usage--snapshot nil
  "The quotas emx pushed last: a list of plists, in display order.")

(defvar agent-usage-change-functions nil
  "Functions called with no arguments after usage or quotas changed.")

(defun agent-usage--lists (value)
  "Decode daemon VALUE into the lists and booleans the usage UI uses."
  (cond ((memq value '(:false :null)) nil)
        ((vectorp value) (mapcar #'agent-usage--lists value))
        ((consp value) (cons (agent-usage--lists (car value))
                             (agent-usage--lists (cdr value))))
        (t value)))

(defun agent-usage--receive-quotas (quotas)
  "Display the daemon's pushed QUOTAS."
  (setq agent-usage--snapshot (agent-usage--lists quotas))
  (run-hooks 'agent-usage-change-functions))

(defun agent-usage--connected (connection)
  "Configure polling and flush retained records on ready usage CONNECTION."
  (when (agent-usage--capable-p connection)
    (setq agent-usage--connection connection
          agent-usage--retry-delay 2)
    (when (timerp agent-usage--retry-timer)
      (cancel-timer agent-usage--retry-timer))
    (setq agent-usage--retry-timer nil)
    (agent-emx--request
     connection "usage/configure"
     (list :agents (vconcat (mapcar #'symbol-name
                                   (reverse (mapcar #'car agent-session-agents)))))
     (lambda (result)
       (agent-usage--receive-quotas (plist-get result :quotas))
       (agent-usage--flush-outbox connection))
     #'agent-usage--error)))

(defun agent-usage--error (error)
  "Report daemon ERROR and schedule recovery without blocking the editor."
  (message "用量服务出错：%s" (plist-get error :message))
  (agent-usage--schedule-reconnect))

(defun agent-usage--json-record (record)
  "Old ledger RECORD, a plist with Lisp keys, as a JSON record."
  (append (list :time (plist-get record :time)
                :agent (format "%s" (plist-get record :agent))
                :root (or (plist-get record :root) :null)
                :session (or (plist-get record :session) :null)
                :model (or (plist-get record :model) :null))
          (when (plist-get record :child) (list :child t))
          (list :turns (or (plist-get record :turns) 1)
                :input (or (plist-get record :input) 0)
                :cache_read (or (plist-get record :cache-read) 0)
                :cache_write (or (plist-get record :cache-write) 0)
                :output (or (plist-get record :output) 0))))

(defun agent-usage--json-quota (entry)
  "Old quota ENTRY, ((AGENT . HOST) . PLIST), as a JSON quota entry."
  (let ((quota (cdr entry)))
    (append (list :agent (symbol-name (caar entry))
                  :host (or (cdar entry) :null)
                  :time (or (plist-get quota :time) 0)
                  :windows (vconcat
                            (mapcar (lambda (window)
                                      (append (agent-usage--json-window window)
                                              (list :history
                                                    (vconcat (mapcar (lambda (reading)
                                                                       (vector (car reading) (cdr reading)))
                                                                     (plist-get window :history))))))
                                    (plist-get quota :windows))))
            (when-let* ((plan (plist-get quota :plan))) (list :plan plan))
            (when-let* ((credits (plist-get quota :credits)))
              (list :credits (if (eq credits 'unlimited) "unlimited" credits)))
            (when-let* ((balance (plist-get quota :balance))) (list :balance (vconcat balance))))))

(defun agent-usage--migrate ()
  "Convert the Lisp files Emacs kept before emx did, once.
Each old file, next to its JSON successor, is converted when that doesn't
exist yet, and kept as .bak."
  (let ((coding-system-for-write 'no-conversion)
        (old-usage (expand-file-name "agent-usage.eld" (file-name-directory agent-usage-file)))
        (old-quota (expand-file-name "agent-quota.eld"
                                     (file-name-directory agent-usage-quota-file))))
    (when (and (file-exists-p old-usage) (not (file-exists-p agent-usage-file)))
      (let (lines)
        (with-temp-buffer
          (insert-file-contents old-usage)
          (goto-char (point-min))
          (while (not (eobp))
            (when-let* ((record (ignore-errors
                                  (car (read-from-string
                                        (buffer-substring-no-properties (point) (line-end-position))))))
                        ((plistp record)))
              (push (json-serialize (agent-usage--json-record record)) lines))
            (forward-line 1)))
        (make-directory (file-name-directory agent-usage-file) t)
        (write-region (mapconcat (lambda (line) (concat line "\n")) (nreverse lines) "")
                      nil agent-usage-file nil 'silent))
      (rename-file old-usage (concat old-usage ".bak") t))
    (when (and (file-exists-p old-quota) (not (file-exists-p agent-usage-quota-file)))
      (let ((quotas (ignore-errors (with-temp-buffer
                                     (insert-file-contents old-quota)
                                     (read (current-buffer))))))
        (make-directory (file-name-directory agent-usage-quota-file) t)
        (write-region (json-serialize (vconcat (mapcar #'agent-usage--json-quota quotas)))
                      nil agent-usage-quota-file nil 'silent))
      (rename-file old-quota (concat old-quota ".bak") t))))

(defun agent-usage--start ()
  "Find or asynchronously start the shared local daemon."
  (agent-usage--migrate)
  (require 'agent-emx)
  (setq agent-usage--monitoring t)
  (setq agent-usage--connection
        (agent-emx--local-connection #'agent-usage--connected
                                     #'agent-usage--error 'usage)))

(defun agent-usage--service ()
  "Ensure the daemon is connected; batch runs require an explicit start."
  (let ((process (and agent-usage--connection
                      (agent-emx--connection-process agent-usage--connection))))
    (if noninteractive
        ;; A pure transport test may have left a mock connection behind.
        ;; Batch calls must never discover or start the default daemon.
        (and (processp process) (process-live-p process)
             (equal (expand-file-name agent-emx-var-directory)
                    (agent-emx--connection-var agent-usage--connection))
             agent-usage--connection)
      (unless (and (processp process) (process-live-p process))
        (agent-usage--start))
      agent-usage--connection)))

(defun agent-usage--with-connection (callback)
  "Run CALLBACK once the usage daemon connection is ready."
  (when (agent-usage--service)
    (agent-emx--local-connection
     (lambda (connection)
       (when (agent-usage--capable-p connection) (funcall callback connection)))
     #'agent-usage--error 'usage)))

(defun agent-usage--notify (method params)
  "Retain usage METHOD with PARAMS until the daemon acknowledges its sequence."
  (agent-usage--restore-outbox)
  (let* ((id (format "%s-%s" agent-usage--id-prefix (cl-incf agent-usage--serial)))
         (quota (equal method "quota"))
         (key (when quota (cons (plist-get params :agent) (plist-get params :host))))
         (entry (list :id id :source agent-usage--id-prefix :sequence agent-usage--serial
                      :method method :key key
                      :params (if quota (list :reading params) params))))
    (setq agent-usage--outbox (append agent-usage--outbox (list entry)))
    (agent-usage--save-outbox)
    (agent-usage--with-connection #'agent-usage--flush-outbox)))

(defun agent-usage--nulls (value)
  "Convert Lisp JSON null markers in VALUE for agent-emx requests."
  (cond ((eq value :null) nil)
        ((consp value) (cons (agent-usage--nulls (car value))
                             (agent-usage--nulls (cdr value))))
        (t value)))

(defun agent-usage--request (method params callback)
  "Ask the daemon usage METHOD with PARAMS; call CALLBACK with the result."
  (agent-usage--with-connection
   (lambda (connection)
     (agent-emx--request connection (concat "usage/" method)
                         (agent-usage--nulls params)
                         (lambda (result) (funcall callback (agent-usage--lists result)))
                         #'agent-usage--error))))

(defun agent-usage-restart-service ()
  "Reconnect usage and reapply quota poll commands to the shared daemon.
The daemon's code is updated by its normal version/restart mechanism."
  (interactive)
  (agent-usage--start)
  (agent-usage--with-connection #'agent-usage--connected))

(defun agent-usage-refresh-quotas (&optional force)
  "Have emx poll the quotas not reported lately; all of them with FORCE."
  (interactive (list t))
  (agent-usage--request "refresh" (list :force (if force t :false)) #'ignore))

(defun agent-usage--on-submit (&rest _)
  "Have emx catch up on stale quotas when the user works with an agent."
  (unless noninteractive (agent-usage-refresh-quotas)))

(add-hook 'agent-session-submit-functions #'agent-usage--on-submit)

;;; Records

(defun agent-usage-clear ()
  "Delete every usage record, after confirming in the minibuffer.
Quotas are kept.  Deliberately bound to no key."
  (interactive)
  (unless (yes-or-no-p (format "清空全部用量记录（%s）？此操作不能撤销 "
                               (abbreviate-file-name agent-usage-file)))
    (user-error "已取消"))
  (agent-usage--request "clear" (make-hash-table)
                        (lambda (_)
                          (message "已清空用量记录")
                          (run-hooks 'agent-usage-change-functions))))

(defun agent-usage--json-window (window)
  "Rate-limit WINDOW, a plist from a backend, as a JSON object."
  (cl-loop for key in '(:id :label :minutes :used :resets)
           for value = (plist-get window key)
           when value append (list key value)))

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

(defun agent-usage--agent-title (agent host)
  "Display name of AGENT (a string or symbol) running on HOST (nil: here)."
  (let ((agent (if (stringp agent) (intern agent) agent)))
    (concat (or (agent-session--get agent :title) (symbol-name agent))
            (when host (concat "@" host)))))

(defun agent-usage-shown-quotas ()
  "The quotas to show, from the latest push: the duplicates left out."
  (cl-remove-if (lambda (quota) (plist-get quota :duplicate)) agent-usage--snapshot))

;;; Echo area line

(defcustom agent-usage-echo-windows '("5h" "周")
  "Labels of the rate-limit windows shown in the echo area."
  :type '(repeat string))

(defun agent-usage--quota-text (quota)
  "Echo-area text for QUOTA, a pushed quota entry."
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
      (concat (propertize (agent-usage--agent-title (plist-get quota :agent)
                                                    (plist-get quota :host))
                          'face 'bold)
              " " (string-join parts " · ")))))

(defun agent-usage-echo-text ()
  "The quota line shown in the echo area, or nil if nothing is known."
  (when-let* ((parts (delq nil (mapcar #'agent-usage--quota-text (agent-usage-shown-quotas)))))
    (propertize (string-join parts "    ")
                'mouse-face 'highlight
                'keymap (define-keymap "<mouse-1>" #'agent-usage)
                'help-echo "点击查看用量")))

(defconst agent-usage--echo-buffer " *Minibuf-0*"
  "Buffer the echo area shows while there is no message.")

(defvar agent-usage--echo-timer nil
  "Timer redrawing the echo line when the next window resets.")

(defun agent-usage--next-reset ()
  "The earliest time a known window resets, if any is still ahead."
  (let* ((now (float-time))
         (times (cl-loop for quota in agent-usage--snapshot
                         append (cl-loop for window in (plist-get quota :windows)
                                         for resets = (plist-get window :resets)
                                         when (and resets (> resets now)) collect resets))))
    (and times (apply #'min times))))

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
  ;; A window that resets turns into "已重置" on time.
  (when (timerp agent-usage--echo-timer) (cancel-timer agent-usage--echo-timer))
  (setq agent-usage--echo-timer
        (when-let* ((agent-usage-echo-mode)
                    (next (agent-usage--next-reset)))
          (run-at-time (- (+ next 1) (float-time)) nil #'agent-usage-echo-refresh))))

;;;###autoload
(define-minor-mode agent-usage-echo-mode
  "Show what the agents' accounts have left in the echo area while idle.
Starts the usage service, which then polls the quotas."
  :global t
  (if agent-usage-echo-mode
      (progn (add-hook 'agent-usage-change-functions #'agent-usage-echo-refresh)
             (unless noninteractive (agent-usage--service)))
    (remove-hook 'agent-usage-change-functions #'agent-usage-echo-refresh)
    (setq agent-usage--monitoring nil)
    (when (timerp agent-usage--retry-timer) (cancel-timer agent-usage--retry-timer))
    (setq agent-usage--retry-timer nil))
  (agent-usage-echo-refresh))

;;; Usage page
;;
;; Modeled on magpie's usage page (github.com/yetone/magpie): the accounts'
;; allowances first, then the period's headline numbers, its timeline, and
;; the usage split by harness, model and project, each row with its share
;; of the tokens.  A row filters the page to it.  Everything on it comes
;; from one emx report.

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
(defvar-local agent-usage--report nil
  "The emx report the page shows, nil until the first arrives.")
(defvar-local agent-usage--asked 0
  "Number of the latest report asked for: older ones arriving are dropped.")

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

(defun agent-usage--sum-tokens (sum)
  "Tokens of SUM as the page counts them, with or without the cache."
  (plist-get sum :tokens))

;;;; Allowances

(defun agent-usage--forecast-help (forecast)
  "Tooltip explaining FORECAST."
  (concat (format "%s以来每天用 %d%%，照这个速度到重置时会用到 %d%%"
                  (format-time-string "%m-%d %H:%M " (plist-get forecast :since))
                  (round (* 100 (plist-get forecast :rate)))
                  (round (* 100 (plist-get forecast :projected))))
          (if-let* ((exhausts (plist-get forecast :exhausts)))
              (format "，约 %s后用完" (agent-usage--duration (- exhausts (float-time))))
            "")))

(defun agent-usage--insert-window (window)
  "Insert the line of rate-limit WINDOW, with its forecast from emx."
  (let* ((left (agent-usage--window-left window))
         (resets (plist-get window :resets))
         (forecast (and left (plist-get window :forecast)))
         (pace (and forecast (round (* 100 (- (plist-get forecast :projected) 1)))))
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
    (cond
     (pace
      (insert (propertize " · " 'face 'agent-session-dim)
              (propertize (cond ((> pace 2) (format "超速 %d%%" pace))
                                ((< pace -2) (format "有余 %d%%" (- pace)))
                                (t "匀速"))
                          'face (if (> pace 2) 'agent-usage-low 'agent-session-dim)
                          'help-echo (agent-usage--forecast-help forecast))))
     ((and left (plist-get window :wait))
      (insert (propertize " · " 'face 'agent-session-dim)
              (propertize "统计中" 'face 'agent-session-dim
                          'help-echo (format "趋势要看最近一段的读数，约 %s后有结果"
                                             (agent-usage--duration
                                              (plist-get window :wait)))))))
    (insert "\n")))

(defun agent-usage--age (time)
  "How long ago TIME was, as text."
  (let ((seconds (- (float-time) time)))
    (if (< seconds 60) "刚刚" (concat (agent-usage--duration seconds) "前"))))

(defun agent-usage--insert-quotas (quotas)
  "Insert the allowances section for QUOTAS, the report's."
  (insert (propertize "额度" 'face 'agent-usage-heading) "\n")
  (let ((quotas (cl-remove-if (lambda (quota) (plist-get quota :duplicate)) quotas)))
    (if (null quotas)
        (insert (propertize "    还没有额度读数：用一次 Claude、Codex 或 DeepSeek，或等 emx 查一次\n"
                            'face 'agent-session-dim))
      (dolist (quota quotas)
        (insert "  " (propertize (agent-usage--agent-title (plist-get quota :agent)
                                                           (plist-get quota :host))
                                 'face 'bold)
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
                  "\n"))))))

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
  "Insert the headline numbers of TOTAL, the period's sum."
  (let* ((prompt (+ (plist-get total :input) (plist-get total :cache_read)
                    (plist-get total :cache_write)))
         (cache (+ (plist-get total :cache_read) (plist-get total :cache_write))))
    (agent-usage--insert-tiles
     (list (list (agent-usage--count (agent-usage--sum-tokens total))
                 (if agent-usage--without-cache "token（不含缓存）" "token（含缓存）")
                 (if agent-usage--without-cache
                     (format "另有缓存 %s" (agent-usage--count cache))
                   (format "其中缓存 %s" (agent-usage--count cache))))
           (list (agent-usage--count (plist-get total :output)) "输出"
                 (format "输入 %s（不含缓存）" (agent-usage--count (plist-get total :input))))
           (list (agent-usage--count (plist-get total :cache_read)) "缓存读取"
                 (if (> prompt 0)
                     (format "命中率 %d%%" (round (* 100.0 (plist-get total :cache_read)) prompt))
                   ""))
           (list (format "%d" (plist-get total :turns)) "轮次"
                 (if (> (plist-get total :child_turns) 0)
                     (format "子 agent %d 轮" (plist-get total :child_turns))
                   ""))))))

(defun agent-usage--insert-timeline (buckets)
  "Insert the bar chart of BUCKETS, the report's tokens over the period."
  (let* ((start (plist-get buckets :start))
         (step (plist-get buckets :step))
         (count (plist-get buckets :count))
         (sums (plist-get buckets :sums))
         (values (mapcar (lambda (sum) (if sum (agent-usage--sum-tokens sum) 0)) sums))
         (peak (max 1 (apply #'max 0 values)))
         (hourly (< step 86400))
         (height 5)
         (indent 8)
         (cell (max 1 (min 6 (/ (- (agent-usage--width) indent 2) (max 1 count)))))
         (bar (max 1 (1- cell)))
         ;; A label is at most 5 characters and a space.
         (every (max 1 (ceiling 6.0 cell))))
    (insert (propertize (if hourly "按时段" "每日趋势") 'face 'agent-usage-heading) "\n")
    (dotimes (row height)
      ;; The peak's label takes the indentation of the first row: exactly
      ;; as wide, or the tops of the bars would stand askew.
      (insert (if (zerop row)
                  (propertize (format (format "%%%ds " (1- indent)) (agent-usage--count peak))
                              'face 'agent-session-dim)
                (make-string indent ?\s)))
      (cl-loop for value in values
               for sum in sums
               for index from 0
               for eighths = (round (* 8.0 height value) peak)
               for level = (- eighths (* 8 (- height row 1)))
               for char = (cond ((>= level 8) ?█)
                                ((<= level 0) (if (and (= row (1- height)) (zerop value)) ?▁ ?\s))
                                (t (aref "▁▂▃▄▅▆▇" (1- level))))
               do (insert (propertize
                           (concat (make-string bar char) (make-string (- cell bar) ?\s))
                           'face (if (zerop value) 'agent-usage-track 'agent-usage-bar)
                           'help-echo
                           (concat (format-time-string (if hourly "%H:00" "%m-%d")
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
               for label = (format-time-string (if hourly "%H" "%m-%d") (+ start (* index step)))
               for column = (* index cell)
               when (<= (+ column (length label)) (length labels))
               do (store-substring labels column label))
      (insert (propertize labels 'face 'agent-session-dim) "\n"))))

;;;; Groups

(defun agent-usage--insert-group (heading key groups total)
  "Insert section HEADING: GROUPS, the report's sums by KEY, out of TOTAL."
  (let* ((total (max 1 (agent-usage--sum-tokens total)))
         (bar (max 8 (min 20 (- (agent-usage--width) 70))))
         (share-column 30)
         (tokens-column (+ share-column bar 7)))
    (insert (propertize heading 'face 'agent-usage-heading) "\n")
    (dolist (sum groups)
      (let* ((value (plist-get sum :key))
             (tokens (agent-usage--sum-tokens sum))
             (share (/ (float tokens) total))
             (prompt (+ (plist-get sum :input) (plist-get sum :cache_read)
                        (plist-get sum :cache_write)))
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
                                    (if (> (plist-get sum :child_turns) 0)
                                        (format " · 子 agent %d 轮" (plist-get sum :child_turns))
                                      ""))
                            'face 'agent-session-dim)
                (agent-usage--align tokens-column)
                (propertize (concat (format "输入 %s · 输出 %s"
                                            (agent-usage--count (plist-get sum :input))
                                            (agent-usage--count (plist-get sum :output)))
                                    (if (> (plist-get sum :cache_read) 0)
                                        (format " · 缓存 %s · 命中 %d%%"
                                                (agent-usage--count (plist-get sum :cache_read))
                                                (round (* 100.0 (plist-get sum :cache_read)) prompt))
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
  "Draw the usage page in the current buffer from its report.
Point stays on its line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (report agent-usage--report))
    (erase-buffer)
    (agent-usage--insert-header)
    (cond
     ((null report)
      (insert (propertize "加载中…\n" 'face 'agent-session-dim)))
     (t
      (agent-usage--insert-quotas (plist-get report :quotas))
      (insert "\n")
      (let ((total (plist-get report :total))
            (groups (plist-get report :groups)))
        (if (zerop (or (plist-get total :tokens) 0))
            (insert (propertize (format "%s没有用量。从 Emacs 启动的 agent 会话，每一轮都会记在这里。\n"
                                        (if (eq agent-usage--range 'all) "还" "这段时间"))
                                'face 'agent-session-dim))
          (agent-usage--insert-headline total)
          (insert "\n")
          (agent-usage--insert-timeline (plist-get report :buckets))
          (insert "\n")
          (agent-usage--insert-group "Harness" :agent (plist-get groups :agent) total)
          (agent-usage--insert-group "模型" :model (plist-get groups :model) total)
          (agent-usage--insert-group "项目" :root (plist-get groups :root) total)))))
    (insert (propertize (format "只统计从这个 Emacs 启动的会话（含子 agent），按各 agent 报告的用量记录 · %s\n"
                                (abbreviate-file-name agent-usage-file))
                        'face 'agent-session-dim))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun agent-usage--redraw (buffer)
  "Redraw the usage page BUFFER, keeping where its windows show it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((windows (get-buffer-window-list buffer nil t))
             (starts (mapcar #'window-start windows)))
        (agent-usage--render)
        (cl-mapc #'set-window-start windows starts)))))

(defun agent-usage--fetch ()
  "Ask emx for the report of the page in the current buffer.
It is drawn when it arrives, unless a newer one was asked for meanwhile."
  (let ((buffer (current-buffer))
        (asked (cl-incf agent-usage--asked)))
    (agent-usage--request
     "report"
     (list :range (symbol-name agent-usage--range)
           ;; A group of no model filters to records of no model: null.
           :filter (or (cl-loop for (key value) on agent-usage--filter by #'cddr
                                append (list key (or value :null)))
                       (make-hash-table))
           :withoutCache (if agent-usage--without-cache t :false))
     (lambda (report)
       (when (and (buffer-live-p buffer)
                  (= asked (buffer-local-value 'agent-usage--asked buffer)))
         (with-current-buffer buffer (setq agent-usage--report report))
         (agent-usage--redraw buffer))))))

(defvar agent-usage--refetch-timer nil
  "Idle timer asking for a new report after a change.")

(defun agent-usage--schedule-fetch ()
  "Ask for a new report soon if the page is on screen; once for a burst."
  (when-let* ((buffer (get-buffer agent-usage--buffer))
              ((get-buffer-window buffer t))
              ((not (timerp agent-usage--refetch-timer))))
    (setq agent-usage--refetch-timer
          (run-with-idle-timer
           0.5 nil
           (lambda ()
             (setq agent-usage--refetch-timer nil)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer (agent-usage--fetch))))))))

(add-hook 'agent-usage-change-functions #'agent-usage--schedule-fetch)

(defun agent-usage--theme-changed (&rest _)
  "Redraw what blends the theme's colors when it changes."
  (when-let* ((buffer (get-buffer agent-usage--buffer)))
    (agent-usage--redraw buffer)))

;; The partly filled cell of a bar takes the track color as background.
(add-hook 'enable-theme-functions #'agent-usage--theme-changed)

(defun agent-usage-set-range (range)
  "Show the period RANGE, a key of `agent-usage--ranges'."
  (setq agent-usage--range range)
  (agent-usage--render)
  (agent-usage--fetch))

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
  (agent-usage--render)
  (agent-usage--fetch))

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
               (goto-char (point-min))
               (agent-usage--fetch))
      (user-error "这里没有可以筛选的行"))))

(defun agent-usage-unfilter (&optional key)
  "Drop the filter on KEY, or the latest one."
  (interactive)
  (unless agent-usage--filter (user-error "没有筛选"))
  (let ((key (or key (car (last agent-usage--filter 2)))))
    (setq agent-usage--filter (cl-loop for (k v) on agent-usage--filter by #'cddr
                                       unless (eq k key) append (list k v))))
  (agent-usage--render)
  (agent-usage--fetch))

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
  "Have emx poll every quota now, and ask for a new report."
  (interactive)
  (agent-usage-refresh-quotas t)
  (agent-usage--fetch))

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
            (lambda (window) (agent-usage--redraw (window-buffer window))) nil t))

;;;###autoload
(defun agent-usage ()
  "Show the usage page; emx polls the quotas meanwhile."
  (interactive)
  (let ((buffer (get-buffer-create agent-usage--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-usage-mode) (agent-usage-mode))
      (agent-usage--render))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (agent-usage-refresh))))

(provide 'agent-usage)
;;; agent-usage.el ends here
