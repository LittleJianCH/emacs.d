# Vendored pi-auto-permissions

Unmodified `index.ts`, `config.ts`, `gates.ts`, `review.ts`, `package.json` and
`LICENSE` of `@ogulcancelik/pi-auto-permissions` 0.1.4 (MIT, Can Celik),
from https://github.com/ogulcancelik/pi-extensions/tree/main/packages/pi-auto-permissions.

`../guardian.ts` loads it, and `../emacs-extension.js` runs its `tool_call`
handler only when the emx daemon answers `review`, that is for Bash in auto
mode.  The policy is
`../auto-permissions.json`, passed through `PI_AUTO_PERMISSIONS_CONFIG` by
`emx/backends/pi.ts`; its rules are the default rules of
`@hank-warren/pi-auto-permissions` 0.22.0 (MIT), with `deny` written as
`convention`.

Before upgrading, review the new source: it runs inside every Pi session emx
starts, with Pi's credentials.
