#pragma once

#include "tpf2mp/native_command_codec.hpp"
#include "tpf2mp/native_common.hpp"

#include <Windows.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <string_view>

namespace tpf2mp::native_status {

struct PendingNativeCommand {
  std::uint64_t local_sequence{};
  std::uint64_t batch{};
  std::uint64_t index{};
  int tag{-1};
  DWORD queue_thread{};
};

struct CompletedNativeCommand {
  PendingNativeCommand pending;
  DWORD apply_thread{};
  int success{-1};
};

struct LuaStateObservation {
  std::string pointer;
  std::string context = "unknown";
  DWORD first_thread{};
  DWORD last_thread{};
  std::uint64_t print_calls{};
  std::uint64_t command_calls{};
  int last_command_argument_count{};
  DWORD last_command_thread{};
  std::uint64_t setfield_calls{};
  bool native_api_registered{};
  bool send_command_wrapped{};
  bool command_observer_registered{};
  std::set<std::string> interesting_bindings;
  std::set<std::string> mirrored_bindings;
};

struct HookFlags {
  bool minhook_initialised{};
  bool lua_print_created{};
  bool lua_setfield_created{};
  bool setup_command_created{};
  bool command_list_swap_created{};
  bool apply_command_created{};
  bool build_proposal_visitor_created{};
  std::uint64_t authority_command_visitors_created{};
  bool enabled{};
};

struct HookStatusView {
  DWORD process_id{};
  const std::string& stage;
  const std::string& last_error;
  const std::filesystem::path& dll_path;
  const ValidationResult& validation;
  const HookFlags& hooks;

  std::uint64_t setup_calls{};
  DWORD setup_last_thread{};
  const std::array<std::string, 4>& setup_last_args;

  std::uint64_t command_swap_calls{};
  std::uint64_t command_nonempty_batches{};
  std::uint64_t command_queued{};
  std::uint64_t command_invalid_layouts{};
  std::uint64_t command_unknown_tags{};
  std::uint64_t command_last_batch{};
  std::uint64_t command_last_batch_id{};
  std::size_t pending_commands{};
  std::uint64_t command_pending_overwrites{};
  DWORD command_swap_last_thread{};
  const native_command::TagCounts& queued_tags;

  std::uint64_t apply_calls{};
  std::uint64_t apply_succeeded{};
  std::uint64_t apply_failed{};
  std::uint64_t apply_unknown{};
  std::uint64_t apply_unknown_tags{};
  std::uint64_t apply_direct{};
  std::uint64_t apply_tag_mismatches{};
  std::uint64_t apply_filtered_script_events{};
  int apply_last_tag{-1};
  DWORD apply_last_thread{};
  const native_command::TagCounts& applied_tags;
  const std::deque<CompletedNativeCommand>& completed_commands;
  const std::deque<CompletedNativeCommand>& recent_completed_commands;

  bool build_gate_enabled{};
  std::uint64_t build_gate_authorizations{};
  std::uint64_t build_gate_allowed{};
  std::uint64_t build_gate_suppressed{};
  std::uint64_t build_gate_calls{};
  std::uint64_t build_gate_tag_mismatches{};
  int build_gate_last_tag{-1};
  DWORD build_gate_last_thread{};
  std::size_t suppressed_build_queued{};
  std::uint64_t suppressed_build_captured{};
  std::uint64_t suppressed_build_consumed{};
  std::uint64_t suppressed_build_dropped{};
  std::uint64_t suppressed_build_last_generation{};
  std::uint64_t suppressed_build_armed_correlation{};
  std::uint64_t suppressed_build_last_correlation{};

  bool command_gate_enabled{};
  std::uint64_t command_gate_tag_mismatches{};
  const native_command::TagCounts& command_gate_authorizations;
  const native_command::TagCounts& command_gate_allowed;
  const native_command::TagCounts& command_gate_suppressed;
  const native_command::TagCounts& command_gate_passthrough;
  const native_command::TagCounts& command_gate_calls;

  std::size_t suppressed_game_speed_queued{};
  std::uint64_t suppressed_game_speed_captured{};
  std::uint64_t suppressed_game_speed_consumed{};
  std::uint64_t suppressed_game_speed_invalid{};
  std::uint64_t suppressed_game_speed_dropped{};
  int suppressed_game_speed_last{-1};

  std::size_t suppressed_line_command_queued{};
  std::uint64_t suppressed_line_command_captured{};
  std::uint64_t suppressed_line_command_consumed{};
  std::uint64_t suppressed_line_command_invalid{};
  std::uint64_t suppressed_line_command_dropped{};
  int suppressed_line_command_last_tag{-1};
  std::int32_t suppressed_line_command_last_target{-1};
  std::size_t suppressed_line_command_last_stop_count{};

  std::size_t suppressed_vehicle_command_queued{};
  std::uint64_t suppressed_vehicle_command_captured{};
  std::uint64_t suppressed_vehicle_command_consumed{};
  std::uint64_t suppressed_vehicle_command_invalid{};
  std::uint64_t suppressed_vehicle_command_dropped{};
  int suppressed_vehicle_command_last_tag{-1};
  std::int32_t suppressed_vehicle_command_last_target{-1};
  std::int32_t suppressed_vehicle_command_last_secondary{-1};

  const std::map<void*, LuaStateObservation>& states;
};

std::string SerializeHookStatus(const HookStatusView& status);

}  // namespace tpf2mp::native_status
