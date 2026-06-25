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
| `locale/en-us/setting.lua` | Descriptions for the three new settings |
| `script/core/diagnostics/undefined-field.lua` | Suppress `undefined-field` inside `__init` / `__post_init` function bodies |

---

## FA Class System: `__init` and `inject-field` Diagnostics

### `undefined-field` inside `__init` / `__post_init`

**Symptom:**
```
Undefined field `SetupDragHandles`. Lua Diagnostics.(undefined-field)
(field) UIChatInterface.SetupDragHandles: unknown
```
fired on `self:SetupDragHandles()` (or any sibling-method call) inside `__init`.

**Root cause:** When a user annotates `---@param self UIChatInterface` inside `__init`,
LuaLS checks whether `UIChatInterface` has `SetupDragHandles`. If `UIChatInterface` was
declared via a standalone `---@class UIChatInterface : Window` somewhere without a full
`---@field` for every method, those methods appear as `unknown` fields. The class table
literal itself *does* have all the methods, but LuaLS's generic `T` inference for the
`ClassUI(Base) { ... }` pattern does not always flow the full method set into a separately-
declared `---@class` name.

**Fix:** `script/core/diagnostics/undefined-field.lua` — patch adds `isInsideFAInit(src)`
which walks up the AST: `src → getParentFunction → function.parent (tablefield)` and
checks whether the tablefield key is `__init` or `__post_init`. When true, the
`undefined-field` check is skipped entirely for that node.

**Why this scope is safe:** The suppression only fires when the *direct* enclosing
function is a table field named `__init` or `__post_init`. Normal method bodies, top-
level code, and anonymous functions are unaffected. The check still fires for genuinely
missing fields in any other context.

**Patch file:** `patches/script_core_diagnostics_undefined-field.lua.patch`

---

### `inject-field` on engine-typed objects

**Symptom:**
```
Fields cannot be injected into the reference of `Bitmap` for `textures`.
To do so, use `---@class` for `UIChatInterface.DragTL`. Lua Diagnostics.(inject-field)
```

**Root cause:** FA code routinely stores extra Lua-side state on engine-typed objects:
```lua
self.DragTL          = Bitmap(self)       -- DragTL : bitmap_methods (engine type)
self.DragTL.textures = DragHandleTextures('ul')  -- inject-field fires here
```
`DragTL` resolves to `Bitmap` (from the FA stubs). `inject-field` fires because `textures`
is not declared as a `---@field` on `Bitmap`, and the engine C++ class is closed — you
cannot add fields to the stub definitions without lying about the engine's actual type.

This is not an error. FA uses this pattern everywhere: caching computed values, attaching
controller tables, storing child references. The engine does not care; Lua's metatable
system allows arbitrary field injection on any table. The diagnostic is purely a LuaLS
type-purity check.

**Fix:** Disable `inject-field` globally for FA files via `meta/3rd/fa/config.lua`:
```lua
{
    key    = 'Lua.diagnostics.disable',
    action = 'add',
    value  = 'inject-field',
},
```

**Why global disable is correct here:** Unlike `undefined-field` (which is often a real
typo), `inject-field` on FA code is almost always intentional. The FA engine type stubs
cover ~700 files; annotating every runtime field injection with `---@class` overrides
or `---@type` casts would be thousands of lines of noise annotations. The diagnostic
adds no value in an FA codebase.

**Patch file:** `patches/meta_3rd_fa_config.lua.patch`

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

Upstream LuaLS natively supports `--#region` / `--#endregion` folding. No patches to
`folding.lua` or `highlight.lua` are required.

The FA `plugin.lua` preprocessor does **not** touch `--#region` lines: when scanning a
line, it detects the `--` at column 1 as a real comment start and stops — the `#` that
follows is already inside the comment and is left alone. So `--#region` reaches the
language server unchanged and LuaLS folds it normally.

A standalone `#region` at the start of a line (no leading `--`) is a valid FA-style
comment. The preprocessor replaces the `#` with `--`, making it `--region`. This is
treated as a regular comment; it will **not** trigger fold markers (use `--#region`
instead if you want foldable regions in FA code).

---

## Bitwise Operators (`<<`, `>>`, `&`, `|`, `^`)

FA's runtime (see [FAForever/lua-lang](https://github.com/FAForever/lua-lang)) adds
C-style bitwise operators. The LuaLS parser already has all five in `BinarySymbol` with
correct precedence:

```lua
['|']   = 4,   -- bitwise OR
['~']   = 5,   -- bitwise XOR (binary) / NOT (unary)
['&']   = 6,   -- bitwise AND
['<<']  = 7,   -- left shift
['>>']  = 7,   -- right shift
```

**Problem with `<<` and `>>`:** `parseBinaryOP` (compile.lua ~line 2983) has a version
guard that fires `UNSUPPORT_SYMBOL` for these two unless the version is `Lua 5.3/5.4/5.5`.
`LuaFA` was not in that allowlist.

**Fix:** Add `and State.version ~= 'LuaFA'` to the guard condition:

```lua
if token == '//'
or token == '<<'
or token == '>>' then
    if  State.version ~= 'Lua 5.3'
    and State.version ~= 'Lua 5.4'
    and State.version ~= 'Lua 5.5'
    -- FAForever: LuaFA supports bitwise << >> (see FAForever/lua-lang)
    and State.version ~= 'LuaFA' then
        pushError { type = 'UNSUPPORT_SYMBOL', ... }
    end
end
```

`&`, `|`, `~` (unary bitwise NOT) and `^` already had no version guard — they parse
without error under any version. Only `<<` and `>>` needed this fix.

**Patch file:** `patches/script_parser_compile.lua.patch` (new hunk at `@@ -2985 @@`)

---

## `plugin.lua` — `#` Preprocessor Bug Fix

**File:** `meta/3rd/fa-lib/plugin.lua`

**Symptom:** On a line like `local x = "a--b" # comment`, the `#` after the string
should be replaced with `--` (it is a FA-style comment). The old code called
`line:find("--", 1, true)` and found `--` at column 12 *inside the string*, then
treated `hash_pos > comment_pos` as "already in a comment" → the `#` was silently
dropped with no replacement.

**Root cause:** `line:find("--", 1, true)` is a plain substring search that cannot
distinguish `--` inside a string literal from a real Lua comment.

**Fix:** Walk the line character-by-character, honouring string literal spans:

```
State machine per character:
  ' or "  → enter string, skip to matching close-quote (handle \\ escapes)
  --      → found real comment start; record position and stop
  other   → advance
```

After finding the real `comment_pos` (or `nil` if no `--` comment exists outside
strings), the `#`-replacement logic is unchanged: replace every `#` that precedes
`comment_pos`, stop at the first `#` that follows it.

**Edge cases handled correctly after the fix:**

| Line                              | comment_pos | `#` replaced? |
|-----------------------------------|-------------|---------------|
| `# comment`                       | nil         | yes (col 1)   |
| `local x = 5 # comment`           | nil         | yes           |
| `-- real comment # hash`          | 1           | no            |
| `local s = "a--b" # comment`      | nil*        | yes           |
| `local s = "a--b" -- real # hash` | 20*         | no            |

_*`--` inside `"a--b"` is skipped; the scanner continues past the closing `"`._

**This file is shipped directly (no `.patch` file for it).** Update `plugin.lua` in
`meta/3rd/fa-lib/` directly.

---

## Build Procedure

### Linux/macOS binary

```sh
# 1. Clone the exact 3.18.2 tag (patches won't apply to other versions)
git clone --depth=1 --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server
git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel

# 2. Build luamake
cd 3rd/luamake && bash compile/build.sh && cd ../..

# 3. Build LuaLS + run full test suite
./3rd/luamake/luamake rebuild
# All tests must pass before packaging
```

### Windows binary (native, requires Visual Studio)

Open a plain **Command Prompt** — NOT Git Bash. `build.bat` must find MSVC via
`vswhere.exe`, and `build.sh` will fail on Windows with exit code 3221225785.

```bat
git submodule update --init --recursive
cd 3rd\luamake
compile\build.bat
cd ..\..\ 
3rd\luamake\luamake.exe rebuild
```

Requires: Visual Studio 2019+ (or Build Tools) with C++ workload, and ninja in PATH
(VS Developer Command Prompt adds it automatically).

Output: `bin/lua-language-server.exe` + DLLs in `bin/`.
The native build ships MSVC runtime DLLs (`msvcp140.dll`, `vcruntime140.dll`, etc.)
instead of `libwinpthread-1.dll`.

### Linux binary from Windows

Three options, in order of recommendation:

**WSL2** (simplest — follow the Linux build steps inside `wsl`):
```sh
# In WSL2 Ubuntu terminal
git clone --depth=1 --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server
# Apply patches, init submodules, then:
cd 3rd/luamake && bash compile/build.sh && cd ../..
./3rd/luamake/luamake rebuild
# Copy result to Windows: cp bin/lua-language-server /mnt/c/your/path/
```

**Docker Desktop** (one liner from PowerShell, no WSL2 required):
```powershell
docker run --rm -v "${PWD}:/work" -w /work ubuntu:22.04 bash -c "
    apt-get update -q && apt-get install -y -q gcc g++ ninja-build &&
    git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel &&
    cd 3rd/luamake && bash compile/build.sh && cd ../.. &&
    ./3rd/luamake/luamake rebuild
"
# bin/lua-language-server appears on the Windows host via volume mount
```

**GitHub Actions** (no local Linux at all): push the patched repo and download the
`linux-x64` artifact from the Actions tab. The existing `.github/workflows/build.yml`
builds all platforms.

### Windows binary (cross-compile from Linux, alternative)

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
   - `isValid` function in `provider/diagnostic.lua`
   - `textDocument/didOpen` and `textDocument/didChange` in `provider/provider.lua`
   - `checkUndefinedField` inner function in `core/diagnostics/undefined-field.lua`
     (specifically: the `if vm.hasDef(src) then return end` block that our FA guard follows)
   - The `if token == '//' or token == '<<' or token == '>>'` block in `parseBinaryOP`
     in `compile.lua` — confirm our `and State.version ~= 'LuaFA'` line is still present
     and that LuaLS hasn't moved or restructured this version guard.
4. Run `./3rd/luamake/luamake rebuild` — all tests must pass.
5. Regenerate `win32-cross-compile.ninja` using the substitutions above.
6. Rebuild the Windows exe and verify DLL dependencies.
