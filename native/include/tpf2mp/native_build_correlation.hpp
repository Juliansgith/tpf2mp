#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <string_view>

namespace tpf2mp::native_build {

struct SuppressedBuildEvent {
  std::uint64_t generation{};
  std::uint64_t correlation{};
  int tag{-1};
};

// The BuildProposal visitor and the GUI Lua state run on different callback
// boundaries.  This bounded queue is the hand-off: Lua arms the latest preview
// token, and every suppressed visitor records that token alongside its own
// process-monotonic generation.  Callers provide external synchronisation.
class SuppressedBuildQueue {
 public:
  explicit SuppressedBuildQueue(std::size_t limit = 64);

  void Arm(std::uint64_t correlation);
  std::uint64_t Capture(int tag);
  std::optional<std::string> TakeEncoded();
  void ResetPending();

  [[nodiscard]] std::uint64_t armed_correlation() const;
  [[nodiscard]] std::uint64_t last_correlation() const;
  [[nodiscard]] std::uint64_t last_generation() const;
  [[nodiscard]] std::uint64_t captured() const;
  [[nodiscard]] std::uint64_t consumed() const;
  [[nodiscard]] std::uint64_t dropped() const;
  [[nodiscard]] std::size_t queued() const;
  [[nodiscard]] bool has_pending() const;

 private:
  std::size_t limit_;
  std::deque<SuppressedBuildEvent> events_;
  std::uint64_t armed_correlation_{};
  std::uint64_t last_correlation_{};
  std::uint64_t next_generation_{1};
  std::uint64_t last_generation_{};
  std::uint64_t captured_{};
  std::uint64_t consumed_{};
  std::uint64_t dropped_{};
  std::uint64_t drops_reported_{};
};

bool ParseCorrelationToken(std::string_view text, std::uint64_t& value);
std::string EncodeSuppressedBuildEvent(const SuppressedBuildEvent& event);

}  // namespace tpf2mp::native_build
