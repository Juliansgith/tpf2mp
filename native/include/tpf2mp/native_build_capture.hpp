#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace tpf2mp::native_build {

struct ProposalNode {
  float x{};
  float y{};
  float z{};
  std::uint32_t flags{};
  std::int32_t type{};
  std::int32_t entity{};
};

// Pointer-free projection of the complete scalar portion of Build 35924's
// SegmentAndEntity.  Keeping the otherwise poorly named words is intentional:
// modded street/track resources can attach semantics to fields that vanilla
// does not exercise, and dropping one here would make an early capture less
// complete than the native proposal it is meant to attest.
struct ProposalEdge {
  std::int32_t entity{};
  std::int32_t node0{};
  std::int32_t node1{};
  float tangent0_x{};
  float tangent0_y{};
  float tangent0_z{};
  float tangent1_x{};
  float tangent1_y{};
  float tangent1_z{};
  std::int32_t word_28{};
  std::int32_t word_2c{};
  std::int32_t carrier{};
  std::int32_t street_type{};
  std::uint32_t word_50{};
  std::int32_t tram_track_type{};
  std::int32_t track_type{};
  std::uint32_t flags_64{};
  std::int32_t construction{};
  std::int32_t word_6c{};
  std::int32_t player{};
  std::uint32_t player_owned{};
};

struct ProposalConstruction {
  std::string file_name;
  std::array<float, 16> transform{};
  std::vector<std::int32_t> frozen_nodes;
  std::int32_t segments_before{};
};

struct BuildFactoryCapture {
  std::uint64_t generation{};
  std::uint64_t correlation{};
  std::uint32_t factory_caller_rva{};
  std::uint32_t add_caller_rva{};
  std::uint32_t factory_thread{};
  std::uint32_t add_thread{};
  bool option_with_cost{};
  bool option_ignore_errors{};
  bool valid{};
  std::string error;
  std::vector<ProposalNode> added_nodes;
  std::vector<ProposalEdge> added_edges;
  std::vector<ProposalNode> removed_nodes;
  std::vector<ProposalEdge> removed_edges;
  std::vector<std::int32_t> edge_objects_to_remove;
  std::vector<std::int32_t> edge_objects_to_add;
  std::vector<std::int32_t> frozen_node_indices;
  std::vector<std::string> segment_tags;
  std::vector<std::int32_t> constructions_to_remove;
  std::vector<ProposalConstruction> constructions_to_add;

  // Process-local identities are retained only while correlating the factory,
  // Add, and visitor boundaries.  They are never serialized to Lua or relay.
  const void* command{};
  const void* command_data{};
  bool added{};
};

struct BuildCaptureStats {
  std::uint64_t factory_calls{};
  std::uint64_t decoded{};
  std::uint64_t invalid{};
  std::uint64_t add_matches{};
  std::uint64_t add_misses{};
  std::uint64_t suppressed_matches{};
  std::uint64_t suppressed_misses{};
  std::uint64_t consumed{};
  // Captures retired before publication are diagnostic lifecycle events, not
  // lost evidence. Only `dropped` makes TakeEncoded emit a sticky fault.
  std::uint64_t retired{};
  std::uint64_t orphaned{};
  std::uint64_t dropped{};
  std::size_t pending{};
  std::size_t ready{};
  std::uint64_t last_generation{};
  std::uint64_t last_correlation{};
  std::uint32_t last_factory_caller_rva{};
  std::uint32_t last_add_caller_rva{};
};

// BuildProposal is decoded synchronously at factory entry, before either the
// command queue or simulation can mutate the world.  The resulting capture is
// published only if the same Command reaches CommandList::Add and the same
// command-data pointer later reaches the suppressed tag-15 visitor.
// Callers provide external synchronization.
class BuildFactoryCaptureQueue {
 public:
  explicit BuildFactoryCaptureQueue(std::size_t pending_limit = 32,
                                    std::size_t ready_limit = 16);

  BuildFactoryCapture Decode(const void* proposal, std::uint64_t correlation,
                             std::uint32_t factory_caller_rva,
                             std::uint32_t factory_thread,
                             bool option_with_cost,
                             bool option_ignore_errors);
  void Commit(BuildFactoryCapture capture, const void* command,
              const void* command_data);
  void ObserveAdd(const void* command, std::uint32_t add_caller_rva,
                  std::uint32_t add_thread);
  bool PromoteSuppressed(const void* command_data);
  bool DiscardObserved(const void* command_data);
  std::optional<std::string> TakeEncoded();
  void ResetPending();

  [[nodiscard]] BuildCaptureStats stats() const;
  [[nodiscard]] bool has_ready() const;

 private:
  void DropOldestPending();

  std::size_t pending_limit_;
  std::size_t ready_limit_;
  std::deque<BuildFactoryCapture> pending_;
  std::deque<BuildFactoryCapture> ready_;
  BuildCaptureStats stats_;
  std::uint64_t next_generation_{1};
  std::uint64_t drops_reported_{};
};

std::string EncodeBuildFactoryCapture(const BuildFactoryCapture& capture);
std::string_view BuildFactoryCallerType(std::uint32_t rva);

}  // namespace tpf2mp::native_build
