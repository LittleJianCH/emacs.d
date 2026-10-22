;;; init-lazy.el --- Load optional modules on first use -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional modules (lisp/lang/lang-NAME.el, lisp/app/init-NAME.el) install
;; their packages with `:ensure t' as soon as they are evaluated.  Requiring
;; them only when they are first needed keeps a machine that never opens an
;; Agda file, or never runs telega, free of those packages.
;;
;; `my/lazy-modules' declares what triggers each module.  `my/lazy-require'
;; installs the triggers:
;;
;; - File rules, (REGEXP . MODE) pairs, join `auto-mode-alist' at once, in
;;   front of the built-in rules, and stay there.  They equal the rules the
;;   module registers itself (a test compares them), so code that reads the
;;   alist, such as the review and canvas highlighting, finds real mode
;;   symbols before the module is loaded.
;; - Commands, mode functions included, are stubs that load the module and
;;   then run the real definition with the same arguments.  Visiting a
;;   file, `M-x nix-mode' and a `mode: nix' cookie all end up in one.
;; - Modes that may already be defined load the module after the selected
;;   mode's body, before its hooks run.  Setup hooks added by the module
;;   therefore run during that same activation, without replacing the mode.
;; - A global key runs a command that loads the module and types the key
;;   again, so the module's binding takes over.
;;
;; The first trigger loads the module and removes all of its triggers.
;; A module that fails to load loses its triggers too, so a broken or offline
;; module is reported once and never retried in a loop; retry it with
;; `M-x my/lazy-load'.  A quit puts the triggers back.
;;
;; A stub replaces only an unbound or autoloaded function.  A direct
;; `(require 'lang-nix)' while nix-mode is not installed removes the stub
;; and leaves `nix-mode' unbound until the package activates.  Table edits
;; take effect after a restart, or by calling `my/lazy-require' again.
;;
;; Keep the file rules in sync with the modules; a test compares them.
;; Other session state, such as `my/cargo' or the eglot server entries,
;; exists only after the first trigger.

;;; Code:

(require 'cl-lib)

(defconst my/lazy-modules
  '((lang-rust :files (("\\.rs\\'" . rust-ts-mode)
                       ("Cargo\\.lock\\'" . toml-ts-mode))
               ;; Not toml-ts-mode: lang-rust adds nothing to it, and a stub
               ;; would load the module for every .toml file.
               :commands (rust-ts-mode))
    (lang-go :files (("\\.go\\'" . go-ts-mode)
                     ("/go\\.mod\\'" . go-mod-ts-mode)
                     ("/go\\.work\\'" . go-work-ts-mode))
             :commands (go-ts-mode go-mod-ts-mode go-work-ts-mode))
    (lang-nix :files (("\\.nix\\'" . nix-mode))
              :commands (nix-mode))
    (lang-c :files (("\\.c\\'" . my/c-mode)
                    ("\\.\\(?:cc\\|cpp\\|cxx\\|c\\+\\+\\|C\\|hh\\|hpp\\|hxx\\|h\\+\\+\\|H\\|ipp\\|inl\\|tpp\\|ixx\\|cppm\\)\\'"
                     . my/c++-mode)
                    ("\\.h\\'" . my/c-or-c++-mode))
            :commands (my/c-mode my/c++-mode my/c-or-c++-mode)
            :modes (c-mode c++-mode c-ts-mode c++-ts-mode))
    ;; The pattern is `my/agda-file-pattern', which needs lang-agda loaded.
    (lang-agda :files (("\\.\\(?:agda\\|lagda\\(?:\\.\\(?:md\\|rst\\|tex\\|org\\|typ\\|tree\\)\\)?\\)\\'"
                        . my/agda-mode))
               :commands (my/agda-mode))
    ;; telega-server-build must see `telega-server-libs-prefix'.
    (init-telega :keys ("C-c T") :commands (telega telega-server-build)))
  "Alist of lazily loaded features and the triggers that load them.
Each value is a plist with any of these keys:
  :files     (REGEXP . MODE) rules for `auto-mode-alist', the ones the
             module registers; they are added at once and never removed
  :keys      global key strings for `keymap-global-set', which may be
             prefix keys that the module binds to a keymap itself
  :commands  interactive commands, to run once the module has loaded;
             list the MODEs of :files here, or the files load nothing
  :modes     major mode symbols that load the module after their bodies,
             before mode hooks; also works for modes already defined
A feature without an entry is required at once by `my/lazy-require'.")

(defvar my/lazy--triggers nil
  "Alist of features and the triggers currently installed for them.
Each trigger is one of
  (key KEY STUB OLD)   STUB bound to KEY, replacing binding OLD
  (command COMMAND STUB OLD DOC)
                       STUB as function of COMMAND, replacing OLD, with
                       DOC as its `function-documentation'
  (mode CALLBACK)      CALLBACK on `change-major-mode-after-body-hook'
Kept across reloads of this file, so no trigger is installed twice.")

(defun my/lazy--remove-triggers (feature)
  "Remove every trigger for FEATURE and restore what its stubs replaced.
Only stubs that are still in place are touched: a binding or definition
the module made itself stays."
  (let ((record (assq feature my/lazy--triggers)))
    ;; Forget the record first, so nothing below can come back here.
    (setq my/lazy--triggers (delq record my/lazy--triggers))
    (dolist (trigger (cdr record))
      (pcase trigger
        (`(mode ,callback)
         (remove-hook 'change-major-mode-after-body-hook callback))
        (`(key ,key ,stub ,old)
         (when (eq (lookup-key (current-global-map) (key-parse key)) stub)
           (if old
               (keymap-global-set key old)
             (keymap-global-unset key t))))
        (`(command ,command ,stub ,old ,doc)
         (when (eq (get command 'function-documentation) doc)
           (cl-remf (symbol-plist command) 'function-documentation))
         (when (eq (symbol-function command) stub)
           (if old
               (fset command old)
             (fmakunbound command))))))))

(defun my/lazy-load (feature)
  "Load FEATURE, a module of `my/lazy-modules'; return non-nil if it worked.
Interactively, choose among the modules that are not loaded yet.  This
is the way to retry a load that failed, say because Emacs was offline.
Remove FEATURE's triggers first: a package's own autoloads must not find
the stub of its command in the way, and no failure can leave a trigger.
An error is reported and not retried.  A quit, say during the first
download, puts the triggers back and quits on."
  (interactive
   (let ((pending (cl-loop for (module . _) in my/lazy-modules
                           unless (featurep module)
                           collect (symbol-name module))))
     (unless pending (user-error "没有待加载的模块"))
     (list (intern (completing-read "加载模块：" pending nil t)))))
  (my/lazy--remove-triggers feature)
  (message "正在加载 %s…" feature)
  (condition-case err
      (progn (require feature) t)
    (quit
     (my/lazy-require feature)
     (signal 'quit nil))
    (error
     (message "加载 %s 失败：%s（可用 M-x my/lazy-load 重试）"
              feature (error-message-string err))
     nil)))

(defun my/lazy--key-stub (feature key)
  "Return the command that loads FEATURE for the global key KEY.
It then types KEY again, as `use-package' does for `:bind-keymap', so the
module's binding (a keymap, for a prefix key) takes over."
  (lambda ()
    (interactive)
    (my/lazy-load feature)
    (let* ((keys (key-parse key))
           (binding (lookup-key (current-global-map) keys)))
      ;; A key the module left unbound has nothing to replay.
      (when (or (commandp binding) (keymapp binding))
        (setq prefix-arg current-prefix-arg
              unread-command-events
              (append (mapcar (lambda (event) (cons t event))
                              (listify-key-sequence keys))
                      unread-command-events))))))

(defun my/lazy--command-stub (feature command)
  "Return the function that loads FEATURE and then runs COMMAND.
The stub is gone by then, and so is any definition that was in the way."
  (let (stub)
    (setq stub
          (lambda (&rest args)
            (interactive)
            (let ((interactively (called-interactively-p 'any)))
              (unless (and (my/lazy-load feature)
                           (fboundp command)
                           (not (eq (symbol-function command) stub)))
                (user-error "无法运行 %s：%s 加载失败，或没有定义它"
                            command feature))
              (if interactively
                  (call-interactively command)
                (apply command args)))))
    stub))

(defun my/lazy--install (feature spec)
  "Install the triggers for FEATURE described by the plist SPEC."
  (let ((record (list feature)))
    (push record my/lazy--triggers)
    ;; In front, so the rules win over built-in ones for the same files.
    ;; A rule that is there already moves instead of appearing twice.
    (dolist (rule (reverse (plist-get spec :files)))
      (setq auto-mode-alist (cons rule (delete rule auto-mode-alist))))
    (when-let* ((modes (plist-get spec :modes)))
      (let ((callback (lambda ()
                        (when (memq major-mode modes)
                          (my/lazy-load feature)))))
        (add-hook 'change-major-mode-after-body-hook callback)
        (push (list 'mode callback) (cdr record))))
    (dolist (key (plist-get spec :keys))
      (let ((stub (my/lazy--key-stub feature key))
            (old (lookup-key (current-global-map) (key-parse key))))
        (keymap-global-set key stub)
        (push (list 'key key stub (and (or (commandp old) (keymapp old)) old))
              (cdr record))))
    (dolist (command (plist-get spec :commands))
      (let ((old (and (fboundp command) (symbol-function command))))
        ;; A real definition cannot be replaced by an autoload either; the
        ;; stub would shadow the user's own function.
        (when (or (null old) (autoloadp old))
          (let ((stub (my/lazy--command-stub feature command))
                (doc (format "首次调用时先加载 %s，再运行 %s。"
                             feature command)))
            ;; A mode takes no arguments.  Say so, or compiling the module's
            ;; own `defun' while the stub exists warns that the function
            ;; "used to take 0 or more arguments".
            (when (rassq command (plist-get spec :files))
              (set-advertised-calling-convention stub nil "31"))
            (fset command stub)
            (put command 'function-documentation doc)
            (push (list 'command command stub old doc) (cdr record))))))
    ;; A plain `require' of the module, as tests do, leaves no stubs.  The
    ;; quoted form compares `equal', so reloading adds no second entry.
    (eval-after-load feature `(my/lazy--remove-triggers ',feature))))

(defun my/lazy-require (feature)
  "Require FEATURE now, or on first use of one of its triggers.
Triggers are declared in `my/lazy-modules'.  A feature that has none,
or is loaded already, is required now.  Calling this again replaces the
triggers of an earlier call."
  (let ((spec (cdr (assq feature my/lazy-modules))))
    (my/lazy--remove-triggers feature)
    (if (or (featurep feature)
            (not (or (plist-get spec :files)
                     (plist-get spec :keys)
                     (plist-get spec :modes)
                     (plist-get spec :commands))))
        (require feature)
      (my/lazy--install feature spec))))

(provide 'init-lazy)
;;; init-lazy.el ends here
