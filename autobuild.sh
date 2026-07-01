cd ..
git clone --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server
git submodule update --init --recursive

SRC="C:/development_GIT_REPOSITORIES/faf-lua-language-server-patch"
cp -r $SRC/meta/3rd/fa-lib meta/3rd

for p in "$SRC"/patches/*.patch; do
    patch -p1 < "$p"
done

cd 3rd/luamake
cmd //c "compile\build.bat"
cd ../../

cd ..

git clone --branch v3.18.2 https://github.com/LuaLS/vscode-lua
cd vscode-lua
git submodule update --init --recursive

SRC="C:/development_GIT_REPOSITORIES/faf-lua-vscode-extension-patch"

patch -p1 < "$SRC/patches/client_src_languageserver.ts.patch"
patch -p1 < "$SRC/patches/package.json.patch"
patch -p1 < "$SRC/patches/package.nls.json.patch"

cd client
npm install
npm run build

cd webvue
npm install
npm run build
cd ../..

# Current working directory: /your/path/to/vscode-lua
LS="C:/development_GIT_REPOSITORIES/lua-language-server"

cp $LS/main.lua      server/
cp $LS/debugger.lua  server/
cp $LS/changelog.md  server/
cp $LS/LICENSE       server/
cp -r $LS/locale     server/
cp -r $LS/script     server/
cp -r $LS/meta       server/
cp -r $LS/bin        server/

vsce package --no-dependencies