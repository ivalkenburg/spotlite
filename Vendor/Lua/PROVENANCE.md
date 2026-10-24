# Lua 5.5.1

Unmodified upstream C library sources and public headers from:
https://www.lua.org/ftp/lua-5.5.1.tar.gz

Archive SHA-256: `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`

The standalone interpreter/compiler entry points (`lua.c`, `luac.c`) and upstream Makefile are omitted; Spotlite builds the library through SwiftPM and provides its own process entry point. Public headers are duplicated in `include` for the SwiftPM C target. Upstream license and copyright notices are retained in `src/lua.h` and `include/lua.h` (MIT license). No LuaJIT or external Lua installation is used.
