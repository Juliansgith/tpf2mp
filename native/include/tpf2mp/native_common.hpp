#pragma once

#include <Windows.h>

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "tpf2mp/build_profile.hpp"

namespace tpf2mp {

struct SignatureResult {
  std::string name;
  std::uint32_t expected_rva{};
  std::uint32_t observed_rva{};
  std::size_t matches{};
  bool expected_bytes_match{};
};

struct ValidationResult {
  bool valid{};
  std::filesystem::path path;
  std::string sha256;
  std::uint32_t pe_timestamp{};
  std::uint32_t image_size{};
  std::uint16_t machine{};
  std::vector<SignatureResult> signatures;
  std::string error;
};

std::string WideToUtf8(const std::wstring& value);
std::wstring Utf8ToWide(const std::string& value);
std::string JsonEscape(const std::string& value);
std::string HexPointer(const void* value);
std::string Sha256File(const std::filesystem::path& path, std::string& error);
ValidationResult ValidatePinnedExecutable(const std::filesystem::path& path);
ValidationResult ValidatePinnedModule(HMODULE module);
std::filesystem::path CurrentExecutablePath();
std::filesystem::path NativeStatusDirectory();
std::filesystem::path NativeStatusPath(DWORD process_id);
bool AtomicWriteUtf8(const std::filesystem::path& path, const std::string& value,
                     std::string& error, bool durable = true);

} // namespace tpf2mp
