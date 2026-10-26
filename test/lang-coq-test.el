;;; lang-coq-test.el --- Coq integration tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Run after init.el.  Proof General and all process calls are mocked, so
;; these tests neither install packages nor require a Coq executable.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'init-env)
(require 'use-package)
(require 'init-lazy)

(defvar coq-mode-map)
(defvar my/coq-command-map)
(declare-function my/coq-start-with-environment "lang-coq")
(declare-function my/coq-mode "lang-coq")
(declare-function coq-mode "coq")
(declare-function proof-shell-start "proof-shell")

(defconst lang-coq-test--module
  (expand-file-name "../lisp/lang/lang-coq.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro lang-coq-test--with-bootstrap (&rest body)
  "Evaluate BODY with a preinstalled PG mode stub and mocked bootstrap."
  (declare (indent 0) (debug t))
  `(let ((saved-features (copy-sequence features))
         (after-load-alist nil)
         (auto-mode-alist (copy-tree auto-mode-alist))
         (coq-mode-map (make-sparse-keymap))
         (use-package-ensure-function 'use-package-ensure-elpa)
         (native-comp-enable-subr-trampolines nil)
         (original-require (symbol-function 'require))
         ensured bootstrap-loaded (mode-invocations 0))
     (ignore ensured bootstrap-loaded mode-invocations)
     ;; Seed PG's documented native keys; the module must leave them intact.
     (dolist (binding '(("C-c C-n" . proof-assert-next-command-interactive)
                        ("C-c C-u" . proof-undo-last-successful-command)
                        ("C-c C-RET" . proof-goto-point)
                        ("C-c C-b" . proof-process-buffer)
                        ("C-c C-r" . proof-retract-buffer)))
       (define-key coq-mode-map (kbd (car binding)) (cdr binding)))
     ;; `provide' changes the global feature list even through a let binding.
     (unwind-protect
         (progn
           (setq features (seq-difference features
                                             '(lang-coq proof-site proof-shell
							coq evil)))
	   (cl-letf (((symbol-function 'use-package-ensure-elpa)
                      (lambda (name args _state)
			(push (cons name args) ensured) t))
		     ((symbol-function 'require)
                      (lambda (feature &rest args)
			(if (eq feature 'proof-site)
			    (progn
                              (setq bootstrap-loaded t)
                              (provide 'proof-site))
			  (apply original-require feature args))))
		     ;; PG installs an ordinary function at package startup, before
                     ;; the optional language module has been loaded.
                     ((symbol-function 'coq-mode)
                      (lambda ()
                        (interactive)
                        (cl-incf mode-invocations)
                        (kill-all-local-variables)
                        (setq major-mode 'coq-mode)
                        (use-local-map coq-mode-map)
                        (run-mode-hooks 'coq-mode-hook)))
                     ((symbol-function 'my/coq-mode) nil)
		     ((symbol-function 'proof-shell-start) #'ignore)
		     ((symbol-function 'make-process)
                      (lambda (&rest _) (ert-fail "Unexpected process")))
		     ((symbol-function 'start-process)
                      (lambda (&rest _) (ert-fail "Unexpected process")))
		     ((symbol-function 'process-file)
                      (lambda (&rest _) (ert-fail "Unexpected process")))
		     ((symbol-function 'call-process)
                      (lambda (&rest _) (ert-fail "Unexpected process")))
		     ((symbol-function 'package-install)
                      (lambda (&rest _) (ert-fail "Unexpected package install")))
		     ((symbol-function 'package-refresh-contents)
                      (lambda (&rest _) (ert-fail "Unexpected package refresh")))
		     ((symbol-function 'eglot-ensure)
                      (lambda (&rest _) (ert-fail "Unexpected Eglot start"))))
	     ,@body))
       (setq features saved-features))))

(defmacro lang-coq-test--with-module (&rest body)
  "Evaluate BODY after loading the module with mocked Proof General."
  (declare (indent 0) (debug t))
  `(lang-coq-test--with-bootstrap
     (load lang-coq-test--module nil t)
     ,@body))

(ert-deftest lang-coq-lazy-start-with-preinstalled-mode ()
  "A PG startup function must not bypass the language module on file visit."
  (lang-coq-test--with-bootstrap
    (let ((my/lazy-modules
           '((lang-coq :files (("\\.v\\'" . my/coq-mode))
                       :commands (my/coq-mode))))
          (my/lazy--triggers nil)
          (installed-mode (symbol-function 'coq-mode)))
      (unwind-protect
          (progn
            (should (functionp installed-mode))
            (should-not (autoloadp installed-mode))
            (my/lazy-require 'lang-coq)
            (should-not (featurep 'lang-coq))
            (should-not bootstrap-loaded)
            (should-not ensured)
            (should (zerop mode-invocations))
            (should (eq (symbol-function 'coq-mode) installed-mode))
            ;; Loading the module must also advise an already loaded PG shell.
            (provide 'proof-shell)
            (with-temp-buffer
              (setq buffer-file-name "/tmp/LazyProof.v")
              (set-auto-mode)
              (should (eq major-mode 'coq-mode))
              (should (featurep 'lang-coq))
              (should bootstrap-loaded)
              (should (equal ensured '((proof-site proof-general))))
              (should (= mode-invocations 1))
              (should (eq (symbol-function 'coq-mode) installed-mode))
              (should (advice-member-p #'my/coq-start-with-environment
                                       'proof-shell-start))
              (setq-local envrc-mode t envrc--running t envrc--status 'on)
              (should-error (proof-shell-start) :type 'user-error))
            (should-not (assq 'lang-coq my/lazy--triggers)))
        (my/lazy--remove-triggers 'lang-coq)))))

(ert-deftest lang-coq-bootstrap-and-file-association ()
  "Install the correct package and leave Coq loading to PG's mode stub."
  (lang-coq-test--with-module
    (should bootstrap-loaded)
    (should (equal ensured '((proof-site proof-general))))
    (should-not (featurep 'coq))
    (should-not (featurep 'proof-shell))
    (should (eq (cdr (assoc "\\.v\\'" auto-mode-alist)) 'my/coq-mode))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/Proof.v")
      (set-auto-mode)
      (should (eq major-mode 'coq-mode)))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/Proof.vother")
      (set-auto-mode)
      (should-not (eq major-mode 'coq-mode)))))

(ert-deftest lang-coq-native-keys-without-evil ()
  "Native proof operations work without loading Evil or starting a prover."
  (lang-coq-test--with-module
    (should-not (featurep 'evil))
    (with-temp-buffer
      (coq-mode)
      (dolist (binding '(("C-c C-n" . proof-assert-next-command-interactive)
                         ("C-c C-u" . proof-undo-last-successful-command)
                         ("C-c C-RET" . proof-goto-point)
                         ("C-c C-b" . proof-process-buffer)
                         ("C-c C-r" . proof-retract-buffer)))
        (should (eq (key-binding (kbd (car binding))) (cdr binding)))))))

(ert-deftest lang-coq-evil-both-load-orders ()
  "Install the language leader only after Evil and Coq are available."
  (dolist (order '((evil coq) (coq evil)))
    (lang-coq-test--with-module
      (let (calls)
        (cl-letf (((symbol-function 'evil-define-key*)
                   (lambda (states map key definition)
                     (push (list states map key definition) calls))))
          (provide (car order))
          (should-not calls)
          (provide (cadr order))
          (should (= (length calls) 1))
          (should (equal (caar calls) '(normal motion visual)))
          (should (eq (nth 1 (car calls)) coq-mode-map))
          (should (equal (nth 2 (car calls)) (kbd "<leader>l")))
          (should (eq (nth 3 (car calls)) my/coq-command-map)))))))

(ert-deftest lang-coq-leader-proof-workflow ()
  "Expose script processing and process lifecycle without changing PG keys."
  (lang-coq-test--with-module
    (dolist (binding '(("n" . proof-assert-next-command-interactive)
                       ("u" . proof-undo-last-successful-command)
                       ("p" . proof-goto-point)
                       ("b" . proof-process-buffer)
                       ("r" . proof-retract-buffer)
                       ("R" . proof-shell-restart)
                       ("q" . proof-shell-exit)))
      (should (eq (lookup-key my/coq-command-map (kbd (car binding)))
                  (cdr binding))))))

(ert-deftest lang-coq-pending-environment-blocks-start ()
  "Pending and denied environments block native as well as leader starts."
  (lang-coq-test--with-module
    (let ((started nil))
      (cl-letf (((symbol-function 'proof-shell-start)
                 (lambda () (setq started t))))
        (provide 'proof-shell)
        (with-temp-buffer
          (coq-mode)
          (setq-local envrc-mode t envrc--running t envrc--status 'on)
          (should-error (proof-shell-start) :type 'user-error)
          (setq-local envrc--running nil envrc--status 'denied)
          (should-error (proof-shell-start) :type 'user-error)
          (should-not started))))))

(ert-deftest lang-coq-ready-environment-reaches-process-buffer ()
  "A ready environment follows PG when it creates a process buffer."
  (lang-coq-test--with-module
    (let ((outer-path exec-path)
          (outer-env process-environment)
          started)
      (cl-letf (((symbol-function 'proof-shell-start)
                 (lambda ()
                   (with-temp-buffer
                     (setq started (list (getenv "COQ_TEST_ENV") exec-path))))))
        (provide 'proof-shell)
        (with-temp-buffer
          (coq-mode)
          (setq-local envrc-mode t envrc--running nil envrc--status 'on
                      process-environment '("COQ_TEST_ENV=project")
                      exec-path '("/project/bin"))
          (proof-shell-start))
        (should (equal started '("project" ("/project/bin"))))
        (should (equal exec-path outer-path))
        (should (equal process-environment outer-env))))))

(ert-deftest lang-coq-start-without-envrc-and-other-assistants ()
  "Unmanaged Coq buffers and other PG assistants remain usable."
  (lang-coq-test--with-module
    (let ((starts 0))
      (cl-letf (((symbol-function 'proof-shell-start)
                 (lambda () (cl-incf starts))))
        (provide 'proof-shell)
        (with-temp-buffer
          (coq-mode)
          (setq-local envrc-mode nil)
          (proof-shell-start))
        (with-temp-buffer
          (setq major-mode 'easycrypt-mode)
          (setq-local envrc-mode t envrc--running t envrc--status 'denied)
          (proof-shell-start))
        (should (= starts 2))))))

(ert-deftest lang-coq-byte-compiles-without-evil ()
  "Compile the module warning-free without installing PG or loading Evil."
  (lang-coq-test--with-module
    (require 'bytecomp)
    (let* ((directory (make-temp-file "coq-elc-" t))
           (byte-compile-error-on-warn t)
           (byte-compile-dest-file-function
            (lambda (_) (expand-file-name "lang-coq.elc" directory))))
      (unwind-protect
          (should (byte-compile-file lang-coq-test--module))
        (delete-directory directory t)))))

(provide 'lang-coq-test)
;;; lang-coq-test.el ends here
