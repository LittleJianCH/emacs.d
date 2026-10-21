;;; init-reload.el --- Apply edited configuration files without a restart -*- lexical-binding: t; -*-

;;; Commentary:

;; `my/reload-config' reloads configuration files into the running Emacs, for the
;; user (M-x my/reload-config) and for agents (the reload method in agent-ui.el).
;;
;; A plain `load' of a source file defines its functions interpreted, which can
;; be slow enough to freeze Emacs.  It also leaves `defvar', `defvar-keymap',
;; `defcustom' and `defface' alone, and quietly breaks live objects when a
;; `cl-defstruct' layout changes.  Reloading a file here:
;;   - byte-compiles it first, so its functions run compiled; a file that does
;;     not compile is not loaded at all, and compiler warnings are reported;
;;   - merges its keymap definitions into the live keymaps: bindings added by
;;     other code are kept, bindings the source dropped since the previous
;;     reload are removed;
;;   - moves options nobody customized or set to their new default;
;;   - applies changed `defface' specs;
;;   - refuses to load a file whose struct layout changed, and reports that
;;     Emacs needs a restart instead.
;; Other `defvar's hold state and keep their values.
;;
;; Without arguments it reloads every file under lisp/ changed on disk since it
;; was last loaded, in dependency order.  Files that depend on a changed file
;; are not reloaded with it: functions are looked up at call time, but code
;; expanding a changed macro needs its own file reloaded.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; bytecomp is loaded when the first file is reloaded.
(defvar byte-compile-current-buffer)
(defvar byte-compile-dest-file-function)
(defvar byte-compile-dynamic-docstrings)
(defvar byte-compile-log-warning-function)
(defvar byte-compile-verbose)

(defvar my/reload-directory (locate-user-emacs-file "lisp/")
  "Directory whose loaded files `my/reload-config' checks for changes.")

(defvar my/reload--times (make-hash-table :test #'equal)
  "Map from a configuration file to the time it was last loaded.
Files loaded before this module count as loaded at `before-init-time'.")

(defvar my/reload--keymaps (make-hash-table :test #'eq)
  "Map from a keymap variable to a copy of the keymap its source built last.
Bindings in it that a later version of the source drops are removed.")

;;; Which files, in which order

(defun my/reload--loaded ()
  "Return (FILE . HISTORY) for loaded source files under `my/reload-directory'.
HISTORY is the file's `load-history' entry list; oldest file first."
  (let ((dir (file-truename my/reload-directory))
        loaded)
    (pcase-dolist (`(,file . ,history) load-history)
      (when (and (stringp file) (string-suffix-p ".el" file)
                 (string-prefix-p dir (file-truename file)))
        (push (cons (file-truename file) history) loaded)))
    (seq-uniq loaded (lambda (a b) (equal (car a) (car b))))))

(defun my/reload--note-load (file)
  "Remember when FILE was loaded, however it was, if it is a configuration file."
  (let ((file (file-truename file)))
    (when (string-prefix-p (file-truename my/reload-directory) file)
      (puthash file (current-time) my/reload--times))))

(add-hook 'after-load-functions #'my/reload--note-load)

(defun my/reload--changed-p (file)
  "Non-nil if FILE changed on disk since it was last loaded."
  (time-less-p (or (gethash file my/reload--times) before-init-time)
               (file-attribute-modification-time (file-attributes file))))

(defun my/reload--order (files loaded)
  "Return FILES sorted so each comes after the files whose features it requires.
LOADED is the value of `my/reload--loaded'.  A reloaded file moves to the
front of `load-history', so the history order alone is not enough."
  (let ((provider (make-hash-table))
        done result)
    (pcase-dolist (`(,file . ,history) loaded)
      (dolist (item history)
        (when (eq (car-safe item) 'provide)
          (puthash (cdr item) file provider))))
    (cl-labels ((visit (file)
                  (unless (member file done)
                    (push file done)
                    (dolist (item (cdr (assoc file loaded)))
                      (when-let* (((eq (car-safe item) 'require))
                                  (dep (gethash (cdr item) provider))
                                  ((member dep files)))
                        (visit dep)))
                    (push file result))))
      (mapc #'visit files))
    (nreverse result)))

;;; What a file defines

(defun my/reload--forms (file)
  "Return the top-level forms of FILE.
The bodies of `progn' and `with-eval-after-load' count as top level."
  (let (forms)
    (cl-labels ((walk (form)
                  (pcase form
                    (`(progn . ,body) (mapc #'walk body))
                    (`(with-eval-after-load ,_ . ,body) (mapc #'walk body))
                    (_ (push form forms)))))
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (while t (walk (read (current-buffer))))
          (end-of-file nil))))
    (nreverse forms)))

(defun my/reload--keymap-var (form)
  "Return the variable FORM defines if it is a live keymap variable."
  (pcase form
    ((or `(defvar-keymap ,var . ,_) `(defvar ,var ,_ . ,_))
     (and (symbolp var) (default-boundp var)
          (keymapp (default-value var)) (not (symbolp (default-value var)))
          var))))

(defun my/reload--struct-change (form)
  "Compare the struct FORM defines with its live definition.
Return nil if the struct is new or keeps its slots, `appended' if FORM only
adds slots at the end, and `changed' otherwise."
  (pcase form
    (`(cl-defstruct ,spec . ,body)
     (let* ((name (if (consp spec) (car spec) spec))
            (include (and (consp spec)
                          (cadr (seq-find (lambda (option)
                                            (eq (car-safe option) :include))
                                          (cdr spec)))))
            (slot-names (lambda (struct)
                          (remq 'cl-tag-slot
                                (mapcar #'car (ignore-errors
                                                (cl-struct-slot-info struct))))))
            (live (funcall slot-names name))
            (new (append (and include (funcall slot-names include))
                         (mapcar (lambda (slot) (if (consp slot) (car slot) slot))
                                 (seq-remove #'stringp body)))))
       (cond ((or (null live) (equal live new)) nil)
             ((equal live (take (length live) new)) 'appended)
             (t 'changed))))))

;;; Applying definitions the reload skipped

(defun my/reload--events (keymap)
  "Return KEYMAP's own bindings as (EVENT . DEFINITION), without its parent's."
  (let (events)
    (map-keymap-internal (lambda (event definition)
                           (unless (consp event) ; char ranges of full keymaps
                             (push (cons event definition) events)))
                         keymap)
    events))

(defun my/reload--merge-keymap (live fresh previous)
  "Make keymap LIVE bind what FRESH binds, keeping bindings added elsewhere.
Bindings of PREVIOUS, the keymap the source built last time, that FRESH no
longer has are removed.  Prefix keymaps defined inline are merged the same way.
Return non-nil if LIVE changed."
  (let ((new (my/reload--events fresh))
        (own (my/reload--events live))
        (old (and previous (my/reload--events previous)))
        changed)
    (pcase-dolist (`(,event . ,_) old)
      (when (and (not (assq event new)) (assq event own))
        (define-key live (vector event) nil t)
        (setq changed t)))
    (pcase-dolist (`(,event . ,definition) new)
      (let ((current (cdr (assq event own))))
        (cond ((and (keymapp definition) (not (symbolp definition))
                    (keymapp current) (not (symbolp current))
                    (not (eq definition current)))
               (when (my/reload--merge-keymap current definition
                                              (cdr (assq event old)))
                 (setq changed t)))
              ((not (equal definition current))
               (define-key live (vector event) definition)
               (setq changed t)))))
    ;; A derived mode sets its map's parent itself; only take a declared one.
    (when-let* ((parent (keymap-parent fresh))
                ((not (eq parent (keymap-parent live)))))
      (set-keymap-parent live parent)
      (setq changed t))
    changed))

(defun my/reload--keymap (var form)
  "Evaluate FORM, which defines keymap VAR, and merge it into the live keymap.
Return non-nil if the live keymap changed."
  (require 'bytecomp)                   ; before let-binding its variables
  (let ((live (default-value var))
        fresh)
    ;; `defvar' only assigns an unbound variable.
    (makunbound var)
    (unwind-protect
        ;; Compiled, so commands defined inline are compiled like the file;
        ;; `byte-compile' would follow the current buffer's `lexical-binding'.
        (progn (eval (let ((lexical-binding t)
                           (byte-compile-log-warning-function #'ignore))
                       (byte-compile form))
                     t)
               (setq fresh (default-value var)))
      (set-default var live))
    (prog1 (my/reload--merge-keymap live fresh (gethash var my/reload--keymaps))
      (puthash var (copy-keymap fresh) my/reload--keymaps))))

(defun my/reload--standard-value (symbol)
  "Return the evaluated default of option SYMBOL, or `my/reload--none'."
  (condition-case nil
      (eval (car (get symbol 'standard-value)) t)
    (error 'my/reload--none)))

(defun my/reload--untouched-options (forms)
  "Return the options defined in FORMS whose value is still their default."
  (seq-keep (lambda (form)
              (pcase form
                (`(defcustom ,symbol . ,_)
                 (and (default-boundp symbol)
                      (not (or (get symbol 'saved-value)
                               (get symbol 'customized-value)
                               (get symbol 'theme-value)))
                      (equal (default-value symbol)
                             (my/reload--standard-value symbol))
                      symbol))))
            forms))

(defun my/reload--update-options (symbols)
  "Set each option in SYMBOLS to its new default; return the changed ones."
  (seq-filter (lambda (symbol)
                (let ((value (my/reload--standard-value symbol)))
                  (unless (or (eq value 'my/reload--none)
                              (equal value (default-value symbol)))
                    (funcall (or (get symbol 'custom-set) #'set-default) symbol value)
                    t)))
              symbols))

(defun my/reload--update-faces (forms)
  "Apply the changed `defface' specs among FORMS; return the changed faces."
  (seq-keep (lambda (form)
              (pcase form
                (`(defface ,face ,spec . ,_)
                 (let ((spec (eval spec t)))
                   (unless (equal spec (get face 'face-defface-spec))
                     (face-spec-set face spec 'face-defface-spec)
                     face)))))
            forms))

;;; Compiling

(defun my/reload--compile (file)
  "Byte-compile FILE and return (CODE . WARNINGS).
CODE is the text of the compiled file, WARNINGS the compiler's warnings.
Return nil if FILE sets `no-byte-compile'; signal an error if it does not
compile."
  (require 'bytecomp)                   ; before let-binding its variables
  (let* ((dir (make-temp-file "my-reload-" t))
         ;; A copy, since `byte-compile-file' offers to save a modified
         ;; buffer visiting the file it compiles.
         (copy (expand-file-name (file-name-nondirectory file) dir))
         (byte-compile-dest-file-function (lambda (source) (concat source "c")))
         ;; Keep docstrings in the code instead of pointing into the copy.
         (byte-compile-dynamic-docstrings nil)
         (byte-compile-verbose nil)
         (inhibit-message t)
         (message-log-max nil)
         warnings errors
         ;; Collect problems instead of popping up *Compile-Log*.  An error
         ;; has unwound past its form; the reader stopped after it.
         (byte-compile-log-warning-function
          (lambda (string position _fill level)
            (let* ((line (ignore-errors
                           (with-current-buffer byte-compile-current-buffer
                             (line-number-at-pos
                              (if (eq level :error) (point) position)))))
                   (problem (if line (format "line %d: %s" line string) string)))
              (if (eq level :error)
                  (push problem errors)
                (push problem warnings))))))
    (unwind-protect
        (progn
          (copy-file file copy)
          (pcase (byte-compile-file copy)
            ('no-byte-compile nil)
            ('nil (error "Does not compile, not loaded: %s"
                         (if errors (string-join (nreverse errors) "; ") "?")))
            (_ (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8-emacs-unix))
                   (insert-file-contents (concat copy "c")))
                 (cons (buffer-string) (nreverse warnings))))))
      (delete-directory dir t))))

(defun my/reload--load-compiled (file code)
  "Evaluate CODE, compiled from FILE, the way `load' evaluates FILE."
  (with-temp-buffer
    ;; Compiled forms don't depend on it; `load' binds nil for .elc files, and
    ;; without a cookie `eval-buffer' warns.
    (insert ";; -*- lexical-binding: nil -*-\n" code)
    ;; As FILE: in `load-history' and for code using `load-file-name'.  A
    ;; .elc name would also make native-comp queue a compilation of it.
    (let ((load-file-name file)
          (load-true-file-name file)
          (load-in-progress t))
      (eval-buffer (current-buffer) nil file nil t)))
  ;; Runs `after-load-functions', which note the time FILE was loaded.
  (do-after-load-evaluation file))

;;; Reloading

(defun my/reload--file (file)
  "Reload FILE and return a report plist."
  (let* ((forms (my/reload--forms file))
         (structs (seq-keep (lambda (form)
                              (when-let* ((change (my/reload--struct-change form)))
                                (cons (cadr form) change)))
                            forms))
         (changed (seq-filter (lambda (struct) (eq (cdr struct) 'changed)) structs)))
    (if changed
        (list :status 'restart_required
              :error (format "struct layout changed: %s; live objects would break"
                             (mapconcat (lambda (struct) (format "%S" (car struct)))
                                        changed ", ")))
      ;; Look before loading: keymaps defined for the first time need no merge.
      ;; Compiling also comes after the struct check: the compiler defines
      ;; structs as it goes.
      (let* ((options (my/reload--untouched-options forms))
             (keymaps (seq-keep (lambda (form)
                                  (when-let* ((var (my/reload--keymap-var form)))
                                    (cons var form)))
                                forms))
             (compiled (my/reload--compile file)))
        (if compiled
            (my/reload--load-compiled file (car compiled))
          (load file nil t t))
        (list :status 'reloaded
              :keymaps (seq-keep (pcase-lambda (`(,var . ,form))
                                   (and (my/reload--keymap var form) var))
                                 keymaps)
              :options (my/reload--update-options options)
              :faces (my/reload--update-faces forms)
              :warnings (append
                         (mapcar (lambda (struct)
                                   (format "%S gained slots at the end; objects \
made before this reload lack them" (car struct)))
                                 structs)
                         (cdr compiled)))))))

(defvar my/reload-emx-function nil
  "Function returning daemon reload reports, installed by agent-emx.")

(defun my/reload-config (&optional files)
  "Reload FILES, by default every configuration file changed on disk.
FILES are file names, relative ones against `user-emacs-directory'.  Return a
list of plists (:file :status ...), where :status is `reloaded', `failed' or
`restart_required', plus an optional (:emx VECTOR) daemon report entry.
Interactively, report the outcome in the echo area."
  (interactive)
  (let* ((loaded (my/reload--loaded))
         (files (if files
                    (mapcar (lambda (file)
                              (file-truename (expand-file-name file user-emacs-directory)))
                            files)
                  (seq-filter #'my/reload--changed-p (mapcar #'car loaded))))
         (report
          (mapcar (lambda (file)
                    (cons :file
                          (cons file
                                (condition-case err
                                    (if (file-exists-p file)
                                        (my/reload--file file)
                                      (error "No such file"))
                                  (error (list :status 'failed
                                               :error (error-message-string err)))))))
                  (my/reload--order files loaded))))
    ;; init.el and early-init.el run once at startup; reloading them would redo it.
    (unless files
      (dolist (file (list user-init-file early-init-file))
        (when (and file (file-exists-p file) (my/reload--changed-p file))
          (setq report (append report
                               (list (list :file file :status 'restart_required
                                           :error "init files only run at startup")))))))
    (when my/reload-emx-function
      (when-let* ((emx (funcall my/reload-emx-function)))
        (setq report (append report (list (list :emx (vconcat emx)))))))
    (when (called-interactively-p 'any)
      (message "%s" (my/reload--summary report)))
    report))

(defun my/reload--summary (report)
  "Describe REPORT from `my/reload-config' for the echo area."
  (if (null report)
      "没有改动过的配置文件"
    (let ((by-status (seq-group-by (lambda (entry) (plist-get entry :status)) report))
          (names (lambda (entries)
                   (mapconcat (lambda (entry) (file-name-nondirectory (plist-get entry :file)))
                              entries "、"))))
      (string-join
       (delq nil
             (list (when-let* ((done (alist-get 'reloaded by-status)))
                     (format "已重载 %s" (funcall names done)))
                   (when-let* ((failed (alist-get 'failed by-status)))
                     (format "加载失败 %s（%s）" (funcall names failed)
                             (plist-get (car failed) :error)))
                   (when-let* ((restart (alist-get 'restart_required by-status)))
                     (format "需要重启 Emacs 才能生效：%s" (funcall names restart)))
                   (when-let* ((emx (seq-find (lambda (e) (plist-member e :emx)) report)))
                     (format "emx：%s"
                             (mapconcat
                              (lambda (entry)
                                (pcase (plist-get entry :status)
                                  ("restarted" "已重启")
                                  ("restart_scheduled" "会话空闲后重启")
                                  ("up_to_date" "已是最新")
                                  (_ "更新失败")))
                              (plist-get emx :emx) "、")))))
       "；"))))

(provide 'init-reload)
;;; init-reload.el ends here
