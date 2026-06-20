# FA Lua Language Server — Build & Maintenance Skill

This skill covers building, patching, and maintaining the FA-specific patches to the
LuaLS language server for Supreme Commander: Forged Alliance development.

---

## Architecture Overview

```
lua-language-server/
  bin/lua-language-server[.exe]   Lua 5.5 VM + bee.lua C extensions, compiled binary
  bin/main.lua                    Bootstrap: loaded by the binary on startup
  script/                         ALL language server logic — pure Lua, loaded at runtime
  meta/3rd/fa/                    FA game engine type library
  3rd/bee.lua/                    C++ platform I/O library (submodule)
  3rd/luamake/                    Build system (submodule)
  3rd/EmmyLuaCodeStyle/           Code formatter (submodule)
  3rd/lpeglabel/                  PEG parser (submodule)
```

**Critical:** The binary is just a Lua VM. All language server logic is in `script/*.lua`,
loaded from disk at runtime. Patching `.lua` files does NOT require rebuilding the binary.
Only modify the C++ layer when you need new native symbols.

---

## FA Patch Files

| File | FA Change |
|---|---|
| `script/parser/compile.lua` | `hasExportEnv` flag; `.export = true` on top-level globals/functions |
| `script/parser/guide.lua` | `isExportEnv(state)` reads per-file `---@export-env` / `---@declare-global` |
| `script/brave/brave.lua` | Platform switch: `bee.select` (Windows) vs `bee.epoll` (Linux/macOS) |
| `script/brave/work.lua` | Adds `exportEnvDefault` field to compile options type annotation |
| `script/config/template.lua` | Registers `exportEnvDefault`, `disableScheme`, `supportScheme` config keys |
| `script/files.lua` | Passes `exportEnvDefault` from config to compiler options |
| `script/provider/diagnostic.lua` | `disableScheme` filtering in the diagnostic provider |
| `script/provider/provider.lua` | `supportScheme` guard on `didOpen` / `didChange` |
| `script/core/folding.lua` | Adds `--#region` / `-- #region` folding variants |
| `script/core/highlight.lua` | Adds `--#region` / `-- #region` to document highlight |
| `locale/en-us/setting.lua` | Descriptions for the three new settings |

---

## The `_ENV = nil` Constraint

`script/parser/compile.lua` sets `_ENV = nil` at line 19. This is intentional sandboxing.

**Rule:** Every standard library function used in `compile.lua` must be captured as a
`local` upvalue **before** line 19. Calling any uncaptured name at runtime produces:

```
attempt to index a nil value (upvalue '_ENV')
```

at the call site — not at the definition. The error is misleading because Lua resolves
unknown names through `_ENV`, which is `nil`.

**Currently captured before `_ENV = nil`:**
```lua
local sbyte, sfind, smatch, sgsub, ssub, schar, supper  -- string.*
local uchar      = utf8.char
local tconcat    = table.concat
local tinsert    = table.insert
local tointeger  = math.tointeger
local tonumber   = tonumber
local maxinteger = math.maxinteger
local assert     = assert
```

**When adding new code to `compile.lua`**, check if it uses any of:
`ipairs`, `pairs`, `type`, `pcall`, `xpcall`, `error`, `select`, `unpack`,
`rawget`, `rawset`, `setmetatable`, `getmetatable`, `next`, `tostring`.

If so, add them to the pre-capture block before `_ENV = nil`.

---

## exportEnvDefault Implementation

The export-env system marks top-level globals with `.export = true` on their AST nodes.
It does NOT inject fake return statements or re-tag node types — doing so breaks the
document symbol provider, semantic token engine, and causes 3–7 second hangs.

**Correct approach:**
1. `guide.isExportEnv(state)` checks per-file comment directives vs config default
2. `compile.lua` calls it once at parse start: `State.hasExportEnv = guide.isExportEnv(State)`
3. `compileExpAsAction` sets `.export = true` on `getglobal` nodes at top chunk level
4. Function declaration handler in `parseAction` sets `.export = true` on `setglobal` nodes

**Wrong approaches (have been tried, all broke things):**
- Re-tagging `exp.type = 'local'` — breaks symbol provider
- Injecting `return { ... }` nodes with `start = -1` — breaks range-based queries
- Calling `pushActionIntoCurrentChunk` from inside `resolveName` — that function is
  defined 800 lines later; `_ENV = nil` makes it an uncaptured global → crash

---

## Region Folding

`core/folding.lua` and `core/highlight.lua` both check comment text against four patterns:

```lua
-- standard LuaLS patterns
s:sub(1, #'region')    == 'region'
s:sub(1, #'#region')   == '#region'
-- FA additions: --#region becomes ----region after preprocessing (# → --)
-- comment text is then `--region`, not `#region`
s:sub(1, #'--region')  == '--region'
s:sub(1, #'-- region') == '-- region'
```

The FA `plugin.lua` preprocessor replaces every `#` with `--` before the parser sees the
file. So `--#region` in the source becomes `----region`, and `ssub(Lua, start+2, right)`
gives `--region` as the comment text. The `#region` pattern won't match it.

---

## Build Procedure

### Linux binary

```sh
# 1. Init submodules (once per clone)
git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel

# 2. Build luamake
cd 3rd/luamake && bash compile/build.sh && cd ../..

# 3. Build LuaLS + run full test suite
./3rd/luamake/luamake rebuild
# All tests must pass before packaging
```

### Windows binary (cross-compile from Linux)

**Requirement:** `x86_64-w64-mingw32-gcc` in posix threading model.

```sh
# Install
apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64

# Switch to posix model (required for C++ exception support across DLL boundaries)
update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

# Create case-redirect header shims (Linux FS is case-sensitive; bee.lua uses <Windows.h>)
mkdir -p build/win32-compat
echo '#include <windows.h>'  > build/win32-compat/Windows.h
echo '#include <dbghelp.h>'  > build/win32-compat/DbgHelp.h
echo '#include <ws2tcpip.h>' > build/win32-compat/Ws2tcpip.h
echo '#include <dbgeng.h>'   > build/win32-compat/DbgEng.h

# Create output dirs
mkdir -p build/win32/{obj/{source_bee,source_lua,lua-language-server,lpeglabel,source_bootstrap,code_format},bin}

# Build (uses the checked-in win32-cross-compile.ninja)
ninja -f win32-cross-compile.ninja all
```

**Runtime dependency check:**
```sh
x86_64-w64-mingw32-objdump -p build/win32/bin/lua-language-server.exe | grep "DLL Name"
# Expected: KERNEL32.dll, VERSION.dll, WS2_32.dll, ntdll.dll,
#           api-ms-win-core-synch-l1-2-0.dll, libwinpthread-1.dll, msvcrt.dll
```

Bundle `libwinpthread-1.dll` from `/usr/x86_64-w64-mingw32/lib/libwinpthread-1.dll`.

### Regenerating win32-cross-compile.ninja for a new LuaLS version

After a new LuaLS version builds successfully on Linux, a new `build/build.ninja` is
generated. Transform it to a Windows cross-compile file with these substitutions:

| Linux | Windows |
|---|---|
| `cc = gcc` | `cc = x86_64-w64-mingw32-gcc` |
| `ar = ar` | `ar = x86_64-w64-mingw32-ar` |
| `builddir = build` | `builddir = build/win32` |
| `-DLUA_USE_LINUX` | `-D_WIN32_WINNT=0x0602` |
| Remove: `-fPIC`, `-fvisibility=hidden`, `-rdynamic` | |
| `bee/filewatch/filewatch_linux.cpp` | `bee/filewatch/filewatch_win.cpp` |
| `bee/net/bpoll_linux.cpp` | `bee/net/bpoll_win.cpp` |
| `bee/sys/path_linux.cpp` | `bee/sys/path_win.cpp` |
| `bee/subprocess/subprocess_posix.cpp` | `bee/subprocess/subprocess_win.cpp` |
| `bee/sys/file_handle_linux.cpp` | `bee/sys/file_handle_win.cpp` |
| `bee/thread/simplethread_posix.cpp` | `bee/thread/simplethread_win.cpp` |
| `binding/lua_epoll.cpp` | `binding/port/lua_windows.cpp` |
| Remove: `file_handle_posix.obj`, `path_posix.obj` from link step | |

**Add these Windows-only sources to build + link:**
```
3rd/bee.lua/bee/win/wtf8.cpp
3rd/bee.lua/bee/win/unicode.cpp
3rd/bee.lua/bee/win/module_version.cpp
3rd/bee.lua/bee/win/afd/afd.cpp
3rd/bee.lua/bee/win/afd/poller.cpp
3rd/bee.lua/bee/win/afd/poller_fd.cpp
3rd/bee.lua/bee/net/uds_win.cpp
3rd/bee.lua/3rd/lua-patch/bee_utf8_crt.cpp
3rd/bee.lua/bee/subprocess/process_select.cpp
```

**Link flags** (replace Linux flags entirely):
```
-Wl,-Bstatic <libstdc++.a> <libsupc++.a> <libgcc_eh.a> <libgcc.a> -Wl,-Bdynamic
-lws2_32 -lpsapi -liphlpapi -lwsock32 -lshlwapi -ldbghelp
-lole32 -luserenv -lbcrypt -lntdll -lversion -lsynchronization -s
```

Use explicit `.a` paths (e.g. `/usr/lib/gcc/x86_64-w64-mingw32/13-posix/libstdc++.a`)
rather than `-static-libstdc++` — the flag doesn't reliably find the right library in
the mingw directory layout.

**Output:** `lua-language-server.exe` (not `lua-language-server`)

**Remove** test steps (`unit-test`, `bee-test`) — cannot run `.exe` on Linux.

---

## Common Failures

### `attempt to index a nil value (upvalue '_ENV')` in compile.lua

A standard library function was called in `compile.lua` without being captured before
`_ENV = nil`. Add it to the pre-capture block at the top of the file.

Run `./3rd/luamake/luamake rebuild` to verify before packaging.

### `module 'bee.epoll' not found` on Windows

`brave.lua` was calling `require 'bee.epoll'` unconditionally. Ensure the platform
check is present:
```lua
if platform.os == 'windows' then
    poller_lib = require 'bee.select'   -- SELECT_READ flag
else
    poller_lib = require 'bee.epoll'    -- EPOLLIN flag
end
```

### Blank outline / grayed-out symbols

Caused by injecting synthetic AST nodes or re-tagging existing nodes' `.type` field
after they've been inserted into the tree. Only set `.export = true` on real nodes.
Never add nodes with `start = -1` / `finish = -1`.

### `bin/main.lua: No such file or directory`

`make/bootstrap.lua` must be copied to `server/bin/main.lua`. It is NOT the same as
`server/main.lua`.

### Windows exe exits with code 1

`libwinpthread-1.dll` is missing from `server/bin/`. Copy it from
`/usr/x86_64-w64-mingw32/lib/libwinpthread-1.dll`.

### Ninja linker errors: `undefined reference to std::...`

The `-static-libstdc++` flag doesn't find the right library in the mingw posix layout.
Use explicit `.a` file paths in the link command instead.

---

## Updating to a New LuaLS Version

1. Clone the new release, init submodules.
2. Apply patches from `patches/*.patch` with `patch -p1`.
3. Verify these functions still exist with the same signatures:
   - `compileExpAsAction` in `compile.lua`
   - Function name handler block in `parseAction` in `compile.lua`
   - `comment.short` handler in `core/folding.lua` and `core/highlight.lua`
   - `isValid` function in `provider/diagnostic.lua`
   - `textDocument/didOpen` and `textDocument/didChange` in `provider/provider.lua`
4. Run `./3rd/luamake/luamake rebuild` — all tests must pass.
5. Regenerate `win32-cross-compile.ninja` using the substitutions above.
6. Rebuild the Windows exe and verify DLL dependencies.
