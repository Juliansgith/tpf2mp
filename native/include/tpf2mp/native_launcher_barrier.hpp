#pragma once

#include <cstddef>

struct lua_State;

namespace tpf2mp::launcher {

using LuaCFunction = int (*)(lua_State*);
using LuaPushCClosure = void (*)(lua_State*, LuaCFunction, int);
using LuaPushLString = const char* (*)(lua_State*, const char*, std::size_t);
using LuaRawSet = void (*)(lua_State*, int);

// Adds the native, non-cached launcher readiness reader to the globals table
// already on top of the supplied Lua state's stack.
void RegisterBootstrapApi(lua_State* state, LuaPushLString push_string,
                          LuaPushCClosure push_closure, LuaRawSet raw_set);

}  // namespace tpf2mp::launcher
