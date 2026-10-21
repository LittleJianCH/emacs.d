;;; agent-dsh.el --- DeepSeek daemon registration -*- lexical-binding: t; -*-

;;; Commentary:
;; Execution and policy live in emx/backends/dsh.ts and emx/config.json.
;; This module is loaded only when dsh is enabled in `my/agents'.

;;; Code:
(require 'agent-emx)

(agent-session-define-agent dsh :title "DeepSeek" :backend emx
  :executable "dsh" :emx-agent "dsh")

(provide 'agent-dsh)
;;; agent-dsh.el ends here
