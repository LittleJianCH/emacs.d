;;; agent-codex.el --- Codex daemon registration -*- lexical-binding: t; -*-

;;; Commentary:
;; Execution and policy live in emx/backends/codex.ts and emx/config.json.
;; This module is loaded only when codex is enabled in `my/agents'.

;;; Code:
(require 'agent-emx)

(agent-session-define-agent codex :title "Codex" :backend emx
  :executable "codex" :emx-agent "codex")

(provide 'agent-codex)
;;; agent-codex.el ends here
