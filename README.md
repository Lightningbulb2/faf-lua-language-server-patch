# FA Lua Language Server — Patches

This package contains the FA-specific patches applied to
[LuaLS](https://github.com/LuaLS/lua-language-server) v3.18.2
to support Supreme Commander: Forged Alliance development.

---

## What's in this package

```
script/
  brave/brave.lua            Platform-aware event loop (bee.select on Windows, bee.epoll on Linux)
  brave/work.lua             Compile options type annotation (adds exportEnvDefault field)
  config/template.lua        Three new config keys: exportEnvDefault, disableScheme, supportScheme
  core/folding.lua           --#region / -- #region folding support
  core/highlight.lua         --#region / -- #region document highlight support
  files.lua                  Passes exportEnvDefault from config into the parser
  parser/compile.lua         exportEnvDefault parser integration; export flag on globals
  parser/guide.lua           isExportEnv(state) function
  provider/diagnostic.lua    disableScheme filtering
  provider/provider.lua      supportScheme filtering on didOpen / didChange

locale/en-us/setting.lua     English descriptions for the three new settings

patches/                     Unified diffs against unmodified LuaLS 3.18.2
  script_brave_brave.lua.patch
  script_brave_work.lua.patch
  script_config_template.lua.patch
  script_core_folding.lua.patch
  script_core_highlight.lua.patch
  script_files.lua.patch
  script_parser_compile.lua.patch
  script_parser_guide.lua.patch
  script_provider_diagnostic.lua.patch
  script_provider_provider.lua.patch
  locale_en-us_setting.lua.patch

win32-cross-compile.ninja    Pre-generated ninja file for Windows cross-compilation from Linux
```

---

## FA-Specific Features

### `---@export-env` / `---@declare-global` Directives

Controlled by `Lua.runtime.exportEnvDefault` (set to `true` automatically by the FA type
library's `config.lua`).

FA scripts define module-level globals that other files access through the environment
rather than explicit `require`. These directives control how the server treats globals
per-file:

| Directive | Effect |
|---|---|
| *(no directive, `exportEnvDefault = true`)* | All top-level globals treated as exported env symbols |
| `---@declare-global` | Opts this file **out** of export-env |
| `---@export-env` | Opts this file **in** when `exportEnvDefault = false` |
| `---@meta` | Marks file as type-declaration; disables export-env |

**Implementation:** `guide.lua` adds `isExportEnv(state)` which reads per-file comment
directives. `compile.lua` calls it once at parse start and sets `State.hasExportEnv`.
`compileExpAsAction` and the function-declaration handler in `parseAction` mark top-level
globals with `.export = true` when active. No AST nodes are added or re-typed.

### `--#region` / `-- #region` Code Folding

FA scripts use `--#region` (no space). The FA preprocessor plugin converts `#` to `--`,
so the comment text the folding provider sees is `--region` rather than `#region`.

`core/folding.lua` and `core/highlight.lua` both match all four variants:

| Input | Comment text after preprocessing | Matched by |
|---|---|---|
| `-- #region` | ` #region` | `#region` pattern |
| `--region` | `region` | `region` pattern |
| `--#region` | `--region` | `--region` pattern (FA-specific) |
| `-- #region` (space) | ` -- region` | `-- region` pattern (FA-specific) |

### `Lua.diagnostics.disableScheme`

Suppresses diagnostics on files matching certain URI schemes. Default: `['git']`.
Prevents errors appearing in VS Code's read-only git diff views.

### `Lua.workspace.supportScheme`

Restricts which URI schemes the server accepts for `didOpen` / `didChange`. Default:
`['file', 'untitled', 'git']`. Files with other schemes are silently ignored.

### Platform-Aware Event Loop (`brave.lua`)

The worker event loop uses `bee.epoll` on Linux/macOS and `bee.select` on Windows:

```lua
if platform.os == 'windows' then
    poller_lib = require 'bee.select'
    POLLIN     = poller_lib.SELECT_READ
else
    poller_lib = require 'bee.epoll'
    POLLIN     = poller_lib.EPOLLIN
end
```

Both modules share the same `create()` / `event_add(fd, flags)` / `wait()` API.
`bee.select.create()` takes no arguments; `bee.epoll.create(n)` takes a max-events hint.

---

## Building

### Prerequisites

| Tool | Notes |
|---|---|
| Git | For cloning and submodule init |
| GCC ≥ 11 | Linux native build |
| ninja ≥ 1.10 | `apt install ninja-build` |
| `x86_64-w64-mingw32-gcc` (posix) | Windows cross-compile only — `apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64` |

Switch mingw to the posix threading model (required for C++ exceptions):
```sh
update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix
```

### Step 1 — Clone LuaLS and init submodules

```sh
git clone --depth=1 https://github.com/LuaLS/lua-language-server
cd lua-language-server
git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel
```

### Step 2 — Apply patches

```sh
PATCHES=/path/to/this/package/patches

for p in "$PATCHES"/*.patch; do
    patch -p1 < "$p"
done
```

Or copy the full patched files directly (replacing the cloned versions):

```sh
SRC=/path/to/this/package
cp $SRC/script/brave/brave.lua            script/brave/brave.lua
cp $SRC/script/brave/work.lua             script/brave/work.lua
cp $SRC/script/config/template.lua        script/config/template.lua
cp $SRC/script/core/folding.lua           script/core/folding.lua
cp $SRC/script/core/highlight.lua         script/core/highlight.lua
cp $SRC/script/files.lua                  script/files.lua
cp $SRC/script/parser/compile.lua         script/parser/compile.lua
cp $SRC/script/parser/guide.lua           script/parser/guide.lua
cp $SRC/script/provider/diagnostic.lua    script/provider/diagnostic.lua
cp $SRC/script/provider/provider.lua      script/provider/provider.lua
cp $SRC/locale/en-us/setting.lua          locale/en-us/setting.lua
```

### Step 3 — Build luamake

```sh
cd 3rd/luamake
bash compile/build.sh
cd ../..
```

### Step 4 — Build the Linux binary

```sh
./3rd/luamake/luamake rebuild
```

This runs the full test suite. All tests must pass. Output: `bin/lua-language-server`

### Step 5 — Build the Windows binary (cross-compile from Linux)

```sh
# Create Windows.h case shims (Linux filesystem is case-sensitive)
mkdir -p build/win32-compat
echo '#include <windows.h>'  > build/win32-compat/Windows.h
echo '#include <dbghelp.h>'  > build/win32-compat/DbgHelp.h
echo '#include <ws2tcpip.h>' > build/win32-compat/Ws2tcpip.h
echo '#include <dbgeng.h>'   > build/win32-compat/DbgEng.h

# Create output directories
mkdir -p build/win32/{obj/{source_bee,source_lua,lua-language-server,lpeglabel,source_bootstrap,code_format},bin}

# Build
ninja -f /path/to/this/package/win32-cross-compile.ninja all
```

Output: `build/win32/bin/lua-language-server.exe`

The exe only depends on `libwinpthread-1.dll` at runtime (at
`/usr/x86_64-w64-mingw32/lib/libwinpthread-1.dll`). All other dependencies are
standard Windows system DLLs.

Verify with:
```sh
x86_64-w64-mingw32-objdump -p build/win32/bin/lua-language-server.exe | grep "DLL Name"
# KERNEL32.dll, VERSION.dll, WS2_32.dll, ntdll.dll, libwinpthread-1.dll, msvcrt.dll
```

---

## Critical: The `_ENV = nil` Constraint

`script/parser/compile.lua` sets `_ENV = nil` at line 19 to prevent accidental global
access. Every standard library function used in that file must be captured as a `local`
upvalue **before** that line. Calling an uncaptured name produces:

```
attempt to index a nil value (upvalue '_ENV')
```

at the call site — not at the definition. This is misleading. When adding new code to
`compile.lua`, check whether it uses `ipairs`, `pairs`, `type`, `pcall`, `error`,
`tostring`, or similar. If so, add them to the pre-capture block:

```lua
local assert     = assert
-- add your captures here, before _ENV = nil
_ENV = nil
```

---

## Updating to a New LuaLS Version

1. Clone the new tag and re-apply patches with `patch -p1`.
2. Check whether these functions were moved or renamed upstream:
   - `compileExpAsAction` in `compile.lua` — export flag injection point
   - Function name handler in `parseAction` in `compile.lua` — function export
   - `isValid` in `diagnostic.lua` — disableScheme injection point
   - `textDocument/didOpen` and `textDocument/didChange` in `provider.lua`
   - `comment.short` handler in `core/folding.lua` and `core/highlight.lua`
3. Run `./3rd/luamake/luamake rebuild` — all tests must pass.
4. Regenerate `win32-cross-compile.ninja` from the new `build/build.ninja` by applying
   the same source-file and linker-flag substitutions documented in the skill.
