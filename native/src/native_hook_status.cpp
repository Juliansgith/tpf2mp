#include "tpf2mp/native_hook_status.hpp"

#include "tpf2mp/build_profile.hpp"

#include <array>
#include <sstream>

namespace tpf2mp::native_status {

using native_command::CommandTypeName;
using native_command::SumTagCounts;
using native_command::WriteTagCounts;

std::string SerializeHookStatus(const HookStatusView& status) {
  std::ostringstream output;
  output << "{\"schemaVersion\":1"
         << ",\"component\":\"tpf2mp-native-hook\""
         << ",\"hookVersion\":\"0.15.0\""
         << ",\"profile\":\"" << tpf2mp::JsonEscape(std::string(tpf2mp::profile::kProfileName)) << "\""
         << ",\"processId\":" << status.process_id
         << ",\"stage\":\"" << tpf2mp::JsonEscape(status.stage) << "\""
         << ",\"active\":" << (status.hooks.enabled ? "true" : "false")
         << ",\"executablePath\":\"" << tpf2mp::JsonEscape(tpf2mp::WideToUtf8(status.validation.path.wstring())) << "\""
         << ",\"dllPath\":\"" << tpf2mp::JsonEscape(tpf2mp::WideToUtf8(status.dll_path.wstring())) << "\""
         << ",\"validation\":{"
         << "\"valid\":" << (status.validation.valid ? "true" : "false")
         << ",\"expectedSha256\":\"" << tpf2mp::profile::kSha256 << "\""
         << ",\"observedSha256\":\"" << tpf2mp::JsonEscape(status.validation.sha256) << "\""
         << ",\"expectedTimestamp\":" << tpf2mp::profile::kPeTimestamp
         << ",\"observedTimestamp\":" << status.validation.pe_timestamp
         << ",\"expectedImageSize\":" << tpf2mp::profile::kImageSize
         << ",\"observedImageSize\":" << status.validation.image_size
         << ",\"error\":\"" << tpf2mp::JsonEscape(status.validation.error) << "\""
         << ",\"signatures\":[";
  for (std::size_t index = 0; index < status.validation.signatures.size(); ++index) {
    const auto& signature = status.validation.signatures[index];
    if (index != 0) output << ',';
    output << "{\"name\":\"" << tpf2mp::JsonEscape(signature.name) << "\""
           << ",\"expectedRva\":" << signature.expected_rva
           << ",\"observedRva\":" << signature.observed_rva
           << ",\"matches\":" << signature.matches
           << ",\"valid\":" << (signature.expected_bytes_match ? "true" : "false") << '}';
  }
  output << "]}"
         << ",\"hooks\":{"
         << "\"minHookInitialised\":" << (status.hooks.minhook_initialised ? "true" : "false")
         << ",\"luaPrint\":" << (status.hooks.lua_print_created ? "true" : "false")
         << ",\"luaSetField\":" << (status.hooks.lua_setfield_created ? "true" : "false")
         << ",\"setupCommandInterface\":" << (status.hooks.setup_command_created ? "true" : "false")
         << ",\"commandListSwap\":" << (status.hooks.command_list_swap_created ? "true" : "false")
         << ",\"applyCommand\":" << (status.hooks.apply_command_created ? "true" : "false")
         << ",\"buildProposalVisitor\":"
         << (status.hooks.build_proposal_visitor_created ? "true" : "false")
         << ",\"authorityCommandVisitors\":"
         << status.hooks.authority_command_visitors_created
         << ",\"sendCommandWrapping\":true"
         << ",\"enabled\":" << (status.hooks.enabled ? "true" : "false") << '}';
  output << ",\"setupCommandInterface\":{" 
         << "\"calls\":" << status.setup_calls
         << ",\"lastThread\":" << status.setup_last_thread
         << ",\"lastArgs\":[";
  for (std::size_t index = 0; index < status.setup_last_args.size(); ++index) {
    if (index != 0) output << ',';
    output << '"' << tpf2mp::JsonEscape(status.setup_last_args[index]) << '"';
  }
  output << "]}"
         << ",\"commandList\":{"
         << "\"swapCalls\":" << status.command_swap_calls
         << ",\"nonEmptyBatches\":" << status.command_nonempty_batches
         << ",\"commands\":" << status.command_queued
         << ",\"invalidLayouts\":" << status.command_invalid_layouts
         << ",\"unknownTags\":" << status.command_unknown_tags
         << ",\"lastBatchCount\":" << status.command_last_batch
         << ",\"lastBatchId\":" << status.command_last_batch_id
         << ",\"pendingCommands\":" << status.pending_commands
         << ",\"pendingOverwrites\":" << status.command_pending_overwrites
         << ",\"lastThread\":" << status.command_swap_last_thread
         << ",\"tagCounts\":";
  WriteTagCounts(output, status.queued_tags);
  output << '}'
         << ",\"applyCommand\":{"
         << "\"calls\":" << status.apply_calls
         << ",\"succeeded\":" << status.apply_succeeded
         << ",\"failed\":" << status.apply_failed
         << ",\"unknown\":" << status.apply_unknown
         << ",\"unknownTags\":" << status.apply_unknown_tags
         << ",\"direct\":" << status.apply_direct
         << ",\"tagMismatches\":" << status.apply_tag_mismatches
         << ",\"filteredScriptEvents\":" << status.apply_filtered_script_events
         << ",\"lastTag\":" << status.apply_last_tag
         << ",\"lastTagName\":\"" << CommandTypeName(status.apply_last_tag) << "\""
         << ",\"lastThread\":" << status.apply_last_thread
         << ",\"tagCounts\":";
  WriteTagCounts(output, status.applied_tags);
  output << '}'
         << ",\"commandEvents\":[";
  bool first_command_event = true;
  for (const auto& event : status.completed_commands) {
    if (!first_command_event) output << ',';
    first_command_event = false;
    output << "{\"localSequence\":" << event.pending.local_sequence
           << ",\"batch\":" << event.pending.batch
           << ",\"index\":" << event.pending.index
           << ",\"tag\":" << event.pending.tag
           << ",\"name\":\"" << CommandTypeName(event.pending.tag) << "\""
           << ",\"queueThread\":" << event.pending.queue_thread
           << ",\"applyThread\":" << event.apply_thread
           << ",\"success\":";
    if (event.success < 0) {
      output << "null";
    } else {
      output << (event.success > 0 ? "true" : "false");
    }
    output << '}';
  }
  output << ']'
         << ",\"recentCommandEvents\":[";
  first_command_event = true;
  for (const auto& event : status.recent_completed_commands) {
    if (!first_command_event) output << ',';
    first_command_event = false;
    output << "{\"localSequence\":" << event.pending.local_sequence
           << ",\"batch\":" << event.pending.batch
           << ",\"index\":" << event.pending.index
           << ",\"tag\":" << event.pending.tag
           << ",\"name\":\"" << CommandTypeName(event.pending.tag) << "\""
           << ",\"success\":";
    if (event.success < 0) {
      output << "null";
    } else {
      output << (event.success > 0 ? "true" : "false");
    }
    output << '}';
  }
  output << ']'
         << ",\"commandEventFilter\":\"commandEvents retains non-SendScriptEvent commands; recentCommandEvents retains the latest 64 commands\""
         << ",\"gates\":{\"buildProposal\":{"
         << "\"enabled\":" << (status.build_gate_enabled ? "true" : "false")
         << ",\"authorizations\":" << status.build_gate_authorizations
         << ",\"allowed\":" << status.build_gate_allowed
         << ",\"suppressed\":" << status.build_gate_suppressed
         << ",\"calls\":" << status.build_gate_calls
         << ",\"tagMismatches\":" << status.build_gate_tag_mismatches
         << ",\"lastTag\":" << status.build_gate_last_tag
         << ",\"lastThread\":" << status.build_gate_last_thread
         << "},\"commandVisitors\":{"
         << "\"enabled\":" << (status.command_gate_enabled ? "true" : "false")
         << ",\"hooked\":" << status.hooks.authority_command_visitors_created
         << ",\"tagMismatches\":" << status.command_gate_tag_mismatches
         << ",\"pendingTotal\":" << SumTagCounts(status.command_gate_authorizations)
         << ",\"allowedTotal\":" << SumTagCounts(status.command_gate_allowed)
         << ",\"suppressedTotal\":" << SumTagCounts(status.command_gate_suppressed)
         << ",\"gatedTags\":";
  native_command::TagCounts gated_tags{};
  for (const auto& visitor : tpf2mp::profile::kAuthorityCommandVisitors) {
    gated_tags[visitor.tag] = 1;
  }
  WriteTagCounts(output, gated_tags);
  output << ",\"pending\":";
  WriteTagCounts(output, status.command_gate_authorizations);
  output << ",\"allowed\":";
  WriteTagCounts(output, status.command_gate_allowed);
  output << ",\"suppressed\":";
  WriteTagCounts(output, status.command_gate_suppressed);
  output << ",\"optimisticPassthrough\":";
  WriteTagCounts(output, status.command_gate_passthrough);
  output << ",\"calls\":";
  WriteTagCounts(output, status.command_gate_calls);
  output << ",\"suppressedGameSpeed\":{"
         << "\"queued\":" << status.suppressed_game_speed_queued
         << ",\"captured\":" << status.suppressed_game_speed_captured
         << ",\"consumed\":" << status.suppressed_game_speed_consumed
         << ",\"invalid\":" << status.suppressed_game_speed_invalid
         << ",\"dropped\":" << status.suppressed_game_speed_dropped
         << ",\"last\":" << status.suppressed_game_speed_last
         << "},\"suppressedLineCommands\":{"
         << "\"queued\":" << status.suppressed_line_command_queued
         << ",\"captured\":" << status.suppressed_line_command_captured
         << ",\"consumed\":" << status.suppressed_line_command_consumed
         << ",\"invalid\":" << status.suppressed_line_command_invalid
         << ",\"dropped\":" << status.suppressed_line_command_dropped
         << ",\"lastTag\":" << status.suppressed_line_command_last_tag
         << ",\"lastTarget\":" << status.suppressed_line_command_last_target
         << ",\"lastStopCount\":" << status.suppressed_line_command_last_stop_count
         << "},\"suppressedVehicleCommands\":{"
         << "\"queued\":" << status.suppressed_vehicle_command_queued
         << ",\"captured\":" << status.suppressed_vehicle_command_captured
         << ",\"consumed\":" << status.suppressed_vehicle_command_consumed
         << ",\"invalid\":" << status.suppressed_vehicle_command_invalid
         << ",\"dropped\":" << status.suppressed_vehicle_command_dropped
         << ",\"lastTag\":" << status.suppressed_vehicle_command_last_tag
         << ",\"lastTarget\":" << status.suppressed_vehicle_command_last_target
         << ",\"lastSecondary\":" << status.suppressed_vehicle_command_last_secondary
         << "}}}"
         << ",\"luaStates\":[";
  bool first_state = true;
  for (const auto& [_, state] : status.states) {
    if (!first_state) output << ',';
    first_state = false;
    output << "{\"pointer\":\"" << state.pointer << "\""
           << ",\"context\":\"" << tpf2mp::JsonEscape(state.context) << "\""
           << ",\"firstThread\":" << state.first_thread
           << ",\"lastThread\":" << state.last_thread
           << ",\"printCalls\":" << state.print_calls
           << ",\"commandCalls\":" << state.command_calls
           << ",\"lastCommandArgumentCount\":" << state.last_command_argument_count
           << ",\"lastCommandThread\":" << state.last_command_thread
           << ",\"setFieldCalls\":" << state.setfield_calls
            << ",\"nativeApiRegistered\":" << (state.native_api_registered ? "true" : "false")
            << ",\"sendCommandWrapped\":" << (state.send_command_wrapped ? "true" : "false")
            << ",\"commandObserverRegistered\":"
            << (state.command_observer_registered ? "true" : "false")
           << ",\"bindings\":[";
    bool first_binding = true;
    for (const auto& binding : state.interesting_bindings) {
      if (!first_binding) output << ',';
      first_binding = false;
      output << '"' << tpf2mp::JsonEscape(binding) << '"';
    }
    output << "]"
           << ",\"mirroredBindings\":[";
    bool first_mirrored_binding = true;
    for (const auto& binding : state.mirrored_bindings) {
      if (!first_mirrored_binding) output << ',';
      first_mirrored_binding = false;
      output << '"' << tpf2mp::JsonEscape(binding) << '"';
    }
    output << "]}";
  }
  output << "]"
         << ",\"scope\":\"Lua command-binding mirrors, sendCommand call-through with an opt-in pre-issue Lua observer, native command observers, a BuildProposal visitor gate, 23 fail-closed consequential-command visitors, suppressed game-speed capture, exact-build typed line capture, and pre-mutation SetLine/BuyVehicle scalar capture\""
         << ",\"lastError\":\"" << tpf2mp::JsonEscape(status.last_error) << "\"}";
  return output.str();
}

}  // namespace tpf2mp::native_status
