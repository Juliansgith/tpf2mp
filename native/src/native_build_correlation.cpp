#include "tpf2mp/native_build_correlation.hpp"

#include <charconv>
#include <limits>
#include <system_error>

namespace tpf2mp::native_build {

SuppressedBuildQueue::SuppressedBuildQueue(std::size_t limit)
    : limit_(limit == 0 ? 1 : limit) {}

void SuppressedBuildQueue::Arm(std::uint64_t correlation) {
  armed_correlation_ = correlation;
}

std::uint64_t SuppressedBuildQueue::Capture(int tag) {
  const std::uint64_t generation = next_generation_++;
  last_generation_ = generation;
  last_correlation_ = armed_correlation_;
  ++captured_;
  if (events_.size() >= limit_) {
    // Once one event is lost, no surviving prefix can be trusted to represent
    // the player's click stream. Discard it and publish one sticky fault token.
    dropped_ += static_cast<std::uint64_t>(events_.size()) + 1;
    events_.clear();
    return generation;
  }
  events_.push_back(SuppressedBuildEvent{generation, armed_correlation_, tag});
  return generation;
}

std::optional<std::string> SuppressedBuildQueue::TakeEncoded() {
  if (drops_reported_ < dropped_) {
    drops_reported_ = dropped_;
    return "F1|suppressed-build-queue-overflow|" + std::to_string(dropped_);
  }
  if (events_.empty()) return std::nullopt;
  const SuppressedBuildEvent event = events_.front();
  events_.pop_front();
  ++consumed_;
  return EncodeSuppressedBuildEvent(event);
}

void SuppressedBuildQueue::ResetPending() {
  events_.clear();
  drops_reported_ = dropped_;
  armed_correlation_ = 0;
}

std::uint64_t SuppressedBuildQueue::armed_correlation() const { return armed_correlation_; }
std::uint64_t SuppressedBuildQueue::last_correlation() const { return last_correlation_; }
std::uint64_t SuppressedBuildQueue::last_generation() const { return last_generation_; }
std::uint64_t SuppressedBuildQueue::captured() const { return captured_; }
std::uint64_t SuppressedBuildQueue::consumed() const { return consumed_; }
std::uint64_t SuppressedBuildQueue::dropped() const { return dropped_; }
std::size_t SuppressedBuildQueue::queued() const { return events_.size(); }
bool SuppressedBuildQueue::has_pending() const {
  return !events_.empty() || drops_reported_ < dropped_;
}

bool ParseCorrelationToken(std::string_view text, std::uint64_t& value) {
  if (text.empty() || text.size() > 20) return false;
  std::uint64_t parsed = 0;
  const char* begin = text.data();
  const char* end = begin + text.size();
  const auto result = std::from_chars(begin, end, parsed, 10);
  if (result.ec != std::errc{} || result.ptr != end) return false;
  // Zero deliberately means "disarmed"; all positive uint64 values are valid.
  value = parsed;
  return true;
}

std::string EncodeSuppressedBuildEvent(const SuppressedBuildEvent& event) {
  return "S1|" + std::to_string(event.generation) + "|" +
         std::to_string(event.correlation) + "|" + std::to_string(event.tag);
}

}  // namespace tpf2mp::native_build
