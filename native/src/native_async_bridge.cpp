#include "tpf2mp/native_async_bridge.hpp"

#include "tpf2mp/native_common.hpp"

#include <Windows.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cwctype>
#include <deque>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <system_error>

namespace tpf2mp::async_bridge {
namespace {

constexpr std::uint64_t kMinimumSequence = 1;
constexpr std::uint64_t kMaximumSequence = 999999999999ULL;
constexpr std::uint64_t kInboxPollMilliseconds = 10;
constexpr std::uint64_t kMaximumIdleInboxPollMilliseconds = 50;
constexpr std::uint64_t kWriteRetryMilliseconds = 100;
constexpr std::size_t kPumpBatch = 32;

struct Item {
  std::uint64_t sequence{};
  std::string bytes;
};

// The game ships its own msvcp140.dll. A hook built with a newer MSVC toolset
// must not instantiate std::mutex against that process-local runtime: the
// layouts are not a safe injected-module ABI on Build 35924. Use the stable
// Win32 primitive already used by hook_dll.cpp instead.
class BridgeLock final {
 public:
  explicit BridgeLock(SRWLOCK& lock) : lock_(&lock) { AcquireSRWLockExclusive(lock_); }
  ~BridgeLock() { ReleaseSRWLockExclusive(lock_); }
  BridgeLock(const BridgeLock&) = delete;
  BridgeLock& operator=(const BridgeLock&) = delete;

 private:
  SRWLOCK* lock_;
};

std::filesystem::path Normal(const std::filesystem::path& value) {
  std::error_code error;
  auto result = std::filesystem::absolute(value, error);
  if (error) result = value;
  return result.lexically_normal();
}

std::wstring Fold(std::filesystem::path value) {
  auto text = Normal(value).wstring();
  std::transform(text.begin(), text.end(), text.begin(),
                 [](const wchar_t ch) { return static_cast<wchar_t>(std::towlower(ch)); });
  while (text.size() > 3 && (text.back() == L'\\' || text.back() == L'/')) text.pop_back();
  return text;
}

bool IsScopedRoot(const std::filesystem::path& value) {
  const auto root = Fold(value);
  const auto allowed = Fold(std::filesystem::temp_directory_path() / "tpf2mp_bridge");
  if (root.size() <= allowed.size() || root.compare(0, allowed.size(), allowed) != 0) return false;
  return root[allowed.size()] == L'\\' || root[allowed.size()] == L'/';
}

bool FileExists(const std::filesystem::path& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES
      && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::string FileName(const std::uint64_t sequence) {
  std::ostringstream output;
  output << std::setw(12) << std::setfill('0') << sequence << ".json";
  return output.str();
}

bool ReadBounded(const std::filesystem::path& path, const std::size_t limit,
                 std::string& result, std::string& error) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) return false;
  const auto size = input.tellg();
  if (size < 0 || static_cast<std::uint64_t>(size) > limit) {
    error = "inbox message exceeds the native bridge size limit";
    return false;
  }
  result.resize(static_cast<std::size_t>(size));
  input.seekg(0);
  input.read(result.data(), size);
  if (!input && !input.eof()) {
    error = "could not read the complete inbox message";
    result.clear();
    return false;
  }
  return true;
}

bool ParseSequence(const char* raw, const std::size_t length, std::uint64_t& result) {
  if (raw == nullptr || length == 0 || length > 12) return false;
  result = 0;
  for (std::size_t index = 0; index < length; ++index) {
    if (raw[index] < '0' || raw[index] > '9') return false;
    result = result * 10 + static_cast<unsigned>(raw[index] - '0');
  }
  return result >= kMinimumSequence && result <= kMaximumSequence;
}

LuaPushLString g_push_string = nullptr;
LuaToLString g_to_string = nullptr;
LuaGetTop g_get_top = nullptr;

void Push(lua_State* state, const std::string& value) {
  g_push_string(state, value.data(), value.size());
}

int NativeConfigure(lua_State* state) {
  if (g_get_top(state) < 3) {
    Push(state, "F1|configure requires root, output sequence, and input sequence");
    return 1;
  }
  std::size_t root_length = 0, out_length = 0, in_length = 0;
  const char* root = g_to_string(state, 1, &root_length);
  const char* raw_out = g_to_string(state, 2, &out_length);
  const char* raw_in = g_to_string(state, 3, &in_length);
  std::uint64_t out = 0, in = 0;
  if (root == nullptr || root_length == 0 || root_length > 32767 ||
      !ParseSequence(raw_out, out_length, out) || !ParseSequence(raw_in, in_length, in)) {
    Push(state, "F1|invalid native bridge configuration");
    return 1;
  }
  std::string error;
  std::uint64_t effective = out;
  if (!Global().Configure(std::filesystem::path(Utf8ToWide(std::string(root, root_length))),
                          out, in, effective, error)) {
    Push(state, "F1|" + error);
    return 1;
  }
  Push(state, "A1|" + std::to_string(effective));
  return 1;
}

int NativeEmit(lua_State* state) {
  if (g_get_top(state) < 2) {
    Push(state, "F1|emit requires a sequence and payload");
    return 1;
  }
  std::size_t sequence_length = 0, data_length = 0;
  const char* raw_sequence = g_to_string(state, 1, &sequence_length);
  const char* data = g_to_string(state, 2, &data_length);
  std::uint64_t sequence = 0;
  if (!ParseSequence(raw_sequence, sequence_length, sequence) || data == nullptr) {
    Push(state, "F1|invalid native bridge emission");
    return 1;
  }
  std::string error;
  if (!Global().Enqueue(sequence, std::string(data, data_length), error)) {
    Push(state, "F1|" + error);
    return 1;
  }
  Push(state, "A1");
  return 1;
}

int NativeTake(lua_State* state) {
  auto item = Global().TakeInbound();
  if (!item) return 0;
  Push(state, "I1|" + std::to_string(item->first) + "|" + std::move(item->second));
  return 1;
}

int NativeStatus(lua_State* state) {
  Push(state, Global().StatusJson());
  return 1;
}

int NativeMonotonicMicroseconds(lua_State* state) {
  Push(state, std::to_string(MonotonicMicroseconds()));
  return 1;
}

template <LuaCFunction Function>
int GuardedLuaCall(lua_State* state) noexcept {
  try {
    return Function(state);
  } catch (...) {
    // No C++ exception may cross Lua's C ABI. Filesystem/allocation failures
    // become an ordinary fail-closed bridge response whenever Lua can still
    // accept one; an exhausted Lua stack receives no result rather than a
    // process-terminating unwind.
    try {
      Push(state, "F1|native bridge operation raised an internal exception");
      return 1;
    } catch (...) {
      return 0;
    }
  }
}

void Register(lua_State* state, const char* name, LuaCFunction function,
              LuaPushCClosure push_closure, LuaRawSet raw_set) {
  g_push_string(state, name, std::strlen(name));
  push_closure(state, function, 0);
  raw_set(state, -3);
}

}  // namespace

struct AsyncFileBridge::Impl {
  explicit Impl(const Limits limits_value) : limits(limits_value) {}

  Limits limits;
  mutable SRWLOCK lock = SRWLOCK_INIT;
  bool configured{};
  std::filesystem::path root;
  std::uint64_t next_out{kMinimumSequence};
  std::uint64_t next_read{kMinimumSequence};
  std::filesystem::path next_inbox_path;
  std::deque<Item> outbound;
  std::deque<Item> inbound;
  std::size_t outbound_bytes{};
  std::size_t inbound_bytes{};
  std::uint64_t accepted{};
  std::uint64_t written{};
  std::uint64_t read{};
  std::uint64_t taken{};
  std::uint64_t rejected{};
  std::uint64_t last_inbox_poll{};
  std::uint64_t inbox_poll_milliseconds{kInboxPollMilliseconds};
  std::uint64_t next_write_retry{};
  std::string last_error;
};

AsyncFileBridge::AsyncFileBridge(const Limits limits) : impl_(new Impl(limits)) {}
AsyncFileBridge::~AsyncFileBridge() { delete impl_; }

bool AsyncFileBridge::Configure(const std::filesystem::path& requested_root,
                                const std::uint64_t requested_out,
                                const std::uint64_t requested_in,
                                std::uint64_t& effective_out, std::string& error) {
  const auto root = Normal(requested_root);
  if (!IsScopedRoot(root)) {
    error = "bridge root is outside the process TEMP/tpf2mp_bridge boundary";
    return false;
  }
  if (requested_out < kMinimumSequence || requested_out > kMaximumSequence ||
      requested_in < kMinimumSequence || requested_in > kMaximumSequence) {
    error = "bridge sequence is outside the 12-digit protocol range";
    return false;
  }
  std::error_code filesystem_error;
  std::filesystem::create_directories(root / "game_outbox", filesystem_error);
  if (!filesystem_error) std::filesystem::create_directories(root / "game_inbox", filesystem_error);
  if (filesystem_error) {
    error = "cannot create native bridge directories: " + filesystem_error.message();
    return false;
  }

  BridgeLock lock(impl_->lock);
  const bool identity_changed = !impl_->configured || Fold(impl_->root) != Fold(root);
  if (identity_changed) {
    impl_->outbound.clear();
    impl_->inbound.clear();
    impl_->outbound_bytes = impl_->inbound_bytes = 0;
    impl_->root = root;
    impl_->next_out = requested_out;
    impl_->next_read = requested_in;
    impl_->next_inbox_path = root / "game_inbox" / FileName(requested_in);
    impl_->last_error.clear();
    impl_->inbox_poll_milliseconds = kInboxPollMilliseconds;
    impl_->configured = true;
  } else {
    // A Lua save/load can recreate its wrapper while this process-owned queue
    // survives. Preserve accepted output and only rewind inbound when the Lua
    // cursor cannot describe the queue we already hold.
    if (requested_out > impl_->next_out && impl_->outbound.empty()) impl_->next_out = requested_out;
    const std::uint64_t earliest = impl_->inbound.empty()
        ? impl_->next_read : impl_->inbound.front().sequence;
    if (requested_in != earliest) {
      impl_->inbound.clear();
      impl_->inbound_bytes = 0;
      impl_->next_read = requested_in;
      impl_->next_inbox_path = root / "game_inbox" / FileName(requested_in);
    }
  }
  while (impl_->next_out <= kMaximumSequence &&
         FileExists(impl_->root / "game_outbox" / FileName(impl_->next_out))) {
    ++impl_->next_out;
  }
  if (impl_->next_out > kMaximumSequence) {
    error = "native bridge output sequence space is exhausted";
    impl_->last_error = error;
    return false;
  }
  effective_out = impl_->next_out;
  error.clear();
  return true;
}

bool AsyncFileBridge::Enqueue(const std::uint64_t sequence, std::string bytes,
                              std::string& error) {
  BridgeLock lock(impl_->lock);
  if (!impl_->configured) error = "native bridge is not configured";
  else if (sequence != impl_->next_out) error = "native bridge output sequence mismatch";
  else if (bytes.size() > impl_->limits.message_bytes) error = "native bridge message is too large";
  else if (impl_->outbound.size() >= impl_->limits.message_count ||
           impl_->outbound_bytes + bytes.size() > impl_->limits.queued_bytes) {
    error = "native bridge output queue is full";
  } else {
    impl_->outbound_bytes += bytes.size();
    impl_->outbound.push_back(Item{sequence, std::move(bytes)});
    impl_->inbox_poll_milliseconds = kInboxPollMilliseconds;
    impl_->last_inbox_poll = 0;
    ++impl_->next_out;
    ++impl_->accepted;
    error.clear();
    return true;
  }
  ++impl_->rejected;
  impl_->last_error = error;
  return false;
}

std::optional<std::pair<std::uint64_t, std::string>> AsyncFileBridge::TakeInbound() {
  BridgeLock lock(impl_->lock);
  if (impl_->inbound.empty()) return std::nullopt;
  Item item = std::move(impl_->inbound.front());
  impl_->inbound.pop_front();
  impl_->inbound_bytes -= item.bytes.size();
  ++impl_->taken;
  return std::pair<std::uint64_t, std::string>{item.sequence, std::move(item.bytes)};
}

void AsyncFileBridge::Pump() {
  try {
    for (std::size_t count = 0; count < kPumpBatch; ++count) {
      Item item;
      std::filesystem::path path;
      {
        BridgeLock lock(impl_->lock);
        const auto now = GetTickCount64();
        if (!impl_->configured || impl_->outbound.empty() || now < impl_->next_write_retry) break;
        item = impl_->outbound.front();
        path = impl_->root / "game_outbox" / FileName(item.sequence);
      }
      std::string error;
      bool written = false;
      if (FileExists(path)) {
        error = "refusing to overwrite an existing numbered outbox message";
      } else {
        written = AtomicWriteUtf8(path, item.bytes, error);
      }
      BridgeLock lock(impl_->lock);
      if (!written) {
        impl_->last_error = error;
        impl_->next_write_retry = GetTickCount64() + kWriteRetryMilliseconds;
        break;
      }
      if (!impl_->outbound.empty() && impl_->outbound.front().sequence == item.sequence) {
        impl_->outbound_bytes -= impl_->outbound.front().bytes.size();
        impl_->outbound.pop_front();
        ++impl_->written;
        impl_->last_error.clear();
      }
    }

    const auto now = GetTickCount64();
    {
      BridgeLock lock(impl_->lock);
      if (!impl_->configured || now - impl_->last_inbox_poll < impl_->inbox_poll_milliseconds) return;
      impl_->last_inbox_poll = now;
    }
    for (std::size_t count = 0; count < kPumpBatch; ++count) {
      std::filesystem::path path;
      std::uint64_t sequence = 0;
      {
        BridgeLock lock(impl_->lock);
        if (impl_->inbound.size() >= impl_->limits.message_count ||
            impl_->inbound_bytes >= impl_->limits.queued_bytes) break;
        sequence = impl_->next_read;
        path = impl_->next_inbox_path;
      }
      if (!FileExists(path)) {
        BridgeLock lock(impl_->lock);
        impl_->inbox_poll_milliseconds = std::min(
            kMaximumIdleInboxPollMilliseconds, impl_->inbox_poll_milliseconds + 5);
        break;
      }
      std::string bytes, error;
      if (!ReadBounded(path, impl_->limits.message_bytes, bytes, error)) {
        BridgeLock lock(impl_->lock);
        impl_->last_error = error.empty() ? "could not read native inbox message" : error;
        break;
      }
      BridgeLock lock(impl_->lock);
      if (sequence != impl_->next_read) continue;
      if (impl_->inbound_bytes + bytes.size() > impl_->limits.queued_bytes) break;
      impl_->inbound_bytes += bytes.size();
      impl_->inbox_poll_milliseconds = kInboxPollMilliseconds;
      impl_->inbound.push_back(Item{sequence, std::move(bytes)});
      ++impl_->next_read;
      impl_->next_inbox_path = impl_->root / "game_inbox" / FileName(impl_->next_read);
      ++impl_->read;
      impl_->last_error.clear();
    }
  } catch (...) {
    // This runs on the injected worker. A denied/corrupt filesystem operation
    // must stall the bridge visibly, never terminate the host game process.
    try {
      BridgeLock lock(impl_->lock);
      impl_->last_error = "native bridge worker raised an internal exception";
      impl_->next_write_retry = GetTickCount64() + kWriteRetryMilliseconds;
    } catch (...) {
    }
  }
}

std::string AsyncFileBridge::StatusJson() const {
  BridgeLock lock(impl_->lock);
  std::ostringstream output;
  output << "{\"schemaVersion\":1,\"configured\":" << (impl_->configured ? "true" : "false")
         << ",\"root\":\"" << JsonEscape(WideToUtf8(impl_->root.wstring())) << "\""
         << ",\"nextOutSeq\":" << impl_->next_out
         << ",\"nextReadSeq\":" << impl_->next_read
         << ",\"inboxPollMs\":" << impl_->inbox_poll_milliseconds
         << ",\"outboundQueued\":" << impl_->outbound.size()
         << ",\"inboundQueued\":" << impl_->inbound.size()
         << ",\"queuedBytes\":" << (impl_->outbound_bytes + impl_->inbound_bytes)
         << ",\"accepted\":" << impl_->accepted << ",\"written\":" << impl_->written
         << ",\"read\":" << impl_->read << ",\"taken\":" << impl_->taken
         << ",\"rejected\":" << impl_->rejected
         << ",\"lastError\":\"" << JsonEscape(impl_->last_error) << "\"}";
  return output.str();
}

bool AsyncFileBridge::IsConfigured() const {
  BridgeLock lock(impl_->lock);
  return impl_->configured;
}

void AsyncFileBridge::Reset() {
  BridgeLock lock(impl_->lock);
  impl_->configured = false;
  impl_->root.clear();
  impl_->next_inbox_path.clear();
  impl_->next_out = impl_->next_read = kMinimumSequence;
  impl_->outbound.clear();
  impl_->inbound.clear();
  impl_->outbound_bytes = impl_->inbound_bytes = 0;
  impl_->accepted = impl_->written = impl_->read = impl_->taken = impl_->rejected = 0;
  impl_->last_inbox_poll = impl_->next_write_retry = 0;
  impl_->inbox_poll_milliseconds = kInboxPollMilliseconds;
  impl_->last_error.clear();
}

AsyncFileBridge& Global() {
  static AsyncFileBridge bridge;
  return bridge;
}

std::uint64_t MonotonicMicroseconds() {
  static LARGE_INTEGER frequency{};
  static const bool available = QueryPerformanceFrequency(&frequency) != 0;
  LARGE_INTEGER now{};
  if (available && QueryPerformanceCounter(&now)) {
    return static_cast<std::uint64_t>((static_cast<long double>(now.QuadPart) * 1000000.0L) /
                                      static_cast<long double>(frequency.QuadPart));
  }
  return GetTickCount64() * 1000ULL;
}

void RegisterLuaApi(lua_State* state, const LuaPushLString push_string,
                    const LuaToLString to_string, const LuaGetTop get_top,
                    const LuaPushCClosure push_closure, const LuaRawSet raw_set) {
  g_push_string = push_string;
  g_to_string = to_string;
  g_get_top = get_top;
  Register(state, "tpf2mp_native_bridge_configure", GuardedLuaCall<NativeConfigure>, push_closure, raw_set);
  Register(state, "tpf2mp_native_bridge_emit", GuardedLuaCall<NativeEmit>, push_closure, raw_set);
  Register(state, "tpf2mp_native_bridge_take", GuardedLuaCall<NativeTake>, push_closure, raw_set);
  Register(state, "tpf2mp_native_bridge_status", GuardedLuaCall<NativeStatus>, push_closure, raw_set);
  Register(state, "tpf2mp_native_monotonic_us", GuardedLuaCall<NativeMonotonicMicroseconds>,
           push_closure, raw_set);
}

}  // namespace tpf2mp::async_bridge
