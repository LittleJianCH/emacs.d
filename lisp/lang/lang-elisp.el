;;; lang-elisp.el --- Emacs Lisp 开发环境 -*- lexical-binding: t; -*-

;;; Commentary:

;; emacs-lisp-mode 中的按键：
;;   C-c C-b  eval-buffer
;;   C-c C-e  对上一个表达式求值并美化输出
;;   C-c C-m  展开光标处的宏（macrostep，q 退出）
;;   C-c C-z  打开 IELM
;; C-h f / v / k / x 换成 helpful，显示源码与引用。

;;; Code:

(defun my/elisp-setup ()
  "elisp buffer 的通用设置。"
  ;; 字节编译检查需要能找到本配置的模块。
  (setq-local elisp-flymake-byte-compile-load-path (cons "./" load-path))
  (when buffer-file-name
    (flymake-mode 1)))

(use-package elisp-mode
  :hook ((emacs-lisp-mode . my/elisp-setup))
  :bind (:map emacs-lisp-mode-map
         ("C-c C-b" . eval-buffer)
         ("C-c C-e" . pp-eval-last-sexp)
         ("C-c C-z" . ielm)
         :map lisp-interaction-mode-map
         ("C-c C-e" . pp-eval-last-sexp)))

(use-package macrostep
  :ensure t
  :bind (:map emacs-lisp-mode-map
         ("C-c C-m" . macrostep-expand)))

(use-package helpful
  :ensure t
  :bind (("C-h f" . helpful-callable)
         ("C-h v" . helpful-variable)
         ("C-h k" . helpful-key)
         ("C-h x" . helpful-command)
         :map emacs-lisp-mode-map
         ("C-c C-d" . helpful-at-point)))

(provide 'lang-elisp)
;;; lang-elisp.el ends here
