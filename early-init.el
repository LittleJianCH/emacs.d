;;; early-init.el --- 首帧之前的设置 -*- lexical-binding: t; -*-

;; 启动期间放宽 GC，启动完成后在 init.el 中恢复。
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

;; 插件统一在 init.el 中初始化。
(setq package-enable-at-startup nil)

;; 原生编译的警告不弹窗，只记录到 *Warnings*。
(setq native-comp-async-report-warnings-errors 'silent)

;; 首帧创建前关闭多余控件，避免闪烁。
(setq frame-inhibit-implied-resize t
      frame-resize-pixelwise t)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars . nil) default-frame-alist)
(push '(internal-border-width . 8) default-frame-alist)
(push '(width . 200) default-frame-alist)
(push '(height . 55) default-frame-alist)
(when (eq system-type 'darwin)
  (push '(ns-transparent-titlebar . t) default-frame-alist))

;;; early-init.el ends here
