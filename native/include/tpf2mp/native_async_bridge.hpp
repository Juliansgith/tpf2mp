#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <utility>

struct lua_State;

namespace tpf2mp::async_bridge {

using LuaCFunction = int (*)(lua_State*);
using LuaPushLString = const char* (*)(lua_State*, const char*, std::size_t);
using LuaToLString = const char* (*)(lua_State*, int, std::size_t*);
using LuaGetTop = int (*)(lua_State*);
using LuaPushCClosure = void (*)(lua_State*, LuaCFunction, int);
using LuaRawSet = void (*)(lua_State*, int);

struct Limits {
  std::size_t message_count{4096};
  std::size_t queued_bytes{64U * 1024U * 1024U};
  std::size_t message_bytes{8U * 1024U * 1024U};
};

// A process-owned FIFO that keeps numbered bridge file I/O off Transport
// Fever 2's Lua/simulation thread. Lua still signs and validates envelopes;
// this class only transports opaque UTF-8 bytes in strict sequence order.
class AsyncFileBridge {
 public:
  explicit AsyncFileBridge(Limits limits = {});
  ~AsyncFileBridge();
  AsyncFileBridge(const AsyncFileBridge&) = delete;
  AsyncFileBridge& operator=(const AsyncFileBridge&) = delete;

  bool Configure(const std::filesystem::path& root, std::uint64_t requested_out,
                 std::uint64_t requested_in, std::uint64_t& effective_out,
                 std::string& error);
  bool Enqueue(std::uint64_t sequence, std::string bytes, std::string& error);
  std::optional<std::pair<std::uint64_t, std::string>> TakeInbound();
  void Pump();
  std::string StatusJson() const;
  bool IsConfigured() const;

  // Test-only lifecycle boundary. The injected DLL itself is never unloaded.
  void Reset();

 private:
  struct Impl;
  Impl* impl_;
};

AsyncFileBridge& Global();
std::uint64_t MonotonicMicroseconds();

// Installs four string-only globals into the exact Lua state supplied by the
// pinned hook. Keeping registration here prevents bridge internals from
// growing hook_dll.cpp back into a monolith.
void RegisterLuaApi(lua_State* state, LuaPushLString push_string,
                    LuaToLString to_string, LuaGetTop get_top,
                    LuaPushCClosure push_closure, LuaRawSet raw_set);

}  // namespace tpf2mp::async_bridge
