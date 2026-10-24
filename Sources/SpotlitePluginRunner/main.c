#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>

/* The protocol has its own descriptor. Plugin print/io.stdout go to the log pipe. */
static int send_message(lua_State *L) {
    size_t length;
    const char *message = luaL_checklstring(L, 1, &length);
    FILE *out = lua_touserdata(L, lua_upvalueindex(1));
    if (length > 4 * 1024 * 1024) return luaL_error(L, "message exceeds 4 MiB");
    if (fwrite(message, 1, length, out) != length || fputc('\n', out) == EOF || fflush(out))
        return luaL_error(L, "host disconnected");
    return 0;
}

int main(int argc, char **argv) {
    /* Host-owned descendants share this group, so Force Stop also reaps them. */
    if (setpgid(0, 0) != 0) { perror("setpgid"); return 1; }
    if (argc >= 3 && strcmp(argv[1], "--exec") == 0) {
        execvp(argv[2], argv + 2);
        perror("execvp"); return 127;
    }
    if (argc != 3) { fprintf(stderr, "usage: SpotlitePluginRunner bootstrap.lua package\n"); return 64; }
    FILE *protocol = fdopen(dup(STDOUT_FILENO), "w");
    if (!protocol || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 1;
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);
    lua_pushlightuserdata(L, protocol);
    lua_pushcclosure(L, send_message, 1);
    lua_setglobal(L, "_spotlite_send");
    lua_pushstring(L, argv[2]); lua_setglobal(L, "_spotlite_package");
    lua_pushstring(L, argv[1]); lua_setglobal(L, "_spotlite_bootstrap");
    int status = luaL_dofile(L, argv[1]);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L);
    fclose(protocol);
    return status == LUA_OK ? 0 : 1;
}
