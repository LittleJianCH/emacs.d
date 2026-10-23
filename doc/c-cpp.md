# C/C++

`lang-c` 在首次打开 C/C++ 文件时加载，无需安装额外的 Emacs 包。
已有 tree-sitter 语法时使用 `c-ts-mode` / `c++-ts-mode`；否则回退到
内置的 CC Mode。项目的缩进设置仍可通过 `.dir-locals.el` 定制。

`.c` 使用 C 模式，`.cc`、`.cpp`、`.cxx`、`.C` 等使用 C++ 模式；
`.h` 沿用 Emacs 的内容检测来区分 C 和 C++。常见 C++ 头文件、模板实现
和模块扩展名也会触发加载。
文件头的 `mode: c` / `mode: c++` 声明及直接调用原生模式也会加载模块。

## 语言服务器

补全、诊断、定义跳转、重命名和代码操作由 Eglot + clangd 提供，
沿用配置现有的 Corfu、Flymake 和 Eldoc 界面。请自行安装 clangd，
也可以由项目的 direnv/Nix 环境提供。缺少 clangd 时仍可编辑源码。

clangd 在项目环境就绪后才启动。服务器命令通过 `my/clangd-command`
定制，默认是 `("clangd" "--background-index")`；未强制设置格式风格，
clangd 会读取项目的 `.clang-format`。连接后保存时自动格式化。
远程文件会在所属主机上查找 clangd，无需在本机重复安装。

## 项目配置

clangd 需要正确的编译参数，才能识别头文件路径、宏和语言标准。
它会查找项目的 `compile_commands.json`；找不到时使用后备参数，
复杂项目可能因此显示错误诊断。

CMake 项目可在配置构建目录时导出编译数据库：

```sh
cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

clangd 会搜索父目录及名为 `build` 的子目录。其他构建目录可通过项目
根目录的 `.clangd` 指定：

```yaml
CompileFlags:
  CompilationDatabase: out/debug
```

现有 Make 项目可用 Bear 在执行构建时采集数据库。配置不会修改项目的
构建系统，也不会自动下载工具链。

## 常用操作

| 按键 | 操作 |
| --- | --- |
| `C-c b` | 使用 `project-compile` 在项目中构建 |
| `C-c k` | 重复上次构建 |
| `C-c o` | 切换源文件 / 头文件 |
| `C-c l f` | Eglot 格式化 |
| `C-c l a` | Eglot 代码操作 |
| `C-c l r` | Eglot 重命名 |
| `M-.`、`M-,` | 跳转定义 / 返回 |
| `M-g n`、`M-g p` | 下一处 / 上一处诊断 |

开启 Evil 时，`SPC m` 另有语言操作入口；原生 Emacs 按键仍可使用。
具体绑定见 `my/c-command-map`。CC Mode 原有的 `C-c C-c` 注释、
`C-c C-k` 注释风格和 `C-c C-o` 缩进调整等按键保持不变。

测试位于 `test/lang-c-test.el`，模拟服务器和工具链，不启动真实 clangd。

参考：[clangd 入门](https://clangd.llvm.org/installation)、
[clangd 项目配置](https://clangd.llvm.org/config.html)。
