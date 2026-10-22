;;; init-evil-pinyin-test.el --- Real Evil pinyin keys -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with init.el and an installed evil-pinyin (or an upstream path
;; dependency).  All motions below go through the real command loop.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)

(declare-function evil-mode "evil-core")
(declare-function evil-local-mode "evil-core")
(declare-function evil-normal-state "evil-states")
(declare-function evil-pinyin-mode "evil-pinyin")
(declare-function global-evil-pinyin-mode "evil-pinyin")
(declare-function evil-pinyin--get-char-table "evil-pinyin")
(declare-function evil-ex-make-search-pattern "evil-search")
(declare-function evil-ex-pattern-regex "evil-search")
(declare-function my/toggle-evil "init-base")
(declare-function my/evil-pinyin--microsoft-char-table "init-evil")
(defvar evil-mode)
(defvar evil-local-mode)
(defvar evil-last-find)
(defvar evil-pinyin-mode)
(defvar evil-pinyin-scheme)
(defvar evil-pinyin-char-table)
(defvar evil-pinyin-with-search-rule)
(defvar evil-pinyin-with-punctuation)
(defvar my/use-evil)
(defvar package-user-dir)
(defvar use-package-ensure-function)

(defun init-evil-pinyin-test--native-process (check)
  "Run CHECK after native startup in an isolated, offline Emacs process."
  (with-temp-buffer
    (let* ((setup
            `(progn
               (setq package-user-dir ,package-user-dir my/use-evil nil)
               (defvar init-evil-pinyin-test--forbidden-attempts 0)
               (defun init-evil-pinyin-test--forbid-startup (&rest _)
                 (setq init-evil-pinyin-test--forbidden-attempts
                       (1+ init-evil-pinyin-test--forbidden-attempts))
                 (error "Unexpected installation, network or server startup"))
               (dolist (fn '(package-install package-refresh-contents server-start
                             open-network-stream make-network-process))
                 (advice-add fn :before
                             #'init-evil-pinyin-test--forbid-startup))))
           (status
            (call-process (expand-file-name invocation-name invocation-directory)
                          nil (current-buffer) nil
                          "-Q" "--batch"
                          (concat "--init-directory=" emx-test--checkout)
                          "--eval" (prin1-to-string setup)
                          "-l" (expand-file-name "init.el" emx-test--checkout)
                          "--eval"
                          (prin1-to-string
                           `(progn
                              (require 'ert)
                              ,check
                              (should (= 0 init-evil-pinyin-test--forbidden-attempts)))))))
      (ert-info ((buffer-string))
        (should (eql status 0))))))

(ert-deftest init-evil-pinyin-native-startup ()
  "Native startup does not load Evil/pinyin or attempt any installation."
  (init-evil-pinyin-test--native-process
   '(progn
      (should-not (featurep 'evil))
      (should-not (featurep 'evil-pinyin))
      (should-not (featurep 'init-evil))
      (should-not (bound-and-true-p evil-mode))
      (should (eq (key-binding "f") 'self-insert-command)))))

(defun init-evil-pinyin-test--forbid (&rest _)
  "Reject package installation and network access in the fixture."
  (error "Unexpected test installation or network access"))

(defun init-evil-pinyin-test--require-config ()
  "Skip absent direct dependencies before loading configuration offline."
  (dolist (dependency '(evil evil-collection evil-pinyin))
    (unless (locate-library (symbol-name dependency))
      (ert-skip (format "Missing optional dependency: %s" dependency))))
  ;; A source dependency need not have an ELPA package descriptor.  Never let
  ;; :ensure install anything, even if this config was previously compiled.
  (let ((use-package-ensure-function #'ignore))
    (cl-letf (((symbol-function 'use-package-ensure-elpa) #'ignore)
              ((symbol-function 'package-install)
               #'init-evil-pinyin-test--forbid)
              ((symbol-function 'package-refresh-contents)
               #'init-evil-pinyin-test--forbid)
              ((symbol-function 'open-network-stream)
               #'init-evil-pinyin-test--forbid)
              ((symbol-function 'make-network-process)
               #'init-evil-pinyin-test--forbid))
      (require 'init-evil))))

(ert-deftest init-evil-pinyin-missing-dependency-skips-offline ()
  "Missing pinyin skips a real motion test before loading or installing."
  (init-evil-pinyin-test--native-process
   `(progn
      (load ,(expand-file-name "test/init-evil-pinyin-test.el" emx-test--checkout)
            nil t)
      (let ((locate (symbol-function 'locate-library)))
        (cl-letf (((symbol-function 'locate-library)
                   (lambda (library &rest args)
                     (cond
                      ((equal library "evil-pinyin") nil)
                      ;; Reach the pinyin check even in a minimal ELPA.
                      ((member library '("evil" "evil-collection")) "present")
                      (t (apply locate library args))))))
          (let ((result (ert-run-test
                         (ert-get-test 'init-evil-pinyin-microsoft-initials))))
            (should (ert-test-skipped-p result))
            (should (string-match-p "Missing optional dependency: evil-pinyin"
                                    (prin1-to-string result))))))
      (should-not (featurep 'init-evil))
      (should-not (featurep 'evil))
      (should-not (featurep 'evil-pinyin)))))

(defmacro init-evil-pinyin-test--with-buffer (text &rest body)
  "Run BODY in a displayed normal-state buffer containing TEXT."
  (declare (indent 1))
  `(let ((enabled (bound-and-true-p evil-mode))
         (my/use-evil my/use-evil))
     (init-evil-pinyin-test--require-config)
     (unwind-protect
         (progn
           (evil-mode 1)
           (save-window-excursion
             (with-temp-buffer
               (switch-to-buffer (current-buffer))
               (buffer-enable-undo)
               (insert ,text)
               (goto-char (point-min))
               (evil-local-mode 1)
               (evil-normal-state)
               (evil-pinyin-mode 1)
               (setq-local evil-last-find nil)
               ,@body)))
       (when (fboundp 'evil-mode)
         (evil-mode (if enabled 1 -1))))))

(defun init-evil-pinyin-test--keys (keys position)
  "Execute KEYS and assert that point lands at POSITION."
  (execute-kbd-macro (kbd keys))
  (should (= (point) position)))

(ert-deftest init-evil-pinyin-microsoft-initials ()
  "One key matches Microsoft's zh/ch/sh and ordinary initials."
  (dolist (case '(("v" . "中找") ("i" . "吃长") ("u" . "是书")
                  ("b" . "不") ("n" . "你") ("z" . "在")
                  ("c" . "从") ("s" . "所")))
    (seq-doseq (char (cdr case))
      (init-evil-pinyin-test--with-buffer (concat "x" (string char))
        (init-evil-pinyin-test--keys (concat "f" (car case)) 2)))))

(ert-deftest init-evil-pinyin-microsoft-zero-initials ()
  "Microsoft o matches all upstream a/e/o groups; a/e remain ASCII."
  (seq-doseq (char "阿爱安昂奥额诶恩儿哦欧")
    (init-evil-pinyin-test--with-buffer (concat "x" (string char))
      (init-evil-pinyin-test--keys "fo" 2)))
  (init-evil-pinyin-test--with-buffer "x阿爱安昂奥额诶恩儿哦欧ae"
    (init-evil-pinyin-test--keys "fa" 13)
    (goto-char 1)
    (init-evil-pinyin-test--keys "fe" 14))
  (init-evil-pinyin-test--with-buffer "xo阿o额哦o"
    (init-evil-pinyin-test--keys "fo" 2)
    (dolist (position '(3 4 5 6 7))
      (init-evil-pinyin-test--keys ";" position))))

(ert-deftest init-evil-pinyin-custom-table-preserves-upstream ()
  "Only a/e/o differ; repeated setup never mutates the upstream table."
  (init-evil-pinyin-test--with-buffer "x"
    (let* ((evil-pinyin-scheme 'simplified-weiruan-all)
           (upstream (evil-pinyin--get-char-table))
           (before (copy-tree upstream t))
           (first (my/evil-pinyin--microsoft-char-table))
           (second (my/evil-pinyin--microsoft-char-table)))
      (should (equal first second))
      (should-not (eq first upstream))
      (should-not (eq first second))
      (should (equal evil-pinyin-char-table first))
      (should (equal (nth 14 first)
                     (concat (nth 0 before) (nth 4 before) (nth 14 before))))
      (should (equal (nth 0 first) ""))
      (should (equal (nth 4 first) ""))
      (dotimes (index (length upstream))
        (unless (memq index '(0 4 14))
          (should (equal (nth index first) (nth index before)))))
      (should (equal upstream before)))))

(ert-deftest init-evil-pinyin-ascii-union-and-literals ()
  "ASCII and Chinese form one ordered set; other input stays literal."
  (init-evil-pinyin-test--with-buffer "xv中v找V"
    (init-evil-pinyin-test--keys "fv" 2)
    (init-evil-pinyin-test--keys ";" 3)
    (init-evil-pinyin-test--keys ";" 4)
    (init-evil-pinyin-test--keys ";" 5)
    (goto-char 1)
    (init-evil-pinyin-test--keys "fV" 6)
    (goto-char 1)
    (init-evil-pinyin-test--keys "f中" 3))
  (init-evil-pinyin-test--with-buffer "x，,。.（("
    (init-evil-pinyin-test--keys "f," 3)
    (init-evil-pinyin-test--keys "f." 5)
    (init-evil-pinyin-test--keys "f(" 7)))

(ert-deftest init-evil-pinyin-four-motions-counts-repeats ()
  "All four motions retain counts and both repeat directions."
  (dolist (case '(("fv" 3 ";" 6 "," 3)
                  ("tv" 2 ";" 5 "," 4)
                  ("Fv" 6 ";" 3 "," 6)
                  ("Tv" 7 ";" 4 "," 5)))
    (init-evil-pinyin-test--with-buffer "ab中de找gh"
      (goto-char (if (memq (aref (car case) 0) '(?F ?T)) 8 1))
      (init-evil-pinyin-test--keys (nth 0 case) (nth 1 case))
      (init-evil-pinyin-test--keys (nth 2 case) (nth 3 case))
      (init-evil-pinyin-test--keys (nth 4 case) (nth 5 case))))
  (dolist (case '(("2fv" 6) ("2tv" 5) ("2Fv" 3) ("2Tv" 4)))
    (init-evil-pinyin-test--with-buffer "ab中de找gh"
      (goto-char (if (memq (aref (car case) 1) '(?F ?T)) 8 1))
      (init-evil-pinyin-test--keys (car case) (cadr case))))
  (init-evil-pinyin-test--with-buffer "a中b找c中d找e"
    (init-evil-pinyin-test--keys "fv" 2)
    (init-evil-pinyin-test--keys "2;" 6)
    (init-evil-pinyin-test--keys "2," 2)))

(ert-deftest init-evil-pinyin-operators-and-dot ()
  "df/dt, counted operators and dot replay the union motion."
  (dolist (case '(("dfv" "bb找cc中dd找ee" "cc中dd找ee")
                  ("dtv" "中bb找cc中dd找ee" "找cc中dd找ee")
                  ("d2fv" "cc中dd找ee" "ee")
                  ("2dfv" "cc中dd找ee" "ee")))
    (init-evil-pinyin-test--with-buffer "aa中bb找cc中dd找ee"
      (execute-kbd-macro (kbd (car case)))
      (should (equal (buffer-string) (nth 1 case)))
      (execute-kbd-macro (kbd "."))
      (should (equal (buffer-string) (nth 2 case))))))

(ert-deftest init-evil-pinyin-zero-initial-counts-repeats-operators ()
  "The o union retains upstream counts, repeats, operators and dot."
  (init-evil-pinyin-test--with-buffer "a阿b额c哦d爱e"
    (init-evil-pinyin-test--keys "fo" 2)
    (init-evil-pinyin-test--keys "2;" 6)
    (init-evil-pinyin-test--keys "2," 2))
  (init-evil-pinyin-test--with-buffer "a阿b额c哦d爱e"
    (init-evil-pinyin-test--keys "2fo" 4))
  (dolist (case '(("dfo" "bb额cc哦dd爱ee" "cc哦dd爱ee")
                  ("dto" "阿bb额cc哦dd爱ee" "额cc哦dd爱ee")
                  ("d2fo" "cc哦dd爱ee" "ee")
                  ("2dfo" "cc哦dd爱ee" "ee")))
    (init-evil-pinyin-test--with-buffer "aa阿bb额cc哦dd爱ee"
      (execute-kbd-macro (kbd (car case)))
      (should (equal (buffer-string) (nth 1 case)))
      (execute-kbd-macro (kbd "."))
      (should (equal (buffer-string) (nth 2 case))))))

(ert-deftest init-evil-pinyin-buffer-toggle ()
  "The standard buffer command selects exact character matching."
  (init-evil-pinyin-test--with-buffer "a中b找cv"
    (should (commandp 'evil-pinyin-mode))
    (execute-kbd-macro (kbd "M-x evil-pinyin-mode RET"))
    (should-not evil-pinyin-mode)
    (init-evil-pinyin-test--keys "fv" 6)
    (goto-char 1)
    (execute-kbd-macro (kbd "M-x evil-pinyin-mode RET"))
    (init-evil-pinyin-test--keys "fv" 2)
    (let ((other (generate-new-buffer "evil-pinyin-other")))
      (unwind-protect
          (progn
            (switch-to-buffer other)
            (fundamental-mode)
            (insert "a中v")
            (goto-char 1)
            (init-evil-pinyin-test--keys "fv" 2)
            (should evil-pinyin-mode))
        (kill-buffer other)))))

(ert-deftest init-evil-pinyin-global-toggle ()
  "The package's global command also enables and disables real motions."
  (init-evil-pinyin-test--with-buffer "a中v"
    (unwind-protect
        (progn
          (global-evil-pinyin-mode -1)
          (should-not evil-pinyin-mode)
          (init-evil-pinyin-test--keys "fv" 3)
          (goto-char 1)
          (global-evil-pinyin-mode 1)
          (init-evil-pinyin-test--keys "fv" 2))
      (global-evil-pinyin-mode 1))))

(ert-deftest init-evil-pinyin-evil-toggle ()
  "Global Evil off restores native commands and on restores motions."
  (init-evil-pinyin-test--with-buffer "a中bv"
    (unwind-protect
        (progn
          (my/toggle-evil)
          (should-not evil-mode)
          (should-not evil-local-mode)
          (init-evil-pinyin-test--keys "f v" 3)
          (should (equal (buffer-string) "fva中bv"))
          (erase-buffer)
          (insert "a中bv")
          (goto-char 1)
          (my/toggle-evil)
          (should evil-local-mode)
          (init-evil-pinyin-test--keys "fv" 2))
      (evil-mode 1))))

(ert-deftest init-evil-pinyin-config-and-search ()
  "Configuration uses the custom table and preserves literal search."
  (init-evil-pinyin-test--with-buffer "x中v"
    (should-not evil-pinyin-scheme)
    (should (eq evil-pinyin-with-search-rule 'never))
    (should-not evil-pinyin-with-punctuation)
    (should (equal (evil-ex-pattern-regex
                    (evil-ex-make-search-pattern "v")) "v"))
    (should (equal (evil-ex-pattern-regex
                    (evil-ex-make-search-pattern ":v")) ":v"))
    (init-evil-pinyin-test--keys "fv" 2)))

(ert-deftest init-evil-pinyin-search-keys-stay-literal ()
  "The existing / and ? commands still search ASCII literally."
  (init-evil-pinyin-test--with-buffer "a中v找v"
    (init-evil-pinyin-test--keys "/ v RET" 3)
    (goto-char 5)
    (init-evil-pinyin-test--keys "? v RET" 3)))

(provide 'init-evil-pinyin-test)
;;; init-evil-pinyin-test.el ends here
