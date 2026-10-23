# Haskell、Coq 和 Lean 4

这三个模块已加入 `my/languages`，在首次打开对应文件时才加载并安装
Emacs 包。编译器和语言服务器需另行安装，也可以由项目的 direnv/Nix
环境提供。配置不会自动安装系统工具链。

C/C++ 也已启用，详见 [C/C++ 配置](c-cpp.md)。配置更新会注册已启用语言
的懒加载入口；自定义的 `my/languages` 选择会保留。

| 语言 | 文件 | Emacs 集成 | 外部工具 |
| --- | --- | --- | --- |
| Haskell | `.hs`、`.lhs`、`.cabal` | haskell-mode、GHCi、Eglot | GHC；补全和诊断需要 HLS |
| Coq | `.v` | Proof General、证明目标与响应窗口 | Coq / Rocq 的兼容工具链 |
| Lean 4 | `.lean` | lean4-mode、目标窗口、Unicode 输入 | elan 提供的 Lean 4 / Lake |

Haskell 和 Lean 的语言服务器会等待项目环境加载完成。缺少服务器时仍可
编辑源码；安装工具或允许项目环境后，可用 `C-c E r` 刷新环境。

## Haskell

`C-c C-l` 将文件加载到 GHCi，`C-c C-z` 切换到交互窗口，`C-c C-t`
查询类型。GHCi 只在使用交互命令时启动。

HLS 提供补全、诊断、定义跳转、代码操作和保存时格式化。服务器命令可通过
`my/haskell-server-command` 定制，默认是
`("haskell-language-server-wrapper" "--lsp")`。项目设置沿用
`eglot-workspace-configuration`，Cabal 文件使用专门的编辑模式。

Evil 的 `SPC m` 下，`l` 加载、`r` 重载、`z` 打开 GHCi、`t` 查询类型、
`i` 查询信息、`b` 构建。

## Coq

`.v` 文件使用 Proof General，可逐句推进、撤回或处理到光标处，并显示当前
证明目标。编辑文件不会立即启动证明进程；首次执行证明命令时才启动。
Coq 使用 Proof General 的协议，不启动 Eglot。

Evil 的 `SPC m` 下，`n` 推进、`u` 撤回一步、`p` 处理到光标、`b` 处理
整个文件、`r` 撤回整个文件、`R` 重启证明器、`q` 退出证明器。原生的
`C-c C-n`、`C-c C-u`、`C-c C-RET` 等 Proof General 键位保持可用。

## Lean 4

Lean 模块通过 Emacs 自带的 `package-vc` 安装
[lean4-mode](https://github.com/leanprover-community/lean4-mode)，包括 Unicode
输入所需的 `data/` 目录。首次安装需要连接 GitHub 和包仓库。

Lean 的目标窗口依赖该模式自带的 lsp-mode 集成，补全接入 Corfu，诊断接入
Flymake。其他语言仍使用各自的客户端。

`C-c C-i` 切换目标窗口，`C-c C-d` 刷新导入，`C-c C-p C-l` 用 Lake
构建，`C-c C-l` 运行当前文件。Unicode 输入沿用模式的反斜线缩写。

Evil 的 `SPC m` 下，`i` 切换目标、`d` 刷新导入、`b` 构建、`l` 运行、
`r` 重启语言服务器。

若工具链不在 PATH 中，可用 `lean4-rootdir` 指向包含 `bin/lean` 的安装目录。
自动探测的工具链路径不会缓存到其他项目。

## 验证

自动化测试使用模拟工具，不启动真实的 GHC/HLS、Coq 或 Lean 进程。
运行方法见 `AGENTS.md`；本次新增的测试是 `test/lang-functional-test.el`
和 `test/lang-coq-test.el`。真实工具链的交互体验仍需在实际项目中验证。

上游说明：[HLS 配置](https://haskell-language-server.readthedocs.io/en/latest/configuration.html)、
[Proof General 安装](https://proofgeneral.github.io/download/)、
[Lean 4 模式](https://github.com/leanprover-community/lean4-mode)。
