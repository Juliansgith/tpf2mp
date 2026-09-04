#include "tpf2mp/native_build_capture.hpp"

#include "tpf2mp/build_profile.hpp"
#include "tpf2mp/native_command_codec.hpp"
#include "tpf2mp/native_common.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <iterator>
#include <limits>
#include <sstream>
#include <utility>

namespace tpf2mp::native_build {
namespace {

using native_command::IsReadableRange;
using native_command::NativeVectorLayout;

template <typename Value>
bool ReadAt(const std::uint8_t* base, const std::size_t offset, Value& output) {
  if (base == nullptr || offset > std::numeric_limits<std::size_t>::max() - sizeof(Value)) {
    return false;
  }
  const auto* pointer = base + offset;
  if (!IsReadableRange(pointer, sizeof(Value))) return false;
  std::memcpy(&output, pointer, sizeof(Value));
  return true;
}

bool ReadVectorLayout(const std::uint8_t* proposal, const std::size_t offset,
                      const std::size_t stride, const std::size_t maximum,
                      NativeVectorLayout& layout, std::size_t& count,
                      std::string& error) {
  if (!ReadAt(proposal, offset, layout)) {
    error = "unreadable vector layout at " + std::to_string(offset);
    return false;
  }
  const auto begin = reinterpret_cast<std::uintptr_t>(layout.begin);
  const auto end = reinterpret_cast<std::uintptr_t>(layout.end);
  const auto capacity = reinterpret_cast<std::uintptr_t>(layout.capacity);
  if (begin == 0 || end == 0 || capacity == 0) {
    if (begin == 0 && end == 0 && capacity == 0) {
      count = 0;
      return true;
    }
    error = "partially null vector layout at " + std::to_string(offset);
    return false;
  }
  if (begin > end || end > capacity) {
    error = "reversed vector layout at " + std::to_string(offset);
    return false;
  }
  const auto used = end - begin;
  const auto reserved = capacity - begin;
  if (stride == 0 || used % stride != 0 || reserved % stride != 0) {
    error = "misaligned vector layout at " + std::to_string(offset);
    return false;
  }
  count = static_cast<std::size_t>(used / stride);
  if (count > maximum || reserved / stride > maximum * 4) {
    error = "vector exceeds capture bound at " + std::to_string(offset);
    return false;
  }
  if (used != 0 && !IsReadableRange(layout.begin, static_cast<std::size_t>(used))) {
    error = "unreadable vector contents at " + std::to_string(offset);
    return false;
  }
  return true;
}

bool ReadIntVector(const std::uint8_t* proposal, const std::size_t offset,
                   const std::size_t maximum, std::vector<std::int32_t>& output,
                   std::string& error) {
  NativeVectorLayout layout{};
  std::size_t count = 0;
  if (!ReadVectorLayout(proposal, offset, sizeof(std::int32_t), maximum,
                        layout, count, error)) {
    return false;
  }
  output.resize(count);
  if (count != 0) {
    std::memcpy(output.data(), layout.begin, count * sizeof(std::int32_t));
  }
  return true;
}

bool ReadNativeString(const std::uint8_t* value, std::string& output) {
  constexpr std::size_t kSizeOffset = 0x10;
  constexpr std::size_t kCapacityOffset = 0x18;
  constexpr std::size_t kSsoCapacity = 15;
  constexpr std::size_t kMaximumText = 512;
  std::uint64_t size = 0;
  std::uint64_t capacity = 0;
  if (!ReadAt(value, kSizeOffset, size) || !ReadAt(value, kCapacityOffset, capacity) ||
      size > kMaximumText || capacity < size) {
    return false;
  }
  const char* characters = reinterpret_cast<const char*>(value);
  if (capacity > kSsoCapacity) {
    if (!ReadAt(value, 0, characters) ||
        (size != 0 && !IsReadableRange(characters, static_cast<std::size_t>(size)))) {
      return false;
    }
  } else if (size != 0 && !IsReadableRange(characters, static_cast<std::size_t>(size))) {
    return false;
  }
  output.assign(characters, static_cast<std::size_t>(size));
  return output.find('\0') == std::string::npos;
}

bool ReadStringVector(const std::uint8_t* proposal, const std::size_t offset,
                      const std::size_t maximum, std::vector<std::string>& output,
                      std::string& error) {
  NativeVectorLayout layout{};
  std::size_t count = 0;
  if (!ReadVectorLayout(proposal, offset, profile::kProposalNativeStringSize,
                        maximum, layout, count, error)) {
    return false;
  }
  output.clear();
  output.reserve(count);
  for (std::size_t index = 0; index < count; ++index) {
    std::string value;
    if (!ReadNativeString(layout.begin + index * profile::kProposalNativeStringSize,
                          value)) {
      error = "invalid native string at " + std::to_string(offset) + ":" +
              std::to_string(index);
      output.clear();
      return false;
    }
    output.push_back(std::move(value));
  }
  return true;
}

bool ReadNodes(const std::uint8_t* proposal, const std::size_t offset,
               std::vector<ProposalNode>& output, std::string& error) {
  NativeVectorLayout layout{};
  std::size_t count = 0;
  if (!ReadVectorLayout(proposal, offset, profile::kProposalNodeRecordSize,
                        profile::kMaximumProposalNodes, layout, count, error)) {
    return false;
  }
  output.clear();
  output.reserve(count);
  for (std::size_t index = 0; index < count; ++index) {
    const auto* record = layout.begin + index * profile::kProposalNodeRecordSize;
    ProposalNode node;
    if (!ReadAt(record, 0x00, node.x) || !ReadAt(record, 0x04, node.y) ||
        !ReadAt(record, 0x08, node.z) || !ReadAt(record, 0x0C, node.flags) ||
        !ReadAt(record, 0x10, node.type) || !ReadAt(record, 0x14, node.entity) ||
        !std::isfinite(node.x) || !std::isfinite(node.y) || !std::isfinite(node.z)) {
      error = "invalid node record at " + std::to_string(offset) + ":" +
              std::to_string(index);
      output.clear();
      return false;
    }
    output.push_back(node);
  }
  return true;
}

bool ReadEdges(const std::uint8_t* proposal, const std::size_t offset,
               std::vector<ProposalEdge>& output, std::string& error) {
  NativeVectorLayout layout{};
  std::size_t count = 0;
  if (!ReadVectorLayout(proposal, offset, profile::kProposalEdgeRecordSize,
                        profile::kMaximumProposalEdges, layout, count, error)) {
    return false;
  }
  output.clear();
  output.reserve(count);
  for (std::size_t index = 0; index < count; ++index) {
    const auto* record = layout.begin + index * profile::kProposalEdgeRecordSize;
    ProposalEdge edge;
    const bool read =
        ReadAt(record, 0x00, edge.entity) &&
        ReadAt(record, 0x08, edge.node0) && ReadAt(record, 0x0C, edge.node1) &&
        ReadAt(record, 0x10, edge.tangent0_x) && ReadAt(record, 0x14, edge.tangent0_y) &&
        ReadAt(record, 0x18, edge.tangent0_z) && ReadAt(record, 0x1C, edge.tangent1_x) &&
        ReadAt(record, 0x20, edge.tangent1_y) && ReadAt(record, 0x24, edge.tangent1_z) &&
        ReadAt(record, 0x28, edge.word_28) && ReadAt(record, 0x2C, edge.word_2c) &&
        ReadAt(record, 0x48, edge.carrier) && ReadAt(record, 0x4C, edge.street_type) &&
        ReadAt(record, 0x50, edge.word_50) && ReadAt(record, 0x54, edge.tram_track_type) &&
        ReadAt(record, 0x60, edge.track_type) && ReadAt(record, 0x64, edge.flags_64) &&
        ReadAt(record, 0x68, edge.construction) && ReadAt(record, 0x6C, edge.word_6c) &&
        ReadAt(record, 0x70, edge.player) && ReadAt(record, 0x74, edge.player_owned);
    if (!read || !std::isfinite(edge.tangent0_x) || !std::isfinite(edge.tangent0_y) ||
        !std::isfinite(edge.tangent0_z) || !std::isfinite(edge.tangent1_x) ||
        !std::isfinite(edge.tangent1_y) || !std::isfinite(edge.tangent1_z)) {
      error = "invalid edge record at " + std::to_string(offset) + ":" +
              std::to_string(index);
      output.clear();
      return false;
    }
    output.push_back(edge);
  }
  return true;
}

bool ReadEdgeObjectEntities(const std::uint8_t* proposal, const std::size_t offset,
                            std::vector<std::int32_t>& output, std::string& error) {
  NativeVectorLayout layout{};
  std::size_t count = 0;
  if (!ReadVectorLayout(proposal, offset, profile::kProposalEdgeObjectRecordSize,
                        profile::kMaximumProposalEdgeObjects, layout, count, error)) {
    return false;
  }
  output.clear();
  output.reserve(count);
  for (std::size_t index = 0; index < count; ++index) {
    std::int32_t entity = -1;
    if (!ReadAt(layout.begin + index * profile::kProposalEdgeObjectRecordSize,
                0, entity)) {
      error = "invalid edge-object record at " + std::to_string(offset) + ":" +
              std::to_string(index);
      output.clear();
      return false;
    }
    output.push_back(entity);
  }
  return true;
}

bool ReadConstructions(const std::uint8_t* proposal,
                       std::vector<ProposalConstruction>& output,
                       std::string& error) {
  NativeVectorLayout layout{};
  std::size_t count = 0;
  if (!ReadVectorLayout(proposal, profile::kProposalConstructionsAddOffset,
                        profile::kProposalConstructionRecordSize,
                        profile::kMaximumProposalConstructions,
                        layout, count, error)) {
    return false;
  }
  output.clear();
  output.reserve(count);
  for (std::size_t index = 0; index < count; ++index) {
    const auto* record = layout.begin + index * profile::kProposalConstructionRecordSize;
    ProposalConstruction construction;
    if (!ReadNativeString(record, construction.file_name) ||
        !ReadAt(record, profile::kProposalConstructionTransformOffset,
                construction.transform) ||
        !std::all_of(construction.transform.begin(), construction.transform.end(),
                     [](const float value) { return std::isfinite(value); }) ||
        !ReadIntVector(record, profile::kProposalConstructionFrozenNodesOffset,
                       profile::kMaximumProposalIndices,
                       construction.frozen_nodes, error) ||
        !ReadAt(record, profile::kProposalConstructionSegmentsBeforeOffset,
                construction.segments_before)) {
      if (error.empty()) {
        error = "invalid construction record at " + std::to_string(index);
      }
      output.clear();
      return false;
    }
    output.push_back(std::move(construction));
  }
  return true;
}

void WriteFloat(std::ostream& output, const float value) {
  output << std::setprecision(std::numeric_limits<float>::max_digits10) << value;
}

void WriteIntArray(std::ostream& output, const std::vector<std::int32_t>& values) {
  output << '[';
  for (std::size_t index = 0; index < values.size(); ++index) {
    if (index != 0) output << ',';
    output << values[index];
  }
  output << ']';
}

void WriteNodes(std::ostream& output, const std::vector<ProposalNode>& values) {
  output << '[';
  for (std::size_t index = 0; index < values.size(); ++index) {
    if (index != 0) output << ',';
    const auto& node = values[index];
    output << "{\"e\":" << node.entity << ",\"x\":";
    WriteFloat(output, node.x);
    output << ",\"y\":";
    WriteFloat(output, node.y);
    output << ",\"z\":";
    WriteFloat(output, node.z);
    output << ",\"f\":" << node.flags << ",\"t\":" << node.type << '}';
  }
  output << ']';
}

void WriteEdges(std::ostream& output, const std::vector<ProposalEdge>& values) {
  output << '[';
  for (std::size_t index = 0; index < values.size(); ++index) {
    if (index != 0) output << ',';
    const auto& edge = values[index];
    output << "{\"e\":" << edge.entity << ",\"n0\":" << edge.node0
           << ",\"n1\":" << edge.node1 << ",\"t0\":[";
    WriteFloat(output, edge.tangent0_x); output << ',';
    WriteFloat(output, edge.tangent0_y); output << ',';
    WriteFloat(output, edge.tangent0_z); output << "],\"t1\":[";
    WriteFloat(output, edge.tangent1_x); output << ',';
    WriteFloat(output, edge.tangent1_y); output << ',';
    WriteFloat(output, edge.tangent1_z);
    output << "],\"w28\":" << edge.word_28 << ",\"w2c\":" << edge.word_2c
           << ",\"carrier\":" << edge.carrier
           << ",\"streetType\":" << edge.street_type
           << ",\"w50\":" << edge.word_50
           << ",\"tramTrackType\":" << edge.tram_track_type
           << ",\"trackType\":" << edge.track_type
           << ",\"f64\":" << edge.flags_64
           << ",\"construction\":" << edge.construction
           << ",\"w6c\":" << edge.word_6c
           << ",\"player\":" << edge.player
           << ",\"owned\":" << edge.player_owned << '}';
  }
  output << ']';
}

}  // namespace

BuildFactoryCaptureQueue::BuildFactoryCaptureQueue(const std::size_t pending_limit,
                                                   const std::size_t ready_limit)
    : pending_limit_(std::max<std::size_t>(1, pending_limit)),
      ready_limit_(std::max<std::size_t>(1, ready_limit)) {}

BuildFactoryCapture BuildFactoryCaptureQueue::Decode(
    const void* proposal_pointer, const std::uint64_t correlation,
    const std::uint32_t factory_caller_rva, const std::uint32_t factory_thread,
    const bool option_with_cost, const bool option_ignore_errors) {
  ++stats_.factory_calls;
  BuildFactoryCapture capture;
  capture.correlation = correlation;
  capture.factory_caller_rva = factory_caller_rva;
  capture.factory_thread = factory_thread;
  capture.option_with_cost = option_with_cost;
  capture.option_ignore_errors = option_ignore_errors;
  stats_.last_correlation = correlation;
  stats_.last_factory_caller_rva = factory_caller_rva;
  const auto* proposal = static_cast<const std::uint8_t*>(proposal_pointer);
  if (!IsReadableRange(proposal, profile::kProposalMinimumReadableSize)) {
    capture.error = "proposal header is unreadable";
  } else if (!ReadNodes(proposal, profile::kProposalAddedNodesOffset,
                        capture.added_nodes, capture.error) ||
             !ReadEdges(proposal, profile::kProposalAddedEdgesOffset,
                        capture.added_edges, capture.error) ||
             !ReadNodes(proposal, profile::kProposalRemovedNodesOffset,
                        capture.removed_nodes, capture.error) ||
             !ReadEdges(proposal, profile::kProposalRemovedEdgesOffset,
                        capture.removed_edges, capture.error) ||
             !ReadEdgeObjectEntities(proposal, profile::kProposalEdgeObjectsRemoveOffset,
                                     capture.edge_objects_to_remove, capture.error) ||
             !ReadEdgeObjectEntities(proposal, profile::kProposalEdgeObjectsAddOffset,
                                     capture.edge_objects_to_add, capture.error) ||
             !ReadIntVector(proposal, profile::kProposalFrozenNodeIndicesOffset,
                            profile::kMaximumProposalIndices,
                            capture.frozen_node_indices, capture.error) ||
             !ReadStringVector(proposal, profile::kProposalSegmentTagsOffset,
                               profile::kMaximumProposalEdges,
                               capture.segment_tags, capture.error) ||
             !ReadIntVector(proposal, profile::kProposalConstructionsRemoveOffset,
                            profile::kMaximumProposalConstructions,
                            capture.constructions_to_remove, capture.error) ||
             !ReadConstructions(proposal, capture.constructions_to_add,
                                capture.error)) {
    // The decoder assigned a precise bounded-read error.
  } else if (!capture.segment_tags.empty() &&
             capture.segment_tags.size() != capture.added_edges.size()) {
    capture.error = "segment-tag count does not match added-edge count";
  } else {
    capture.valid = true;
  }
  if (capture.valid) ++stats_.decoded; else ++stats_.invalid;
  return capture;
}

void BuildFactoryCaptureQueue::DropOldestPending() {
  if (pending_.empty()) return;
  pending_.pop_front();
  ++stats_.orphaned;
}

void BuildFactoryCaptureQueue::Commit(BuildFactoryCapture capture,
                                      const void* command,
                                      const void* command_data) {
  capture.generation = next_generation_++;
  capture.command = command;
  capture.command_data = command_data;
  stats_.last_generation = capture.generation;
  for (auto found = pending_.begin(); found != pending_.end();) {
    if ((command != nullptr && found->command == command) ||
        (command_data != nullptr && found->command_data == command_data)) {
      found = pending_.erase(found);
      ++stats_.orphaned;
    } else {
      ++found;
    }
  }
  while (pending_.size() >= pending_limit_) DropOldestPending();
  pending_.push_back(std::move(capture));
  stats_.pending = pending_.size();
}

void BuildFactoryCaptureQueue::ObserveAdd(const void* command,
                                          const std::uint32_t add_caller_rva,
                                          const std::uint32_t add_thread) {
  auto found = std::find_if(pending_.rbegin(), pending_.rend(),
                            [command](const BuildFactoryCapture& capture) {
                              return capture.command == command;
                            });
  if (found == pending_.rend()) {
    ++stats_.add_misses;
    return;
  }
  found->added = true;
  found->add_caller_rva = add_caller_rva;
  found->add_thread = add_thread;
  ++stats_.add_matches;
  stats_.last_add_caller_rva = add_caller_rva;
}

bool BuildFactoryCaptureQueue::PromoteSuppressed(const void* command_data) {
  auto found = std::find_if(pending_.rbegin(), pending_.rend(),
                             [command_data](const BuildFactoryCapture& capture) {
                               return capture.command_data == command_data;
                             });
  if (found == pending_.rend() || !found->added) {
    ++stats_.suppressed_misses;
    return false;
  }
  BuildFactoryCapture capture = std::move(*found);
  pending_.erase(std::prev(found.base()));
  ++stats_.suppressed_matches;
  if (ready_.size() >= ready_limit_) {
    stats_.dropped += static_cast<std::uint64_t>(ready_.size()) + 1;
    ready_.clear();
  } else {
    ready_.push_back(std::move(capture));
  }
  stats_.pending = pending_.size();
  stats_.ready = ready_.size();
  return true;
}

bool BuildFactoryCaptureQueue::DiscardObserved(const void* command_data) {
  auto found = std::find_if(pending_.rbegin(), pending_.rend(),
                            [command_data](const BuildFactoryCapture& capture) {
                              return capture.command_data == command_data;
                            });
  if (found == pending_.rend()) return false;
  pending_.erase(std::prev(found.base()));
  ++stats_.retired;
  stats_.pending = pending_.size();
  return true;
}

std::optional<std::string> BuildFactoryCaptureQueue::TakeEncoded() {
  if (drops_reported_ < stats_.dropped) {
    drops_reported_ = stats_.dropped;
    return "F1|build-factory-capture-overflow|" + std::to_string(stats_.dropped);
  }
  if (ready_.empty()) return std::nullopt;
  BuildFactoryCapture capture = std::move(ready_.front());
  ready_.pop_front();
  ++stats_.consumed;
  stats_.ready = ready_.size();
  return EncodeBuildFactoryCapture(capture);
}

void BuildFactoryCaptureQueue::ResetPending() {
  pending_.clear();
  ready_.clear();
  drops_reported_ = stats_.dropped;
  stats_.pending = 0;
  stats_.ready = 0;
}

BuildCaptureStats BuildFactoryCaptureQueue::stats() const {
  BuildCaptureStats result = stats_;
  result.pending = pending_.size();
  result.ready = ready_.size();
  return result;
}

bool BuildFactoryCaptureQueue::has_ready() const {
  return !ready_.empty() || drops_reported_ < stats_.dropped;
}

std::string_view BuildFactoryCallerType(const std::uint32_t rva) {
  // Exact return addresses observed at the pinned Build 35924 factory. Unknown
  // callers remain serializable and are classified by the correlated GUI
  // source rather than guessed from address ranges.
  switch (rva) {
    case 0x00459E97: return "street-builder";
    case 0x00419F62: return "construction-builder";
    case 0x004311C6: return "proposal-action";
    case 0x00CED378: return "lua-command-factory";
    default: return "unknown";
  }
}

std::string EncodeBuildFactoryCapture(const BuildFactoryCapture& capture) {
  std::ostringstream output;
  output << "{\"schemaVersion\":1,\"generation\":" << capture.generation
         << ",\"correlation\":" << capture.correlation
         << ",\"factoryCallerRva\":" << capture.factory_caller_rva
         << ",\"addCallerRva\":" << capture.add_caller_rva
         << ",\"callerType\":\"" << BuildFactoryCallerType(capture.factory_caller_rva)
         << "\",\"factoryThread\":" << capture.factory_thread
         << ",\"addThread\":" << capture.add_thread
         << ",\"withCost\":" << (capture.option_with_cost ? "true" : "false")
         << ",\"ignoreErrors\":" << (capture.option_ignore_errors ? "true" : "false")
         << ",\"valid\":" << (capture.valid ? "true" : "false")
         << ",\"error\":\"" << tpf2mp::JsonEscape(capture.error) << "\""
         << ",\"addedNodes\":";
  WriteNodes(output, capture.added_nodes);
  output << ",\"addedEdges\":";
  WriteEdges(output, capture.added_edges);
  output << ",\"removedNodes\":";
  WriteNodes(output, capture.removed_nodes);
  output << ",\"removedEdges\":";
  WriteEdges(output, capture.removed_edges);
  output << ",\"edgeObjectsToRemove\":";
  WriteIntArray(output, capture.edge_objects_to_remove);
  output << ",\"edgeObjectsToAdd\":";
  WriteIntArray(output, capture.edge_objects_to_add);
  output << ",\"frozenNodeIndices\":";
  WriteIntArray(output, capture.frozen_node_indices);
  output << ",\"segmentTags\":[";
  for (std::size_t index = 0; index < capture.segment_tags.size(); ++index) {
    if (index != 0) output << ',';
    output << '\"' << tpf2mp::JsonEscape(capture.segment_tags[index]) << '\"';
  }
  output << "],\"constructionsToRemove\":";
  WriteIntArray(output, capture.constructions_to_remove);
  output << ",\"constructionsToAdd\":[";
  for (std::size_t index = 0; index < capture.constructions_to_add.size(); ++index) {
    if (index != 0) output << ',';
    const auto& construction = capture.constructions_to_add[index];
    output << "{\"fileName\":\"" << tpf2mp::JsonEscape(construction.file_name)
           << "\",\"transform\":[";
    for (std::size_t transform_index = 0;
         transform_index < construction.transform.size(); ++transform_index) {
      if (transform_index != 0) output << ',';
      WriteFloat(output, construction.transform[transform_index]);
    }
    output << "],\"frozenNodes\":";
    WriteIntArray(output, construction.frozen_nodes);
    output << ",\"segmentsBefore\":" << construction.segments_before << '}';
  }
  output << "]}";
  return output.str();
}

}  // namespace tpf2mp::native_build
