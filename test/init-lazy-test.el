;;; init-lazy-test.el --- Lazy module loading tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise the triggers with fake modules in a temporary directory, then
;; check the real table against the real modules.  Tests of a real module
;; need its packages installed, and skip otherwise; nothing is ever installed.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'package)
(require 'init-lazy)

;; `features' is not declared special for the byte compiler.
(defvar features)
(defvar package-archive-contents)
(defvar personal-keybindings)
(defvar custom-known-themes)
(defvar custom-enabled-themes)
(defvar nix-mode-hook)
(defvar agent-canvas--page)
(defvar telega-directory)
(defvar telega-server-libs-prefix)
(declare-function agent-canvas--buffer "agent-canvas")
(declare-function agent-canvas--load-sources "agent-canvas")
(declare-function agent-canvas--redraw "agent-canvas")
(declare-function agent-review--file-mode "agent-review")

(defvar init-lazy-test-loads 0 "Times a fake module body started.")
(defvar init-lazy-test-configured nil "Set by a fake module when it loads.")
(defvar init-lazy-test-result nil "What the fake package command saw.")

(defconst init-lazy-test--key "C-c Q"
  "Global key the fake modules use; it is restored after each test.")

(defconst init-lazy-test--functions
  '(init-lazy-test-foo-mode init-lazy-test-key-command init-lazy-test-cmd)
  "Functions the fake modules define; made void again after each test.")

(defun init-lazy-test--module (feature &rest forms)
  "Return (FEATURE . SOURCE) of a fake module that evaluates FORMS."
  (cons feature
        (concat ";;; -*- lexical-binding: t; -*-\n"
                (mapconcat #'prin1-to-string forms "\n")
                (format "\n(provide '%s)\n" feature))))

(defun init-lazy-test--global-key (key)
  "Return the global binding of KEY, or nil."
  (let ((binding (lookup-key (current-global-map) (key-parse key))))
    (and (not (integerp binding)) binding)))

(defun init-lazy-test--restore-key (key binding)
  "Bind the global KEY to BINDING again; unbind it if BINDING is nil."
  (if binding
      (keymap-global-set key binding)
    (keymap-global-unset key t)))

(defmacro init-lazy-test--with-env (modules &rest body)
  "Run BODY with the fake MODULES, an alist of (FEATURE . SOURCE), loadable.
Everything the modules and triggers touch is restored afterwards."
  (declare (indent 1))
  `(let* ((init-lazy-test--dir (make-temp-file "init-lazy-test-" t))
          (load-path (cons init-lazy-test--dir load-path))
          (features (copy-sequence features))
          (load-history load-history)
          (after-load-alist (copy-tree after-load-alist))
          (auto-mode-alist (copy-sequence auto-mode-alist))
          (unread-command-events nil)
          (my/lazy--triggers nil)
          (init-lazy-test-loads 0)
          (init-lazy-test-configured nil)
          (init-lazy-test-result nil)
          (saved-key (init-lazy-test--global-key init-lazy-test--key))
          (saved-functions (mapcar (lambda (function)
                                     (and (fboundp function)
                                          (symbol-function function)))
                                   init-lazy-test--functions)))
     (unwind-protect
         (cl-letf (((symbol-function 'package-install)
                    (lambda (&rest _) (ert-fail "Tests must not install")))
                   ((symbol-function 'package-refresh-contents)
                    (lambda (&rest _) (ert-fail "Tests must not refresh"))))
           (dolist (module ,modules)
             (with-temp-file (expand-file-name (format "%s.el" (car module))
                                               init-lazy-test--dir)
               (insert (cdr module))))
           ,@body)
       (cl-mapc (lambda (function definition)
                  (if definition
                      (fset function definition)
                    (fmakunbound function))
                  (cl-remf (symbol-plist function) 'function-documentation))
                init-lazy-test--functions saved-functions)
       (init-lazy-test--restore-key init-lazy-test--key saved-key)
       (delete-directory init-lazy-test--dir t))))

(defun init-lazy-test--messages (thunk)
  "Call THUNK and return the messages it printed."
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (when format-string
                   (push (apply #'format format-string args) messages)))))
      (funcall thunk))
    (nreverse messages)))

(defun init-lazy-test--visit (file)
  "Return the major mode `set-auto-mode' chooses for a buffer visiting FILE."
  (with-temp-buffer
    (setq buffer-file-name file)
    (set-auto-mode)
    major-mode))

(defun init-lazy-test--rule-mode (file)
  "Return what `auto-mode-alist' says about FILE, as code reading it sees it."
  (assoc-default file auto-mode-alist #'string-match))

(defconst init-lazy-test--foo-forms
  '((setq init-lazy-test-loads (1+ init-lazy-test-loads))
    (defun init-lazy-test-foo-mode ()
      (prog-mode)
      (setq major-mode 'init-lazy-test-foo-mode))
    (add-to-list 'auto-mode-alist '("\\.foo\\'" . init-lazy-test-foo-mode)))
  "Forms of a fake language module with a file rule and a simple mode.")

(defconst init-lazy-test--rule '("\\.foo\\'" . init-lazy-test-foo-mode)
  "The file rule of the fake language module.")

(defconst init-lazy-test--table
  '((init-lazy-test-files :files (("\\.foo\\'" . init-lazy-test-foo-mode))
                          :commands (init-lazy-test-foo-mode)))
  "Triggers of the fake language module.")

(defun init-lazy-test--files-module ()
  "Return the fake language module."
  (apply #'init-lazy-test--module 'init-lazy-test-files
         init-lazy-test--foo-forms))

;;; Files

(ert-deftest init-lazy-files-are-real-rules-from-the-start ()
  "The rule names the mode itself, ahead of built-in rules, before any load."
  (init-lazy-test--with-env (list (init-lazy-test--files-module))
    (let ((my/lazy-modules init-lazy-test--table))
      (push '("\\.foo\\'" . text-mode) auto-mode-alist)
      (my/lazy-require 'init-lazy-test-files)
      (should-not (featurep 'init-lazy-test-files))
      (should (equal (car auto-mode-alist) init-lazy-test--rule))
      (should (eq (init-lazy-test--rule-mode "/tmp/x.foo")
                  'init-lazy-test-foo-mode))
      (should (functionp 'init-lazy-test-foo-mode))
      (should (= init-lazy-test-loads 0)))))

(ert-deftest init-lazy-files-mode-function-loads-the-module ()
  "Calling the mode, as highlighting code does, loads the module."
  (init-lazy-test--with-env (list (init-lazy-test--files-module))
    (let ((my/lazy-modules init-lazy-test--table))
      (my/lazy-require 'init-lazy-test-files)
      (let ((mode (init-lazy-test--rule-mode "/tmp/x.foo")))
        (with-temp-buffer
          (funcall mode)
          (should (eq major-mode 'init-lazy-test-foo-mode))))
      (should (featurep 'init-lazy-test-files))
      (should-not my/lazy--triggers)
      (should (= init-lazy-test-loads 1)))))

(ert-deftest init-lazy-files-load-on-first-visit ()
  "The first visit loads the module; the rule stays where it was."
  (init-lazy-test--with-env (list (init-lazy-test--files-module))
    (let ((my/lazy-modules init-lazy-test--table))
      (push '("\\.foo\\'" . text-mode) auto-mode-alist)
      (my/lazy-require 'init-lazy-test-files)
      (should (eq (init-lazy-test--visit "/tmp/x.foo")
                  'init-lazy-test-foo-mode))
      (should (featurep 'init-lazy-test-files))
      (should-not my/lazy--triggers)
      (should (equal (car auto-mode-alist) init-lazy-test--rule))
      (should (= (cl-count init-lazy-test--rule auto-mode-alist
                           :test #'equal)
                 1))
      ;; Nothing loads twice.
      (should (eq (init-lazy-test--visit "/tmp/y.foo")
                  'init-lazy-test-foo-mode))
      (should (= init-lazy-test-loads 1)))))

(ert-deftest init-lazy-files-mode-cookie-loads-the-module ()
  "A `mode:' cookie, like `M-x' on the mode, finds the stub and loads."
  (init-lazy-test--with-env (list (init-lazy-test--files-module))
    (let ((my/lazy-modules init-lazy-test--table))
      (my/lazy-require 'init-lazy-test-files)
      (with-temp-buffer
        (insert "# -*- mode: init-lazy-test-foo -*-\n")
        (setq buffer-file-name "/tmp/cookie.txt")
        (set-auto-mode)
        (should (eq major-mode 'init-lazy-test-foo-mode)))
      (should (featurep 'init-lazy-test-files)))))

(ert-deftest init-lazy-files-keep-suffix-handling ()
  "Backup versions and compression suffixes still find the module's mode."
  (dolist (file '("/tmp/x.foo~" "/tmp/x.foo.~1~" "/tmp/x.foo.gz"
                  "/tmp/x.foo.gz~"))
    (init-lazy-test--with-env (list (init-lazy-test--files-module))
      (let ((my/lazy-modules init-lazy-test--table))
        (push '("\\.gz\\'" nil t) auto-mode-alist)
        (my/lazy-require 'init-lazy-test-files)
        (should (eq (init-lazy-test--visit file) 'init-lazy-test-foo-mode))
        (should (featurep 'init-lazy-test-files))
        (should-not my/lazy--triggers)))))

(ert-deftest init-lazy-files-load-error-reports-once-and-retries ()
  "A failing module reports once, keeps its rule, and `my/lazy-load' retries."
  (init-lazy-test--with-env
      (list (init-lazy-test--module
             'init-lazy-test-files
             '(setq init-lazy-test-loads (1+ init-lazy-test-loads))
             '(error "Offline test module")))
    (let ((my/lazy-modules init-lazy-test--table))
      (my/lazy-require 'init-lazy-test-files)
      (let ((messages (init-lazy-test--messages
                       (lambda ()
                         (should-error (init-lazy-test--visit "/tmp/x.foo")
                                       :type 'user-error)))))
        (should (string-match-p "加载 init-lazy-test-files 失败"
                                (cadr messages)))
        (should (string-match-p "Offline test module" (cadr messages)))
        (should (string-match-p "M-x my/lazy-load" (cadr messages))))
      (should-not (featurep 'init-lazy-test-files))
      (should-not my/lazy--triggers)
      (should-not (fboundp 'init-lazy-test-foo-mode))
      (should (equal (car auto-mode-alist) init-lazy-test--rule))
      (should (= init-lazy-test-loads 1))
      ;; Online again: the same command loads it, no stub involved.
      (let ((module (init-lazy-test--files-module)))
        (with-temp-file (expand-file-name "init-lazy-test-files.el"
                                          (car load-path))
          (insert (cdr module))))
      (should (my/lazy-load 'init-lazy-test-files))
      (should (eq (init-lazy-test--visit "/tmp/x.foo")
                  'init-lazy-test-foo-mode)))))

(ert-deftest init-lazy-direct-require-removes-stubs ()
  "A plain `require' keeps the module's mode and its single rule."
  (init-lazy-test--with-env (list (init-lazy-test--files-module))
    (let ((my/lazy-modules init-lazy-test--table))
      (my/lazy-require 'init-lazy-test-files)
      (should (get 'init-lazy-test-foo-mode 'function-documentation))
      (require 'init-lazy-test-files)
      (should-not my/lazy--triggers)
      (should-not (get 'init-lazy-test-foo-mode 'function-documentation))
      (should (eq (init-lazy-test--rule-mode "/tmp/x.foo")
                  'init-lazy-test-foo-mode))
      (with-temp-buffer
        (init-lazy-test-foo-mode)
        (should (eq major-mode 'init-lazy-test-foo-mode)))
      (should (= (cl-count "\\.foo\\'" auto-mode-alist :key #'car
                           :test #'equal)
                 1))
      (should (= init-lazy-test-loads 1)))))

(ert-deftest init-lazy-files-mode-stub-compiles-with-the-module ()
  "Compiling a module's own mode over its stub raises no arity warning."
  (init-lazy-test--with-env nil
    (let ((my/lazy-modules init-lazy-test--table)
          (file (expand-file-name "mode.el" init-lazy-test--dir))
          (byte-compile-dest-file-function (lambda (file) (concat file "c"))))
      (my/lazy-require 'init-lazy-test-files)
      (with-temp-file file
        (insert ";;; -*- lexical-binding: t; -*-\n"
                "(defun init-lazy-test-foo-mode () (interactive) nil)\n"))
      ;; Interactive Emacs logs warnings there, not in the echo area.
      (with-current-buffer (get-buffer-create "*Compile-Log*")
        (let ((inhibit-read-only t))
          (erase-buffer)))
      (let ((messages (init-lazy-test--messages
                       (lambda () (byte-compile-file file))))
            (log (with-current-buffer "*Compile-Log*" (buffer-string))))
        (should-not (string-match-p "used to take"
                                    (mapconcat #'identity messages "\n")))
        (should-not (string-match-p "used to take" log))))))

;;; Keys

(defconst init-lazy-test--key-forms
  '((defun init-lazy-test-key-command () (interactive))
    (keymap-global-set "C-c Q" #'init-lazy-test-key-command))
  "Forms of a fake module that binds the test key itself.")

(ert-deftest init-lazy-key-loads-and-replays ()
  "The stub loads the module, which rebinds the key; the key is typed again."
  (init-lazy-test--with-env
      (list (apply #'init-lazy-test--module 'init-lazy-test-keys
                   init-lazy-test--key-forms))
    (let ((my/lazy-modules '((init-lazy-test-keys :keys ("C-c Q")))))
      (my/lazy-require 'init-lazy-test-keys)
      (should-not (featurep 'init-lazy-test-keys))
      (let ((stub (init-lazy-test--global-key init-lazy-test--key)))
        (should (commandp stub))
        (call-interactively stub)
        (should (featurep 'init-lazy-test-keys))
        (should (eq (init-lazy-test--global-key init-lazy-test--key)
                    #'init-lazy-test-key-command))
        (should (equal unread-command-events '((t . 3) (t . 81))))
        (should-not my/lazy--triggers)))))

(ert-deftest init-lazy-key-unbound-after-load-does-not-replay ()
  "A key the module leaves alone or fails to bind loses the stub, not a loop."
  (dolist (module (list (init-lazy-test--module 'init-lazy-test-keys)
                        (init-lazy-test--module
                         'init-lazy-test-keys '(error "Broken module"))))
    (init-lazy-test--with-env (list module)
      (let ((my/lazy-modules '((init-lazy-test-keys :keys ("C-c Q")))))
        (my/lazy-require 'init-lazy-test-keys)
        (init-lazy-test--messages
         (lambda ()
           (call-interactively
            (init-lazy-test--global-key init-lazy-test--key))))
        (should-not (init-lazy-test--global-key init-lazy-test--key))
        (should-not unread-command-events)
        (should-not my/lazy--triggers)))))

(ert-deftest init-lazy-key-restores-previous-binding ()
  "Removing the stub brings back what the key was bound to before."
  (init-lazy-test--with-env (list (init-lazy-test--module 'init-lazy-test-keys))
    (let ((my/lazy-modules '((init-lazy-test-keys :keys ("C-c Q")))))
      (keymap-global-set init-lazy-test--key #'ignore)
      (my/lazy-require 'init-lazy-test-keys)
      (should-not (eq (init-lazy-test--global-key init-lazy-test--key)
                      #'ignore))
      (require 'init-lazy-test-keys)
      (should (eq (init-lazy-test--global-key init-lazy-test--key) #'ignore)))))

(ert-deftest init-lazy-key-direct-require-keeps-module-binding ()
  "A plain `require' drops the stub only if the module did not replace it."
  (init-lazy-test--with-env
      (list (apply #'init-lazy-test--module 'init-lazy-test-keys
                   init-lazy-test--key-forms))
    (let ((my/lazy-modules '((init-lazy-test-keys :keys ("C-c Q")))))
      (my/lazy-require 'init-lazy-test-keys)
      (require 'init-lazy-test-keys)
      (should-not my/lazy--triggers)
      (should (eq (init-lazy-test--global-key init-lazy-test--key)
                  #'init-lazy-test-key-command)))))

;;; Commands

(defconst init-lazy-test--package
  (init-lazy-test--module
   'init-lazy-test-pkg
   '(defun init-lazy-test-cmd (&rest args)
      (interactive)
      (setq init-lazy-test-result (list init-lazy-test-configured args))))
  "A fake package whose command reports whether the module was loaded.")

(defconst init-lazy-test--autoload
  '(autoload 'init-lazy-test-cmd "init-lazy-test-pkg" nil t)
  "What a package's autoloads file does for its command.")

(defun init-lazy-test--command-module (&rest forms)
  "Return a fake module that records its load, then evaluates FORMS."
  (apply #'init-lazy-test--module 'init-lazy-test-cmds
         '(setq init-lazy-test-configured t) forms))

(ert-deftest init-lazy-command-with-installed-package ()
  "The package's autoload exists at startup; the module still loads first."
  (init-lazy-test--with-env (list init-lazy-test--package
                                  (init-lazy-test--command-module))
    (let ((my/lazy-modules '((init-lazy-test-cmds
                              :commands (init-lazy-test-cmd)))))
      (eval init-lazy-test--autoload t)
      (let ((package-autoload (symbol-function 'init-lazy-test-cmd)))
        (my/lazy-require 'init-lazy-test-cmds)
        (should (commandp 'init-lazy-test-cmd))
        (should-not (featurep 'init-lazy-test-cmds))
        (call-interactively 'init-lazy-test-cmd)
        (should (equal init-lazy-test-result '(t nil)))
        (should (featurep 'init-lazy-test-cmds))
        (should-not (autoloadp (symbol-function 'init-lazy-test-cmd)))
        (should-not my/lazy--triggers)
        ;; The package's own autoload comes back if the module is required
        ;; some other way.
        (fmakunbound 'init-lazy-test-cmd)
        (fset 'init-lazy-test-cmd package-autoload)
        (setq features (remq 'init-lazy-test-cmds features))
        (my/lazy-require 'init-lazy-test-cmds)
        (require 'init-lazy-test-cmds)
        (should (eq (symbol-function 'init-lazy-test-cmd) package-autoload))))))

(ert-deftest init-lazy-command-with-package-installed-by-module ()
  "Without an autoload, the module's own installation defines the command."
  (init-lazy-test--with-env
      (list init-lazy-test--package
            (init-lazy-test--command-module init-lazy-test--autoload))
    (let ((my/lazy-modules '((init-lazy-test-cmds
                              :commands (init-lazy-test-cmd)))))
      (should-not (fboundp 'init-lazy-test-cmd))
      (my/lazy-require 'init-lazy-test-cmds)
      (should (commandp 'init-lazy-test-cmd))
      ;; Called as a function, with arguments.
      (init-lazy-test-cmd 1 2)
      (should (equal init-lazy-test-result '(t (1 2))))
      (should (featurep 'init-lazy-test-cmds))
      (should (featurep 'init-lazy-test-pkg))
      (should-not my/lazy--triggers)
      (call-interactively 'init-lazy-test-cmd)
      (should (equal init-lazy-test-result '(t nil))))))

(ert-deftest init-lazy-command-not-defined-by-module ()
  "A module without the command leaves a clean error, not a stub loop."
  (init-lazy-test--with-env (list (init-lazy-test--command-module))
    (let ((my/lazy-modules '((init-lazy-test-cmds
                              :commands (init-lazy-test-cmd)))))
      (my/lazy-require 'init-lazy-test-cmds)
      (should-error (call-interactively 'init-lazy-test-cmd)
                    :type 'user-error)
      (should-not (fboundp 'init-lazy-test-cmd))
      (should-not my/lazy--triggers)
      ;; The second attempt loads nothing again.
      (should-not (init-lazy-test--messages
                   (lambda ()
                     (should-error (call-interactively
                                    'init-lazy-test-cmd))))))))

(ert-deftest init-lazy-command-load-error ()
  "A failing module reports once and gives the package's autoload back."
  (init-lazy-test--with-env
      (list init-lazy-test--package
            (init-lazy-test--module
             'init-lazy-test-cmds
             '(setq init-lazy-test-loads (1+ init-lazy-test-loads))
             '(error "Offline test module")))
    (let ((my/lazy-modules '((init-lazy-test-cmds
                              :commands (init-lazy-test-cmd)))))
      (eval init-lazy-test--autoload t)
      (let ((package-autoload (symbol-function 'init-lazy-test-cmd)))
        (my/lazy-require 'init-lazy-test-cmds)
        (let ((messages
               (init-lazy-test--messages
                (lambda ()
                  (should-error (call-interactively 'init-lazy-test-cmd)
                                :type 'user-error)))))
          (should (string-match-p "Offline test module"
                                  (car (last messages)))))
        (should (eq (symbol-function 'init-lazy-test-cmd) package-autoload))
        (should-not (get 'init-lazy-test-cmd 'function-documentation))
        (should-not my/lazy--triggers)
        (should (= init-lazy-test-loads 1))))))

(ert-deftest init-lazy-command-leaves-real-definitions-alone ()
  "A command that is already defined needs no stub."
  (init-lazy-test--with-env (list (init-lazy-test--command-module))
    (let ((my/lazy-modules '((init-lazy-test-cmds
                              :commands (init-lazy-test-cmd)))))
      (defalias 'init-lazy-test-cmd #'ignore)
      (my/lazy-require 'init-lazy-test-cmds)
      (should (eq (symbol-function 'init-lazy-test-cmd) #'ignore))
      (should-not (get 'init-lazy-test-cmd 'function-documentation)))))

(ert-deftest init-lazy-command-stub-documents-itself ()
  "`C-h f' on a stub says what it will do; the text goes with the stub."
  (init-lazy-test--with-env (list init-lazy-test--package
                                  (init-lazy-test--command-module))
    (let ((my/lazy-modules '((init-lazy-test-cmds
                              :commands (init-lazy-test-cmd)))))
      (eval init-lazy-test--autoload t)
      (my/lazy-require 'init-lazy-test-cmds)
      (should (equal (documentation 'init-lazy-test-cmd)
                     "首次调用时先加载 init-lazy-test-cmds，再运行 init-lazy-test-cmd。"))
      (call-interactively 'init-lazy-test-cmd)
      (should-not (get 'init-lazy-test-cmd 'function-documentation)))))

;;; Shared behavior

(ert-deftest init-lazy-any-trigger-loads-and-removes-all ()
  "One use of any trigger loads the module and drops every stub of it."
  (init-lazy-test--with-env
      (list init-lazy-test--package
            (apply #'init-lazy-test--module 'init-lazy-test-all
                   (append init-lazy-test--foo-forms
                           init-lazy-test--key-forms
                           (list init-lazy-test--autoload))))
    (let ((my/lazy-modules '((init-lazy-test-all
                              :files (("\\.foo\\'" . init-lazy-test-foo-mode))
                              :keys ("C-c Q")
                              :commands (init-lazy-test-foo-mode
                                         init-lazy-test-cmd))))
          (before (copy-sequence auto-mode-alist)))
      (my/lazy-require 'init-lazy-test-all)
      (should (= (length (cdr (assq 'init-lazy-test-all my/lazy--triggers)))
                 3))
      (init-lazy-test--visit "/tmp/x.foo")
      (should (featurep 'init-lazy-test-all))
      (should-not my/lazy--triggers)
      (should (eq (init-lazy-test--global-key init-lazy-test--key)
                  #'init-lazy-test-key-command))
      (should (autoloadp (symbol-function 'init-lazy-test-cmd)))
      (should (equal auto-mode-alist (cons init-lazy-test--rule before))))))

(ert-deftest init-lazy-quit-keeps-triggers ()
  "Aborting the first load, say its download, leaves the triggers for later."
  (init-lazy-test--with-env
      (list (init-lazy-test--module
             'init-lazy-test-files
             '(setq init-lazy-test-loads (1+ init-lazy-test-loads))
             '(signal 'quit nil)))
    (let ((my/lazy-modules init-lazy-test--table))
      (my/lazy-require 'init-lazy-test-files)
      (should (eq (condition-case nil
                      (progn (init-lazy-test--visit "/tmp/x.foo") nil)
                    (quit 'quit))
                  'quit))
      (should (assq 'init-lazy-test-files my/lazy--triggers))
      (should (functionp 'init-lazy-test-foo-mode))
      (should (get 'init-lazy-test-foo-mode 'function-documentation))
      (should (= (cl-count init-lazy-test--rule auto-mode-alist
                           :test #'equal)
                 1))
      (should (= init-lazy-test-loads 1)))))

(ert-deftest init-lazy-requires-features-without-triggers ()
  "Features without an entry, or already loaded, are required now."
  (init-lazy-test--with-env (list (init-lazy-test--files-module)
                                  (init-lazy-test--module 'init-lazy-test-eager))
    (let ((my/lazy-modules nil))
      (my/lazy-require 'init-lazy-test-eager)
      (should (featurep 'init-lazy-test-eager)))
    (let ((my/lazy-modules '((init-lazy-test-files))))
      (my/lazy-require 'init-lazy-test-files)
      (should (featurep 'init-lazy-test-files)))
    (let ((my/lazy-modules init-lazy-test--table))
      (my/lazy-require 'init-lazy-test-files)
      (should-not my/lazy--triggers)
      (should (= init-lazy-test-loads 1)))))

(ert-deftest init-lazy-require-is-idempotent ()
  "Repeating the call, or reloading this file, adds no second stub or hook."
  (init-lazy-test--with-env
      (list init-lazy-test--package
            (apply #'init-lazy-test--module 'init-lazy-test-all
                   (append init-lazy-test--foo-forms
                           init-lazy-test--key-forms
                           (list init-lazy-test--autoload))))
    (let ((my/lazy-modules '((init-lazy-test-all
                              :files (("\\.foo\\'" . init-lazy-test-foo-mode))
                              :keys ("C-c Q")
                              :commands (init-lazy-test-foo-mode
                                         init-lazy-test-cmd)))))
      (my/lazy-require 'init-lazy-test-all)
      (let ((rules (copy-sequence auto-mode-alist))
            (hooks (copy-tree (assq 'init-lazy-test-all after-load-alist)))
            (triggers (length (cdr (assq 'init-lazy-test-all
                                         my/lazy--triggers)))))
        (should (= triggers 3))
        (my/lazy-require 'init-lazy-test-all)
        ;; Reloading re-evaluates the table, but keeps the state.
        (let ((table my/lazy-modules))
          (load (locate-library "init-lazy") nil t)
          (setq my/lazy-modules table))
        (my/lazy-require 'init-lazy-test-all)
        (should (equal auto-mode-alist rules))
        (should (= (cl-count init-lazy-test--rule auto-mode-alist
                             :test #'equal)
                   1))
        (should (= (length my/lazy--triggers) 1))
        (should (= (length (cdr (assq 'init-lazy-test-all my/lazy--triggers)))
                   triggers))
        (should (equal (assq 'init-lazy-test-all after-load-alist) hooks))
        (init-lazy-test--visit "/tmp/x.foo")
        (should-not my/lazy--triggers)
        (my/lazy-require 'init-lazy-test-all)
        (load (locate-library "init-lazy") nil t)
        (should-not my/lazy--triggers)
        (should (equal auto-mode-alist rules))))))

(ert-deftest init-lazy-load-command-offers-pending-modules ()
  "`M-x my/lazy-load' completes over the table's modules not loaded yet."
  (init-lazy-test--with-env (list (init-lazy-test--files-module))
    (push 'init-lazy-test-done features)
    (let ((my/lazy-modules (append init-lazy-test--table
                                   '((init-lazy-test-done
                                      :commands (init-lazy-test-cmd)))))
          offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered collection)
                   "init-lazy-test-files")))
        (call-interactively #'my/lazy-load))
      (should (equal offered '("init-lazy-test-files")))
      (should (featurep 'init-lazy-test-files))
      (should (= init-lazy-test-loads 1))
      (should-error (call-interactively #'my/lazy-load) :type 'user-error))))

;;; The real table

(defconst init-lazy-test--packages
  '((lang-nix nix-mode) (lang-agda poly-markdown)
    (lang-haskell haskell-mode) (lang-coq proof-general)
    (lang-lean lean4-mode) (init-telega telega))
  "Packages the real modules install, per feature.
The tests need them installed already and skip without them.")

(defun init-lazy-test--skip-unless-installed (feature)
  "Skip the running test unless the packages of FEATURE are installed."
  (dolist (package (cdr (assq feature init-lazy-test--packages)))
    (unless (package-installed-p package)
      (ert-skip (format "%s is not installed" package)))))

(defun init-lazy-test--call-with-real-module (feature thunk)
  "Call THUNK with FEATURE, a module of the real table, not loaded yet.
The stubs that startup installed for FEATURE are out of the way, as if
its package had been required directly; THUNK may install fresh ones
with `my/lazy-require'.  The functions, documentation, global keys and
trigger state of the live Emacs come back afterwards."
  (let* ((spec (cdr (assq feature my/lazy-modules)))
         (triggers (copy-sequence my/lazy--triggers))
         (functions (mapcar (lambda (command)
                              (list command (symbol-function command)
                                    (get command 'function-documentation)))
                            (plist-get spec :commands)))
         (bindings (mapcar (lambda (key)
                             (cons key (init-lazy-test--global-key key)))
                           (plist-get spec :keys))))
    (unwind-protect
        (progn
          (my/lazy--remove-triggers feature)
          (init-lazy-test--with-env nil
            (let ((features (remq feature (copy-sequence features))))
              (funcall thunk))))
      (setq my/lazy--triggers triggers)
      (pcase-dolist (`(,command ,definition ,doc) functions)
        (fset command definition)
        (cl-remf (symbol-plist command) 'function-documentation)
        (when doc (put command 'function-documentation doc)))
      (pcase-dolist (`(,key . ,binding) bindings)
        (init-lazy-test--restore-key key binding)))))

(defmacro init-lazy-test--with-real-module (feature &rest body)
  "Run BODY with the real module FEATURE not loaded; see the function."
  (declare (indent 1))
  `(init-lazy-test--call-with-real-module ,feature (lambda () ,@body)))

(defun init-lazy-test--as-autoload (command file)
  "Make COMMAND an autoload of FILE, as startup does for a package's modes.
Use it in `init-lazy-test--with-real-module', which restores the original
definition, so that a stub can replace COMMAND whatever has been loaded."
  (fset command nil)
  (autoload command file nil t))

(defun init-lazy-test--define-per-module (prefix doc key function)
  "Define a test PREFIX-FEATURE for each table module that has KEY triggers.
FUNCTION receives the feature inside `init-lazy-test--with-real-module';
the test is skipped unless the packages of the module are installed."
  (dolist (entry my/lazy-modules)
    (when (plist-get (cdr entry) key)
      (let ((feature (car entry))
            (name (intern (format "%s-%s" prefix (car entry)))))
        (ert-set-test
         name
         (make-ert-test
          :name name :documentation doc
          :body (lambda ()
                  (init-lazy-test--skip-unless-installed feature)
                  (init-lazy-test--with-real-module feature
                    (funcall function feature)))))))))

(ert-deftest init-lazy-real-table-is-well-formed ()
  "Every module exists and every trigger is of a known, valid kind."
  (dolist (entry my/lazy-modules)
    (should (locate-library (symbol-name (car entry))))
    (should (cdr entry))
    (let ((spec (cdr entry)))
      (while spec
        (should (memq (car spec) '(:files :keys :commands)))
        (should (consp (cadr spec)))
        (dolist (item (cadr spec))
          (pcase (car spec)
            (:files (should (stringp (car-safe item)))
                    (should (symbolp (cdr item)))
                    (should (cdr item)))
            (:keys (should (key-valid-p item)))
            (:commands (should (and item (symbolp item))))))
        (setq spec (cddr spec))))
    ;; Files that no stub stands behind would never load the module.
    (let ((modes (mapcar #'cdr (plist-get (cdr entry) :files))))
      (when modes
        (should (seq-intersection modes (plist-get (cdr entry) :commands)))))))

(init-lazy-test--define-per-module
 'init-lazy-real-files-match
 "The module registers exactly the file rules its table entry declares.
A declared rule that the module does not register would load it for
nothing, or start the wrong mode; a rule that the table lacks would put
the module's mode in front of nothing, for files that never trigger it."
 :files
 (lambda (feature)
   (let ((declared (plist-get (cdr (assq feature my/lazy-modules)) :files))
         (auto-mode-alist nil))
     (load (locate-library (symbol-name feature)) nil t)
     (should auto-mode-alist)
     (should-not (cl-set-exclusive-or auto-mode-alist declared
                                      :test #'equal)))))

(init-lazy-test--define-per-module
 'init-lazy-real-commands-defined
 "After the module loads, each command of its entry is defined by it or by
its package, not by one of our stubs."
 :commands
 (lambda (feature)
   (load (locate-library (symbol-name feature)) nil t)
   (dolist (command (plist-get (cdr (assq feature my/lazy-modules)) :commands))
     (ert-info ((format "%s defines %s" feature command))
       (should (fboundp command))
       (should-not (get command 'function-documentation))))))

(ert-deftest init-lazy-real-rules-lead-and-stay-single ()
  "Each rule is in front of built-in ones once, however often it is installed."
  (dolist (feature '(lang-rust lang-go))
    (init-lazy-test--with-real-module feature
      (let ((files (plist-get (cdr (assq feature my/lazy-modules)) :files)))
        (my/lazy-require feature)
        (my/lazy-require feature)
        (should (equal (seq-take auto-mode-alist (length files)) files))
        (dolist (rule files)
          (should (= (cl-count rule auto-mode-alist :test #'equal) 1)))))))

(ert-deftest init-lazy-real-rust-highlighting-sees-the-mode ()
  "Code that reads the alist finds `rust-ts-mode' before lang-rust loads."
  (require 'agent-review)
  (init-lazy-test--with-real-module 'lang-rust
    (init-lazy-test--as-autoload 'rust-ts-mode "rust-ts-mode")
    (my/lazy-require 'lang-rust)
    (should-not (featurep 'lang-rust))
    (should (eq (agent-review--file-mode "src/x.rs") 'rust-ts-mode))
    ;; Cargo.lock is TOML; lang-rust has nothing to add to it.
    (should (eq (init-lazy-test--rule-mode "Cargo.lock") 'toml-ts-mode))
    (should-not (get 'toml-ts-mode 'function-documentation))
    (skip-unless (treesit-language-available-p 'rust))
    (with-temp-buffer
      (funcall (agent-review--file-mode "src/x.rs"))
      (should (eq major-mode 'rust-ts-mode)))
    (should (featurep 'lang-rust))
    (should-not my/lazy--triggers)))

(ert-deftest init-lazy-real-canvas-code-block-uses-the-go-mode ()
  "A code block with a path highlights with go-ts-mode, loading lang-go."
  (skip-unless (treesit-language-available-p 'go))
  (require 'agent-canvas)
  (let ((file (make-temp-file "init-lazy-test-" nil ".go"
                              "package main\n\nfunc main() {}\n")))
    (unwind-protect
        (init-lazy-test--with-real-module 'lang-go
          (dolist (mode '(go-ts-mode go-mod-ts-mode go-work-ts-mode))
            (init-lazy-test--as-autoload mode "go-ts-mode"))
          (my/lazy-require 'lang-go)
          (should-not (featurep 'lang-go))
          (let ((buffer (agent-canvas--buffer "init-lazy-test")))
            (unwind-protect
                (with-current-buffer buffer
                  (set-window-buffer (selected-window) buffer)
                  (setq agent-canvas--page
                        (list :title "init-lazy-test"
                              :blocks (agent-canvas--load-sources
                                       (vector (list :type "code"
                                                     :path file)))))
                  (agent-canvas--redraw (selected-window))
                  (goto-char (point-min))
                  (search-forward "func")
                  (should (memq 'font-lock-keyword-face
                                (ensure-list
                                 (get-text-property (match-beginning 0)
                                                    'face)))))
              (kill-buffer buffer)))
          (should (featurep 'lang-go)))
      (delete-file file))))

(ert-deftest init-lazy-real-nix-mode-command-loads-the-module ()
  "`M-x nix-mode', before any .nix file, loads lang-nix and its hook."
  (init-lazy-test--skip-unless-installed 'lang-nix)
  (init-lazy-test--with-real-module 'lang-nix
    (init-lazy-test--as-autoload 'nix-mode "nix-mode")
    (remove-hook 'nix-mode-hook #'my/nix-setup)
    (my/lazy-require 'lang-nix)
    (should-not (featurep 'lang-nix))
    (should (equal (documentation 'nix-mode)
                   "首次调用时先加载 lang-nix，再运行 nix-mode。"))
    (with-temp-buffer
      (call-interactively 'nix-mode)
      (should (eq major-mode 'nix-mode)))
    (should (featurep 'lang-nix))
    (should (memq 'my/nix-setup nix-mode-hook))
    (should-not my/lazy--triggers)))

(ert-deftest init-lazy-real-telega-key-runs-init-telega ()
  "C-c T loads init-telega and is typed again; the module owns the key then."
  (init-lazy-test--skip-unless-installed 'init-telega)
  (require 'bind-key)
  ;; `use-package :custom' records its settings in the `use-package' theme
  ;; and on the variables, whether or not telega itself is loaded.
  (let* ((key "C-c T")
         (variables '(telega-directory telega-server-libs-prefix))
         (saved (mapcar (lambda (variable)
                          (list variable (default-boundp variable)
                                (and (default-boundp variable)
                                     (default-value variable))
                                (copy-tree (symbol-plist variable))))
                        variables))
         (theme-settings (copy-tree (get 'use-package 'theme-settings)))
         (known-themes (copy-sequence custom-known-themes))
         (enabled-themes (copy-sequence custom-enabled-themes))
         (personal-keybindings (copy-tree personal-keybindings)))
    (unwind-protect
        (init-lazy-test--with-real-module 'init-telega
          (dolist (variable variables)
            (put variable 'theme-value nil))
          (my/lazy-require 'init-telega)
          (let ((stub (init-lazy-test--global-key key)))
            (should (commandp stub))
            (should (assq 'init-telega my/lazy--triggers))
            (should-not (featurep 'init-telega))
            (call-interactively stub)
            (should (featurep 'init-telega))
            ;; The key is typed again: C-c, T.
            (should (equal unread-command-events '((t . 3) (t . 84))))
            (let ((binding (init-lazy-test--global-key key)))
              (should-not (eq binding stub))
              (should (or (commandp binding) (keymapp binding)))
              ;; `bind-key' recorded it, so init-telega bound the key.
              (should (cl-find key personal-keybindings
                               :key #'caar :test #'equal)))
            (should (equal (get 'telega-directory 'theme-value)
                           '((use-package (my/var "telega/")))))
            (should-not my/lazy--triggers)
            (dolist (command '(telega telega-server-build))
              (should-not (get command 'function-documentation)))))
      (pcase-dolist (`(,variable ,bound ,value ,plist) saved)
        (setplist variable plist)
        (if bound
            (set-default variable value)
          (makunbound variable)))
      (put 'use-package 'theme-settings theme-settings)
      (setq custom-known-themes known-themes
            custom-enabled-themes enabled-themes))))

(provide 'init-lazy-test)
;;; init-lazy-test.el ends here
