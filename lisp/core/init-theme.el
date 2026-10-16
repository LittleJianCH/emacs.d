;;; init-theme.el --- Nano-style light and dark themes -*- lexical-binding: t; -*-

;;; Commentary:

;; Two themes, `my-nano-light' and `my-nano-dark', built from one face table
;; after Nicolas Rougier's N Λ N O Emacs (https://github.com/rougier/nano-emacs).
;; Few faces, each with one role:
;;
;;   strong    structure: titles, names, definitions (bold)
;;   salient   important, same weight as text, another hue: keywords, links
;;   popout    asks for attention: strings, warnings, search matches
;;   critical  needs action now: errors
;;   faded     secondary: comments, metadata, inactive things
;;   dim       weakest text still meant to be read: line numbers, markup
;;   subtle    a physical area: bands, buttons, code blocks (background only)
;;
;; Nano's light palette (Material Blue Grey) and dark one (Nord) are kept, but
;; its faded and popout colors are darkened for text: as foregrounds they fall
;; under 2:1 against white.  The light tints remain as backgrounds.  Strong
;; is bold rather than nano's light/medium pair, which needs a font with those
;; weights (Menlo, the fallback, has regular and bold only).
;;
;; The themes follow the macOS appearance (emacs-plus).
;;
;; Credits
;;
;; This look is modeled on N Λ N O Emacs ("Emacs made simple") by Nicolas
;; P. Rougier and the N Λ N O developers, https://github.com/rougier/nano-emacs,
;; licensed GPL-3.0-or-later, and on the ideas of Rougier's "On the design of
;; text editors" (https://arxiv.org/abs/2008.06030).  From it come the
;; semantic face roles above, the two palettes (which nano takes from Material
;; Design, https://material.io/, and Nord, https://www.nordtheme.com/), the
;; wide margins and the status line with a state tag (see init-ui.el).  No
;; nano code is copied; the faces and layout are reimplemented here for this
;; configuration and its agent UI.  Thank you.

;;; Code:

(require 'map)

(defconst my/nano-palettes
  '((light
     :bg "#FFFFFF" :fg "#37474F" :strong "#263238"
     :faded "#6E828C" :dim "#8496A0" :faint "#B0BEC5"
     :subtle "#ECEFF1" :highlight "#F5F7F8" :sidebar "#F7F9FA"
     :salient "#673AB7" :salient-bg "#EDE7F6" :tag-fg "#FFFFFF"
     :popout "#C2552F" :popout-bg "#FFAB91" :popout-soft "#FBE9E7"
     :on-popout "#263238" :flash "#FFD9CC"
     :accent "#673AB7" :on-accent "#FFFFFF" :on-accent-dim "#D1C4E9"
     :critical "#C62828" :green "#2E7D32"
     :added "#E8F5E9" :added-refine "#C8E6C9"
     :removed "#FFEBEE" :removed-refine "#FFCDD2" :changed "#FFF8E1")
    (dark
     :bg "#2E3440" :fg "#D8DEE9" :strong "#ECEFF4"
     :faded "#939DB2" :dim "#7A869C" :faint "#4C566A"
     :subtle "#3B4252" :highlight "#343A47" :sidebar "#2A2F3A"
     :salient "#81A1C1" :salient-bg "#3B4A61" :tag-fg "#2E3440"
     :popout "#D08770" :popout-bg "#D08770" :popout-soft "#4A3F3F"
     :on-popout "#2E3440" :flash "#6B4438"
     :accent "#B48EAD" :on-accent "#242933" :on-accent-dim "#3B4252"
     :critical "#E08A92" :green "#A3BE8C"
     :added "#384539" :added-refine "#4B6150"
     :removed "#4A3439" :removed-refine "#6A4550" :changed "#48463A"))
  "Colors of the nano themes, by variant.")

(defface my/nano-sidebar '((t :inherit default))
  "Background of side panels: the session list and review navigation."
  :group 'faces)

(defface my/nano-tag '((t :inherit (bold mode-line-active)))
  "Status tag at the start of the active mode line."
  :group 'faces)

(defface my/nano-on-accent-dim '((t :inherit shadow))
  "Secondary text on the accent band of the selected window's mode line."
  :group 'faces)

(defface my/nano-tag-inactive '((t :inherit mode-line-inactive))
  "Status tag at the start of an inactive mode line."
  :group 'faces)

(defface my/nano-tag-modified '((t :inherit my/nano-tag))
  "Status tag of a modified buffer."
  :group 'faces)

(defface my/nano-tag-read-only '((t :inherit my/nano-tag))
  "Status tag of a read-only buffer."
  :group 'faces)

(defun my/nano-face-specs (palette)
  "Face specs of the theme with PALETTE, for `custom-theme-set-faces'."
  (pcase-let (((map :bg :fg :strong :faded :dim :faint :subtle :highlight :sidebar
                    :salient :salient-bg :tag-fg :popout :popout-bg :popout-soft
                    :on-popout :flash :accent :on-accent :on-accent-dim
                    :critical :green :added :added-refine
                    :removed :removed-refine :changed)
               palette))
    (let ((pill '(:line-width (6 . 2) :style flat-button))
          (tag (lambda (bg fg) `(:background ,bg :foreground ,fg :weight bold
                                 :box (:line-width (6 . 1) :color ,bg)))))
      (mapcar
       (lambda (spec) `(,(car spec) ((t ,@(cdr spec)))))
       `(;; Basics
         (default :background ,bg :foreground ,fg)
         (cursor :background ,salient)
         (region :background ,salient-bg :extend t)
         (secondary-selection :background ,subtle :extend t)
         (highlight :background ,salient-bg)
         (hl-line :background ,highlight :extend t)
         (fringe :background ,bg :foreground ,dim)
         (shadow :foreground ,faded)
         (link :foreground ,salient :underline t)
         (link-visited :foreground ,salient :underline t)
         (button :foreground ,salient :underline t)
         (success :foreground ,green)
         (warning :foreground ,popout)
         (error :foreground ,critical :weight bold)
         (match :background ,popout-soft :foreground ,strong)
         (minibuffer-prompt :foreground ,salient :weight bold)
         (escape-glyph :foreground ,salient)
         (homoglyph :foreground ,salient)
         (nobreak-space :foreground ,faded :underline t)
         (trailing-whitespace :background ,popout-soft)
         (help-key-binding :foreground ,salient :background ,highlight
                           :box (:line-width (2 . -1) :color ,subtle))
         (tooltip :background ,subtle :foreground ,fg)
         (fill-column-indicator :foreground ,subtle)
         ;; Windows are separated by space, as in nano: invisible dividers.
         (vertical-border :foreground ,bg)
         (window-divider :foreground ,bg)
         (window-divider-first-pixel :foreground ,bg)
         (window-divider-last-pixel :foreground ,bg)
         (internal-border :background ,bg)
         (child-frame-border :background ,faint)
         (line-number :foreground ,dim)
         (line-number-current-line :foreground ,strong :weight bold)
         (line-number-major-tick :foreground ,faded)
         (line-number-minor-tick :foreground ,dim)
         (show-paren-match :foreground ,salient :background ,salient-bg :weight bold)
         (show-paren-mismatch :foreground ,tag-fg :background ,critical)
         (isearch :foreground ,on-popout :background ,popout-bg :weight bold)
         (isearch-fail :foreground ,critical :background ,popout-soft)
         (lazy-highlight :foreground ,strong :background ,popout-soft)
         (completions-common-part :foreground ,salient :weight bold)
         (completions-first-difference :foreground ,strong :weight bold)
         (completions-annotations :foreground ,faded)

         ;; Mode line: a band with room above and below the text.  The
         ;; selected window's band is the accent color, so it is clear where
         ;; the cursor is; the others are a quiet grey.
         (mode-line :background ,accent :foreground ,on-accent
                    :box (:line-width (1 . 6) :color ,accent))
         (mode-line-active :inherit mode-line)
         (mode-line-inactive :background ,highlight :foreground ,faded
                             :box (:line-width (1 . 6) :color ,highlight))
         (mode-line-emphasis :foreground ,on-accent :weight bold)
         (mode-line-buffer-id :foreground ,on-accent :weight bold)
         (mode-line-highlight :background ,on-accent-dim :foreground ,strong)
         (my/nano-on-accent-dim :foreground ,on-accent-dim)
         (my/nano-tag ,@(funcall tag on-accent accent))
         (my/nano-tag-modified ,@(funcall tag popout-bg on-popout))
         (my/nano-tag-read-only ,@(funcall tag on-accent-dim strong))
         (my/nano-tag-inactive :background ,subtle :foreground ,faded
                               :box (:line-width (6 . 1) :color ,subtle))
         ;; Header line: the toolbar of review and session-list buffers.
         (header-line :background ,highlight :foreground ,fg
                      :box (:line-width (1 . 5) :color ,highlight))
         (header-line-active :inherit header-line)
         (header-line-inactive :inherit header-line :foreground ,faded)
         (header-line-highlight :foreground ,salient)
         (my/nano-sidebar :background ,sidebar :extend t)
         (tab-bar :background ,highlight :foreground ,faded)
         (tab-bar-tab :background ,bg :foreground ,strong :weight bold
                      :box (:line-width (8 . 4) :color ,bg))
         (tab-bar-tab-inactive :background ,highlight :foreground ,faded
                               :box (:line-width (8 . 4) :color ,highlight))
         (tab-line :background ,highlight :foreground ,faded)

         ;; Code: nano's restraint, hue only for keywords and strings.
         (font-lock-comment-face :foreground ,faded :slant italic)
         (font-lock-comment-delimiter-face :foreground ,faded :slant italic)
         (font-lock-doc-face :foreground ,faded :slant italic)
         (font-lock-doc-markup-face :foreground ,salient)
         (font-lock-string-face :foreground ,popout)
         (font-lock-regexp-face :foreground ,popout)
         (font-lock-regexp-grouping-backslash :foreground ,salient :weight bold)
         (font-lock-regexp-grouping-construct :foreground ,salient :weight bold)
         (font-lock-escape-face :foreground ,salient)
         (font-lock-constant-face :foreground ,salient)
         (font-lock-number-face :foreground ,salient)
         (font-lock-builtin-face :foreground ,salient)
         (font-lock-keyword-face :foreground ,salient)
         (font-lock-type-face :foreground ,salient)
         (font-lock-preprocessor-face :foreground ,salient)
         (font-lock-negation-char-face :foreground ,popout)
         (font-lock-warning-face :foreground ,popout :weight bold)
         (font-lock-function-name-face :foreground ,strong :weight bold)
         (font-lock-function-call-face :foreground ,strong)
         (font-lock-variable-name-face :foreground ,strong)
         (font-lock-variable-use-face :foreground ,fg)
         (font-lock-property-name-face :foreground ,fg)
         (font-lock-property-use-face :foreground ,fg)

         ;; Outlines: headings in org, outline and agent pages.
         (outline-1 :foreground ,strong :weight bold)
         (outline-2 :foreground ,strong :weight bold)
         (outline-3 :foreground ,strong :weight bold)
         (outline-4 :foreground ,fg :weight bold)
         (outline-5 :foreground ,fg :weight bold)
         (outline-6 :foreground ,fg :weight bold)

         ;; Completion: vertico, orderless, marginalia, consult, corfu
         (vertico-current :background ,salient-bg :foreground ,strong :extend t)
         (vertico-group-title :foreground ,faded :slant italic)
         (vertico-group-separator :foreground ,faint :strike-through t)
         (orderless-match-face-0 :foreground ,salient :weight bold)
         (orderless-match-face-1 :foreground ,popout :weight bold)
         (orderless-match-face-2 :foreground ,green :weight bold)
         (orderless-match-face-3 :foreground ,strong :weight bold :underline t)
         (marginalia-documentation :foreground ,faded :slant italic)
         (consult-preview-line :background ,highlight :extend t)
         (consult-highlight-match :foreground ,strong :background ,popout-soft)
         (corfu-default :background ,highlight :foreground ,fg)
         (corfu-current :background ,salient-bg :foreground ,strong)
         (corfu-border :background ,faint)
         (corfu-bar :background ,faded)
         (corfu-annotations :foreground ,faded)
         (corfu-deprecated :foreground ,faded :strike-through t)
         (corfu-popupinfo :background ,highlight :foreground ,fg)
         (which-key-key-face :foreground ,salient :weight bold)
         (which-key-separator-face :foreground ,dim)
         (which-key-command-description-face :foreground ,fg)
         (which-key-group-description-face :foreground ,popout)
         (which-key-local-map-description-face :foreground ,strong)

         ;; Diffs: tinted backgrounds, text keeps its own colors.
         (diff-header :background ,subtle :foreground ,fg :extend t)
         (diff-file-header :background ,subtle :foreground ,strong :weight bold :extend t)
         (diff-hunk-header :background ,highlight :foreground ,faded :extend t)
         (diff-context :foreground ,fg)
         (diff-added :background ,added :extend t)
         (diff-removed :background ,removed :extend t)
         (diff-changed :background ,changed :extend t)
         (diff-refine-added :background ,added-refine)
         (diff-refine-removed :background ,removed-refine)
         (diff-refine-changed :background ,changed)
         (diff-indicator-added :foreground ,green :background ,added)
         (diff-indicator-removed :foreground ,critical :background ,removed)
         (diff-indicator-changed :foreground ,popout :background ,changed)
         (diff-hl-insert :foreground ,green :background ,added)
         (diff-hl-delete :foreground ,critical :background ,removed)
         (diff-hl-change :foreground ,popout :background ,changed)
         (smerge-upper :background ,removed :extend t)
         (smerge-lower :background ,added :extend t)
         (smerge-base :background ,changed :extend t)
         (smerge-markers :background ,subtle :foreground ,faded :extend t)
         (smerge-refined-added :background ,added-refine)
         (smerge-refined-removed :background ,removed-refine)

         ;; Magit
         (magit-section-heading :foreground ,strong :weight bold)
         (magit-section-highlight :background ,highlight :extend t)
         (magit-section-heading-selection :foreground ,salient)
         (magit-branch-local :foreground ,salient)
         (magit-branch-remote :foreground ,green)
         (magit-branch-current :foreground ,salient :weight bold
                               :box (:line-width (2 . -1) :color ,salient))
         (magit-head :foreground ,salient :weight bold)
         (magit-tag :foreground ,popout)
         (magit-hash :foreground ,faded)
         (magit-dimmed :foreground ,faded)
         (magit-log-author :foreground ,fg)
         (magit-log-date :foreground ,faded)
         (magit-log-graph :foreground ,faded)
         (magit-filename :foreground ,fg)
         (magit-diff-file-heading :foreground ,strong :weight bold :extend t)
         (magit-diff-file-heading-highlight :background ,highlight :foreground ,strong
                                            :weight bold :extend t)
         (magit-diff-hunk-heading :background ,subtle :foreground ,faded :extend t)
         (magit-diff-hunk-heading-highlight :background ,subtle :foreground ,strong
                                            :extend t)
         (magit-diff-context :foreground ,faded :extend t)
         (magit-diff-context-highlight :background ,highlight :foreground ,fg :extend t)
         (magit-diff-added :background ,added :foreground ,fg :extend t)
         (magit-diff-added-highlight :background ,added :foreground ,strong :extend t)
         (magit-diff-removed :background ,removed :foreground ,fg :extend t)
         (magit-diff-removed-highlight :background ,removed :foreground ,strong :extend t)
         (magit-diffstat-added :foreground ,green)
         (magit-diffstat-removed :foreground ,critical)
         (magit-process-ok :foreground ,green :weight bold)
         (magit-process-ng :foreground ,critical :weight bold)

         ;; Diagnostics and language servers
         (flymake-error :underline (:style wave :color ,critical))
         (flymake-warning :underline (:style wave :color ,popout))
         (flymake-note :underline (:style wave :color ,salient))
         (compilation-error :foreground ,critical :weight bold)
         (compilation-warning :foreground ,popout :weight bold)
         (compilation-info :foreground ,green)
         (compilation-line-number :foreground ,faded)
         (compilation-mode-line-fail :foreground ,critical :weight bold)
         (compilation-mode-line-exit :foreground ,green :weight bold)
         (eglot-highlight-symbol-face :background ,subtle :weight bold)
         (eglot-inlay-hint-face :foreground ,dim :height 0.9)
         (eldoc-highlight-function-argument :foreground ,salient :weight bold)
         ;; eldoc-box popups: a card in the band color; its border is padding.
         (eldoc-box-body :background ,subtle :foreground ,fg)
         (eldoc-box-border :background ,subtle)
         (eldoc-box-markdown-separator :strike-through ,faint :extend t :height 0.4)
         (xref-file-header :foreground ,strong :weight bold)
         (xref-line-number :foreground ,faded)
         (xref-match :foreground ,strong :background ,popout-soft)

         ;; Dired, info, customize
         (dired-directory :foreground ,salient :weight bold)
         (dired-header :foreground ,strong :weight bold)
         (dired-symlink :foreground ,salient :slant italic)
         (dired-ignored :foreground ,faded)
         (dired-flagged :foreground ,critical :weight bold)
         (dired-marked :foreground ,popout :weight bold)
         (info-title-1 :foreground ,strong :weight bold :height 1.3)
         (info-title-2 :foreground ,strong :weight bold :height 1.2)
         (info-title-3 :foreground ,strong :weight bold :height 1.1)
         (info-menu-star :foreground ,popout)
         (custom-variable-tag :foreground ,salient :weight bold)
         (custom-group-tag :foreground ,strong :weight bold :height 1.2)
         (custom-state :foreground ,green)
         (widget-field :background ,subtle :extend t)
         (custom-button :background ,subtle :foreground ,strong :box ,pill)
         (custom-button-mouse :background ,salient-bg :foreground ,strong :box ,pill)
         (custom-button-pressed :background ,salient :foreground ,tag-fg :box ,pill)

         ;; Markdown: agent transcripts are rendered with it.
         (markdown-header-face :foreground ,strong :weight bold)
         (markdown-header-face-1 :foreground ,strong :weight bold :height 1.2)
         (markdown-header-face-2 :foreground ,strong :weight bold :height 1.1)
         (markdown-header-face-3 :foreground ,strong :weight bold)
         (markdown-header-delimiter-face :foreground ,dim)
         (markdown-markup-face :foreground ,faded)
         (markdown-bold-face :foreground ,strong :weight bold)
         (markdown-italic-face :slant italic)
         (markdown-inline-code-face :foreground ,popout :background ,highlight)
         (markdown-code-face :background ,highlight :extend t)
         (markdown-pre-face :foreground ,fg)
         (markdown-language-keyword-face :foreground ,faded)
         (markdown-link-face :foreground ,salient)
         (markdown-url-face :foreground ,faded :underline t)
         (markdown-blockquote-face :foreground ,faded :slant italic)
         (markdown-list-face :foreground ,salient)
         (markdown-table-face :foreground ,fg)
         (markdown-hr-face :foreground ,dim)

         ;; Org
         (org-document-title :foreground ,strong :weight bold :height 1.4)
         (org-document-info :foreground ,faded)
         (org-level-1 :foreground ,strong :weight bold :height 1.15)
         (org-level-2 :foreground ,strong :weight bold)
         (org-level-3 :foreground ,strong :weight bold)
         (org-level-4 :foreground ,fg :weight bold)
         (org-block :background ,highlight :extend t)
         (org-block-begin-line :foreground ,faded :background ,highlight :extend t)
         (org-block-end-line :foreground ,faded :background ,highlight :extend t)
         (org-code :foreground ,popout)
         (org-verbatim :foreground ,salient)
         (org-meta-line :foreground ,faded)
         (org-date :foreground ,faded :underline t)
         (org-todo :foreground ,popout :weight bold)
         (org-done :foreground ,faded :weight bold)
         (org-headline-done :foreground ,faded)
         (org-tag :foreground ,faded :weight normal)
         (org-table :foreground ,fg)
         (org-link :foreground ,salient :underline t)

         ;; Agent sessions.  Theme specs replace the defface ones, so these keep
         ;; the structural attributes (boxes, extend, heights) of the originals.
         (agent-session-user :foreground ,salient :weight bold)
         (agent-session-assistant :foreground ,strong :weight bold)
         (agent-session-thinking :foreground ,faded :slant italic)
         (agent-session-tool :foreground ,faded)
         (agent-session-dim :foreground ,faded)
         (agent-session-ok :foreground ,green)
         (agent-session-error :foreground ,critical)
         (agent-session-ask :foreground ,popout :weight bold)
         (agent-session-button :background ,subtle :foreground ,strong :weight bold
                               :box (:line-width (6 . 2) :style flat-button))
         (agent-session-separator :foreground ,faded
                                  :underline (:color ,faint :position t))
         (agent-session-prompt :foreground ,salient :weight bold)
         (agent-session-run-button :foreground ,salient :underline nil)
         (agent-session-list-heading :foreground ,faded :weight bold)
         (agent-session-list-title :foreground ,strong :weight bold)
         (agent-session-list-alert :background ,popout-soft :extend t)
         (agent-session-list-alert-flash :background ,flash :extend t)
         (agent-canvas-title :foreground ,strong :weight bold :height 1.5)
         (agent-canvas-h1 :foreground ,strong :weight bold :height 1.3)
         (agent-canvas-h2 :foreground ,strong :weight bold :height 1.15)
         (agent-canvas-h3 :foreground ,strong :weight bold)
         (agent-canvas-meta :foreground ,faded)
         (agent-canvas-code :foreground ,popout)
         (agent-canvas-button :background ,subtle :foreground ,strong :weight bold
                              :box (:line-width (6 . 3) :style flat-button))
         (agent-review-comment :foreground ,popout)
         (agent-review-response :foreground ,faded :slant italic)
         (agent-review-brand :foreground ,salient :weight bold :height 1.1))))))

(defun my/nano-define-themes ()
  "Define `my-nano-light' and `my-nano-dark' from `my/nano-palettes'.
Redefining replaces their old settings; enable one afterwards with
`my/nano-apply-theme'."
  (dolist (variant '(light dark))
    (let ((theme (intern (format "my-nano-%s" variant))))
      (custom-declare-theme theme (custom-make-theme-feature theme)
                            (format "Nano-style %s theme, after rougier/nano-emacs." variant))
      ;; Settings pushed onto a theme that is not enabled are added next to
      ;; the old ones instead of replacing them, so the stale specs would
      ;; still apply: start from an empty, disabled theme.
      (when (custom-theme-enabled-p theme)
        (disable-theme theme))
      (put theme 'theme-settings nil)
      (apply #'custom-theme-set-faces theme
             (my/nano-face-specs (alist-get variant my/nano-palettes))))))

(my/nano-define-themes)

(defun my/nano-apply-theme (&optional appearance)
  "Enable the nano theme matching APPEARANCE, `light' or `dark'.
Default to the system appearance.  Other themes are disabled first, so
reloading never stacks themes."
  (let* ((appearance (if (eq (or appearance (bound-and-true-p ns-system-appearance))
                             'dark)
                         'dark
                       'light))
         (theme (intern (format "my-nano-%s" appearance))))
    (mapc #'disable-theme custom-enabled-themes)
    (setq frame-background-mode appearance)
    (enable-theme theme)
    (mapc #'frame-set-background-mode (frame-list))
    ;; The transparent title bar draws its text in the appearance's color.
    (setf (alist-get 'ns-appearance default-frame-alist) appearance)
    (dolist (frame (frame-list))
      (unless (frame-parent frame)
        (set-frame-parameter frame 'ns-appearance appearance)))))

(my/nano-apply-theme)
;; emacs-plus only: follow the system when it switches light / dark.
(when (boundp 'ns-system-appearance-change-functions)
  (add-hook 'ns-system-appearance-change-functions #'my/nano-apply-theme))

(provide 'init-theme)
;;; init-theme.el ends here
