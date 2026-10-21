;;; agent-claude.el --- Claude daemon registration -*- lexical-binding: t; -*-

;;; Commentary:
;; Execution and policy live in emx/backends/claude.ts and emx/config.json.
;; This module is loaded only when claude is enabled in `my/agents'.

;;; Code:
(require 'agent-emx)

(agent-session-define-agent claude :title "Claude" :backend emx
  :executable "claude" :emx-agent "claude")

(provide 'agent-claude)
;;; agent-claude.el ends here
