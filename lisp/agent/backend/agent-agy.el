;;; agent-agy.el --- Antigravity daemon registration -*- lexical-binding: t; -*-

;;; Commentary:
;; Execution and policy live in emx/backends/agy.ts and emx/config.json.
;; This module is loaded only when agy is enabled in `my/agents'.

;;; Code:
(require 'agent-emx)

(agent-session-define-agent agy :title "Antigravity" :backend emx
  :executable "agy" :emx-agent "agy")

(provide 'agent-agy)
;;; agent-agy.el ends here
