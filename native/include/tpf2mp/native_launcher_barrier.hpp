#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

struct lua_State;

namespace tpf2mp::launcher {

using LuaCFunction = int (*)(lua_State*);
using LuaPushCClosure = void (*)(lua_State*, LuaCFunction, int);
using LuaPushLString = const char* (*)(lua_State*, const char*, std::size_t);
using LuaCallK = void (*)(lua_State*, int, int, int, LuaCFunction);
using LuaGetTop = int (*)(lua_State*);
using LuaInsert = void (*)(lua_State*, int);
using LuaRawGetI = void (*)(lua_State*, int, int);
using LuaRawSet = void (*)(lua_State*, int);
using LuaSetTop = void (*)(lua_State*, int);

// Adds the native, non-cached launcher readiness reader to the globals table
// already on top of the supplied Lua state's stack.
void RegisterBootstrapApi(lua_State* state, LuaPushLString push_string,
                          LuaPushCClosure push_closure, LuaRawSet raw_set,
                          LuaRawGetI raw_get_i, LuaInsert insert,
                          LuaCallK call_k, LuaGetTop get_top,
                          LuaSetTop set_top);

// Points the persistent launcher at the currently active GUI command state.
// The pump is accepted only from that state's owning thread and only emits the
// fixed TPF2MP heartbeat event; it is not a general cross-state evaluator.
void SetPumpTarget(lua_State* state, int script_event_registry_slot,
                   int send_command_registry_slot, std::uint32_t owning_thread);
void ObserveContext(lua_State* state, std::string_view context,
                    int script_event_registry_slot, int send_command_registry_slot);

}  // namespace tpf2mp::launcher
