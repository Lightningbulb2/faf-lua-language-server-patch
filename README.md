# FA Lua Language Server — Patch

This package contains the FA-specific patches applied to
[LuaLS](https://github.com/LuaLS/lua-language-server) v3.18.2
to support Supreme Commander: Forged Alliance development.

<mark>**Notice**: Claude.ai was used to read all the FA specific functionality from this LuaLS fork [FAForever/fa-lua-language-server](https://github.com/FAForever/fa-lua-language-server) and build this patch for the modern [LuaLS](https://github.com/LuaLS/lua-language-server).</mark>

---

## Table of Contents

[FA Specific Features](#fa-specific-features)

[Building](#building)

[Updating the FA library](#updating-the-fa-library)

[Updating to a new LuaLS version](#updating-to-a-new-luals-version)

[What's in this package](#whats-in-this-package)

---

# FA-Specific Features

### `---@export-env` / `---@declare-global` Directives

Controlled by `Lua.runtime.exportEnvDefault` (set to `true` automatically by the FA type
library's `config.lua`).

FA scripts define module-level globals that other files access through the environment
rather than explicit `require`. These directives control how the server treats globals
per-file:

| Directive                                   | Effect                                                |
| ------------------------------------------- | ----------------------------------------------------- |
| _(no directive, `exportEnvDefault = true`)_ | All top-level globals treated as exported env symbols |
| `---@declare-global`                        | Opts this file **out** of export-env                  |
| `---@export-env`                            | Opts this file **in** when `exportEnvDefault = false` |
| `---@meta`                                  | Marks file as type-declaration; disables export-env   |

**Implementation:** `guide.lua` adds `isExportEnv(state)` which reads per-file comment
directives. `compile.lua` calls it once at parse start and sets `State.hasExportEnv`.
`compileExpAsAction` and the function-declaration handler in `parseAction` mark top-level
globals with `.export = true` when active. No AST nodes are added or re-typed.

### Support both "--" and "#" syntax for comments

LuaFA supports both `--` and `#` for comments. The FA preprocessor plugin (`meta/3rd/fa-lib/plugin.lua`) converts bare `#` to `--` before the parser sees the file.

The conversion is only done when `#` is **not** already inside a `--` comment:

- `# this is a comment` → `-- this is a comment` ✓
- `local x = 5 # inline comment` → `local x = 5 -- inline comment` ✓
- `-- already a comment with # in it` → unchanged ✓
- `--#region` → **unchanged** (upstream LuaLS handles `--#region` folding natively)

The scanner walks each line character-by-character, skipping over string literal spans (`"..."` / `'...'` including `\\` escape sequences), so `--` inside a string is not mistaken for a comment start.

### Bitwise operators: `&`, `|`, `<<`, `>>`, `^` (XOR)

FA's runtime adds C-style bitwise operators as first-class syntax despite originating from Lua 5.0 (those were added natively in Lua 5.3)
(see [FAForever/lua-lang](https://github.com/FAForever/lua-lang)):

| Operator | Meaning     | Notes                         |
| -------- | ----------- | ----------------------------- |
| `&`      | bitwise AND | binary                        |
| `\|`     | bitwise OR  | binary                        |
| `<<`     | left shift  | binary                        |
| `>>`     | right shift | binary                        |
| `^`      | bitwise XOR | binary (replaces Lua 5.x pow) |

### `LuaFA` Runtime Version

A new runtime version option that maps to Lua 5.1 semantics while removing deprecation
warnings from functions that are standard (not deprecated) in FA's custom runtime:

| Function               | Standard LuaLS (Lua 5.1) | LuaFA                               |
| ---------------------- | ------------------------ | ----------------------------------- |
| `table.getn(t)`        | ~~deprecated~~           | ✓ normal                            |
| `table.foreach(t, f)`  | ~~deprecated~~           | ~~deprecated~~ (use `for k,v in t`) |
| `table.foreachi(t, f)` | ~~deprecated~~           | ~~deprecated~~                      |
| `table.empty(t)`       | unknown                  | ✓ FA extension                      |
| `table.getsize(t)`     | unknown                  | ✓ FA extension                      |
| `continue` keyword     | error                    | ✓ via nonstandardSymbol             |
| `!=` operator          | error                    | ✓ via nonstandardSymbol             |
| `<<` / `>>` operators  | error (Lua 5.1)          | ✓ no error                          |
| `&` / `\|` / `^`       | error (Lua 5.1)          | ✓ no error                          |
| `arg` implicit vararg  | undefined-global         | ✓ declared as global                |

Set automatically by the FA `config.lua` when any `.lua` file is opened. Can be
set manually via `Lua.runtime.version = "LuaFA"`.

### FA Class System (`class.lua`)

The FA class system uses several Lua 5.0-era features that the LS needs to handle:

**`arg` implicit vararg table** — In Lua 5.0, vararg functions receive arguments as
`arg = {..., n=N}` rather than `...`. FA's class system uses `unpack(arg)` throughout.
`config.lua` now declares `arg` as a known global to suppress undefined-global warnings.

**`Class(...)` / `State(...)` / `ConstructClass(...)` types** — The class system file
(`class.lua`) is included in the FA library so the LS understands the `fa-class` and
`fa-class-state` types, including the callable `__call` metamethod pattern.

### `__init` / `__post_init`: no `undefined-field` for sibling methods

Inside `__init` (and `__post_init`) FA code calls methods defined on the **same** class
table:

```lua
local ChatInterface = ClassUI(Window) {
    ---@param self UIChatInterface
    __init = function(self, parent)
        self:SetupDragHandles()      -- ← was: undefined-field false positive
    end,
    SetupDragHandles = function(self) ... end,
}
```

When the user annotates `---@param self UIChatInterface`, LuaLS resolves the type
through a separately-declared `---@class` annotation. That declaration may not list
every method from the class table literal, so `SetupDragHandles` resolves as `unknown`.

**Fix:** `script/core/diagnostics/undefined-field.lua` — a small `isInsideFAInit(src)`
helper walks the AST upward: `getfield`/`getmethod` → `getParentFunction` →
`function.parent` (the `tablefield` node) → checks the key is `__init` or
`__post_init`. If so, the `undefined-field` check is skipped.

Only the two init-method names are suppressed; all other function bodies and top-level
code are unaffected.

---

### `inject-field` disabled for FA engine-typed objects

FA code routinely attaches extra Lua-side state to engine-typed objects:

```lua
self.DragTL          = Bitmap(self)
self.DragTL.textures = DragHandleTextures('ul')   -- was: inject-field
```

`Bitmap` is an engine C++ type exposed through FA stubs. The engine does not prevent
field injection — Lua's metatable system allows it freely — but LuaLS fires
`inject-field` because `textures` is not declared as a `---@field` on `Bitmap`.
Annotating every such site across thousands of FA files would add thousands of
`---@class`-override casts with no meaningful benefit.

**Fix:** `meta/3rd/fa-lib/config.lua` — `inject-field` added to `Lua.diagnostics.disable`
for all FA workspace files.

---

### Named Color Picker

The document color provider (`core/color.lua`) is replaced with the FA version which
recognises FA's named color constants in addition to hex strings:

| Format                 | Example           | Supported        |
| ---------------------- | ----------------- | ---------------- |
| 8-digit hex (AARRGGBB) | `"BD8608FF"`      | ✓                |
| 6-digit hex (#RRGGBB)  | `"#BD8608"`       | ✓                |
| FA named color         | `"DarkGoldenrod"` | ✓ (FA extension) |

Named colors come from FA's `EnumColorNames` table and cover ~140 standard CSS colors
remapped to FA's AARRGGBB byte order.

### `Lua.diagnostics.disableScheme`

Suppresses diagnostics on files matching certain URI schemes. Default: `['git']`.
Prevents errors appearing in VS Code's read-only git diff views.

### `Lua.workspace.supportScheme`

Restricts which URI schemes the server accepts for `didOpen` / `didChange`. Default:
`['file', 'untitled', 'git']`. Files with other schemes are silently ignored.

### Platform-Aware Event Loop (`brave.lua`)

The worker event loop uses `bee.epoll` on Linux and `bee.select` on Windows:

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

# Building

### Prerequisites

| Tool                             | Notes                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| Git                              | For cloning and submodule init                                                       |
| GCC ≥ 11                         | Linux native build                                                                   |
| ninja ≥ 1.10                     | `apt install ninja-build`                                                            |
| `x86_64-w64-mingw32-gcc` (posix) | Windows cross-compile only — `apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64` |

Switch mingw to the posix threading model (required for C++ exceptions):

```sh
update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix
```

### Step 1 — Clone LuaLS 3.18.2 and init submodules

This is all built on top of the Lua Language Server so clone that somewhere and cd into it.

```sh
git clone --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server
git submodule update --init --recursive
```

> **Version matters.** These patches are generated against the exact `3.18.2` tag.
> Cloning `main`/HEAD will get a newer commit with different line numbers and the
> patches will fail to apply.

### Step 2 — Copy over the FA Library

The FA library contains many Lua type stub files covering the engine API as well as the game's codebase.

> See [Updating the FA Library](#updating-the-fa-library) for how to get the latest files straight from the FA codebase before continuing

```sh
# Current working directory: "/your/path/to/lua-language-server"

SRC="/your/path/to/faf-lua-language-server-patch"
cp -r $SRC/meta/3rd/fa-lib meta/3rd
```

### Step 3 — Apply patches

```sh
# Current working directory: "/your/path/to/lua-language-server"
# SRC="/your/path/to/faf-lua-language-server-patch"

for p in "$SRC"/patches/*.patch; do
    patch -p1 < "$p"
done
```

#### alternative Step 3

Or copy the pre-patched files directly (replacing the cloned versions):

```sh
# Current working directory: "/your/path/to/lua-language-server"
# SRC="/your/path/to/faf-lua-language-server-patch"

cp $SRC/locale/en-us/setting.lua                     locale/en-us/setting.lua
cp $SRC/script/brave/brave.lua                       script/brave/brave.lua
cp $SRC/script/brave/work.lua                        script/brave/work.lua
cp $SRC/script/config/template.lua                   script/config/template.lua
cp $SRC/script/core/color.lua                        script/core/color.lua
cp $SRC/script/core/completion/completion.lua        script/core/completion/completion.lua
cp $SRC/script/core/completion/keyword.lua           script/core/completion/keyword.lua
cp $SRC/script/core/diagnostics/undefined-field.lua  script/core/diagnostics/undefined-field.lua
cp $SRC/script/files.lua                             script/files.lua
cp $SRC/script/library.lua                           script/library.lua
cp $SRC/script/parser/compile.lua                    script/parser/compile.lua
cp $SRC/script/parser/guide.lua                      script/parser/guide.lua
cp $SRC/script/provider/diagnostic.lua               script/provider/diagnostic.lua
cp $SRC/script/provider/provider.lua                 script/provider/provider.lua
cp $SRC/script/vm/compiler.lua                       script/vm/compiler.lua
cp $SRC/script/vm/doc.lua                            script/vm/doc.lua
```

### Step 4 — Build luamake

**On Linux:**

> cd into 3rd/luamake is required for the build script's relative paths

```sh
cd 3rd/luamake
bash compile/build.sh
cd ../..
```

**On Windows** (requires Visual Studio 2019 or later, or Build Tools):

Open a **plain Command Prompt** (not Git Bash — `build.bat` must detect MSVC via
`vswhere.exe`):

> cd into 3rd/luamake is required for the build script's relative paths

```bat
:: cd back into the lua-language-server directory

cd 3rd\luamake
compile\build.bat
cd ..\..\
```

> `compile/build.sh` does **not** work on Windows — it targets the mingw compiler
> and will fail with exit code 3221225785 even if Git Bash is installed. Always use
> `compile\build.bat` on Windows.

Ninja must be in your PATH. Visual Studio's Developer Command Prompt includes it
automatically, or install it standalone: https://github.com/ninja-build/ninja/releases

### Step 5 — Build the binary

**On Linux:**

```sh
# in the lua-language-server directory

./3rd/luamake/luamake rebuild
```

**On Windows** (from a plain Command Prompt or VS Developer Command Prompt):

```bat
:: in the lua-language-server directory

3rd\luamake\luamake.exe rebuild
```

This runs the full test suite. All tests must pass.

Output:

- Linux: `bin/lua-language-server`
- Windows: `bin/lua-language-server.exe` + `bin/lua-language-server.dll` + MSVC runtime DLLs

### Step 6 (optional) — Build the Windows binary from Linux (cross-compile, optional)

> <mark>This is an unverified claude-written section (I'm not running linux), if you have tested and/or want improvements to it, please submit a PR</mark>

Only needed if you want to produce a Windows binary on a Linux host. Skip this if
you built natively on Windows in Step 4.

```sh
# Prerequisites: apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
# Switch to posix threading model:
update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

# Create Windows.h case shims (Linux filesystem is case-sensitive)
mkdir -p build/win32-compat
echo '#include <windows.h>'  > build/win32-compat/Windows.h
echo '#include <dbghelp.h>'  > build/win32-compat/DbgHelp.h
echo '#include <ws2tcpip.h>' > build/win32-compat/Ws2tcpip.h
echo '#include <dbgeng.h>'   > build/win32-compat/DbgEng.h

# Create output directories
mkdir -p build/win32/{obj/{source_bee,source_lua,lua-language-server,lpeglabel,source_bootstrap,code_format},bin}

# Build using the cross-compile ninja file from this package
ninja -f /path/to/this/package/win32-cross-compile.ninja all
```

Output: `build/win32/bin/lua-language-server.exe`

The cross-compiled exe depends only on `libwinpthread-1.dll` (no MSVC runtime).
The natively-built Windows exe ships with MSVC runtime DLLs instead.

```sh
x86_64-w64-mingw32-objdump -p build/win32/bin/lua-language-server.exe | grep "DLL Name"
# KERNEL32.dll, VERSION.dll, WS2_32.dll, ntdll.dll, libwinpthread-1.dll, msvcrt.dll
```

---

## Step 6 (optional) — Build the Linux binary from Windows

The extension can bundle Linux and Windows binaries in the same `.vsix` so users
on either OS install the same file. The Windows binary is easy (build natively). For the
Linux binary you have three options from a Windows host.

---

### Option A — WSL2 (recommended)

WSL2 runs a real Linux kernel on Windows with near-native performance. This is the
simplest path and uses the same Linux build steps exactly.

**One-time setup:**

```powershell
# In PowerShell (Admin)
wsl --install          # installs Ubuntu by default; reboot when prompted
wsl --set-default-version 2
```

Then open the Ubuntu terminal and install build tools:

```sh
sudo apt update
sudo apt install -y git gcc g++ ninja-build
```

**Build:**

```sh
# Inside WSL2 Ubuntu terminal
git clone --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server

# Apply FA patches (copy them from Windows into WSL2 first, or clone from your repo)
# Windows drives are at /mnt/c/, /mnt/d/, etc.
for p in /mnt/c/path/to/patches/script_*.patch /mnt/c/path/to/patches/locale_*.patch; do
    patch -p1 < "$p"
done

# Build luamake
git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel
cd 3rd/luamake && bash compile/build.sh && cd ../..

# Build LuaLS (runs tests)
./3rd/luamake/luamake rebuild
```

**Copy the binary to Windows:**

```sh
# From WSL2, copy to Windows filesystem
cp bin/lua-language-server /mnt/c/path/to/extension/server/bin/lua-language-server
cp bin/main.lua             /mnt/c/path/to/extension/server/bin/main.lua
```

---

### Option B — Docker Desktop

> <mark>This is an unverified claude-written section, if you have tested and/or want improvements to it, please submit a PR</mark>

Docker Desktop runs Linux containers on Windows without WSL2 (though it also works
with WSL2 as backend).

**One-time setup:**
Download and install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).

**Build:**

```powershell
# In PowerShell, from the lua-language-server directory with FA patches already applied
docker run --rm -v "${PWD}:/work" -w /work ubuntu:22.04 bash -c "
    apt-get update -q && apt-get install -y -q git gcc g++ ninja-build &&
    git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel &&
    cd 3rd/luamake && bash compile/build.sh && cd ../.. &&
    ./3rd/luamake/luamake rebuild
"
```

The `bin/lua-language-server` Linux binary will appear in your working directory on
Windows when the container exits (volume mount keeps the output).

---

### Option C — GitHub Actions (no local Linux at all)

> <mark>This is an unverified claude-written section, if you have tested and/or want improvements to it, please submit a PR</mark>

If you don't want to install WSL2 or Docker, let CI build the Linux binary and
download the artifact.

1. Fork `LuaLS/lua-language-server` to your GitHub account.
2. Checkout the `3.18.2` tag and apply the FA patches.
3. Push to your fork (to a branch or tag).
4. The existing `.github/workflows/build.yml` will build for all platforms automatically.
5. Download the `linux-x64` artifact from the Actions tab.

The artifact contains `bin/lua-language-server` and all the Lua scripts — just take
`bin/lua-language-server` and `bin/main.lua` from it.

---

### Step 7 (FINAL, Optional) — Assembling the .VSIX for VSCode

Once you have binaries for one or both platforms you can continue the instructions at [Lightningbulb2/faf-lua-vscode-extension-patch](https://github.com/Lightningbulb2/faf-lua-vscode-extension-patch)

---

# Updating the FA library

The FA library is from part of the game's repository [`FAForever/fa`](https://github.com/FAForever/fa) and pieces must be copied over if there have been many updates to its lua.

clone the game repo somewhere and cd into it.

```sh
git clone https://github.com/FAForever/fa
cd fa
```

```sh
# Current working directory: "/your/path/to/fa"

SRC="/your/path/to/faf-lua-language-server-patch"

cp -r /engine  $SRC/meta/3rd/fa-lib/library
cp -r /lua  $SRC/meta/3rd/fa-lib/library

```

---

# Updating to a New LuaLS Version

1. Clone the new tag and re-apply patches with `patch -p1`.
2. Check whether these functions were moved or renamed upstream:
   - `compileExpAsAction` in `compile.lua` — export flag injection point
   - Function name handler in `parseAction` in `compile.lua` — function export
   - `isValid` in `diagnostic.lua` — disableScheme injection point
   - `textDocument/didOpen` and `textDocument/didChange` in `provider.lua`
3. Run `./3rd/luamake/luamake rebuild` — all tests must pass.
4. Regenerate `win32-cross-compile.ninja` from the new `build/build.ninja` by applying
   the same source-file and linker-flag substitutions documented in the skill (For LLMs).

---

# What's in this package

```
script/
  brave/brave.lua            Platform-aware event loop (bee.select on Windows, bee.epoll on Linux)
  brave/work.lua             Compile options type annotation (adds exportEnvDefault field)
  config/template.lua        Three new config keys: exportEnvDefault, disableScheme, supportScheme
  core/completion/completion.lua
  core/completion/keyword.lua
  core/diagnostics/undefined-field.lua      Suppress undefined-field inside __init / __post_init bodies
  core/color.lua
  files.lua                  Passes exportEnvDefault from config into the parser
  parser/compile.lua         exportEnvDefault parser integration; export flag on globals
  parser/guide.lua           isExportEnv(state) function
  provider/diagnostic.lua    disableScheme filtering
  provider/provider.lua      supportScheme filtering on didOpen / didChange
  vm/compiler.lua
  vm/doc.lua
  library.lua

locale/en-us/setting.lua     English descriptions for the three new settings

meta/3rd/fa-lib              The FA library contains many Lua type stub files covering the engine API as well as the game's codebase.

patches/                     Unified diffs against unmodified LuaLS 3.18.2
  locale_en-us_setting.lua.patch
  script_brave_brave.lua.patch
  script_brave_work.lua.patch
  script_config_template.lua.patch
  script_core_color.lua.patch
  script_core_completion_completion.lua.patch
  script_core_completion_keyword.lua.patch
  script_core_diagnostics_undefined-field.lua.patch
  script_files.lua.patch
  script_library.lua.patch
  script_parser_compile.lua.patch
  script_parser_guide.lua.patch
  script_provider_diagnostic.lua.patch
  script_provider_provider.lua.patch
  script_vm_compiler.lua.patch
  script_vm_doc.lua.patch


win32-cross-compile.ninja    Pre-generated ninja file for Windows cross-compilation from Linux
```

---

## Notes for when modifying patches for the language server

### Critical: The `_ENV = nil` Constraint

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
