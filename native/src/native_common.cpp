#include "tpf2mp/native_common.hpp"

#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <system_error>

namespace tpf2mp {
namespace {

struct ParsedPe {
  std::vector<std::uint8_t> bytes;
  const IMAGE_DOS_HEADER* dos{};
  const IMAGE_NT_HEADERS64* nt{};
  const IMAGE_SECTION_HEADER* sections{};
};

bool ReadPe(const std::filesystem::path& path, ParsedPe& result, std::string& error) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) {
    error = "cannot open executable";
    return false;
  }
  const auto size = input.tellg();
  if (size <= 0 || size > static_cast<std::streamoff>(512ULL * 1024ULL * 1024ULL)) {
    error = "executable size is invalid";
    return false;
  }
  result.bytes.resize(static_cast<std::size_t>(size));
  input.seekg(0);
  input.read(reinterpret_cast<char*>(result.bytes.data()), size);
  if (!input) {
    error = "cannot read complete executable";
    return false;
  }
  if (result.bytes.size() < sizeof(IMAGE_DOS_HEADER)) {
    error = "file is smaller than a DOS header";
    return false;
  }
  result.dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(result.bytes.data());
  if (result.dos->e_magic != IMAGE_DOS_SIGNATURE || result.dos->e_lfanew < 0) {
    error = "invalid DOS header";
    return false;
  }
  const auto nt_offset = static_cast<std::size_t>(result.dos->e_lfanew);
  if (nt_offset + sizeof(IMAGE_NT_HEADERS64) > result.bytes.size()) {
    error = "invalid PE header offset";
    return false;
  }
  result.nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(result.bytes.data() + nt_offset);
  if (result.nt->Signature != IMAGE_NT_SIGNATURE ||
      result.nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
    error = "file is not a PE32+ executable";
    return false;
  }
  const auto section_offset = nt_offset + offsetof(IMAGE_NT_HEADERS64, OptionalHeader) +
                              result.nt->FileHeader.SizeOfOptionalHeader;
  const auto section_bytes = static_cast<std::size_t>(result.nt->FileHeader.NumberOfSections) *
                             sizeof(IMAGE_SECTION_HEADER);
  if (section_offset + section_bytes > result.bytes.size()) {
    error = "section table extends past end of file";
    return false;
  }
  result.sections = reinterpret_cast<const IMAGE_SECTION_HEADER*>(result.bytes.data() + section_offset);
  return true;
}

std::size_t CountSignature(const ParsedPe& pe, const profile::Signature& signature,
                           std::uint32_t& first_rva) {
  std::size_t matches = 0;
  first_rva = 0;
  for (std::uint16_t index = 0; index < pe.nt->FileHeader.NumberOfSections; ++index) {
    const auto& section = pe.sections[index];
    if ((section.Characteristics & IMAGE_SCN_MEM_EXECUTE) == 0 ||
        section.PointerToRawData >= pe.bytes.size()) {
      continue;
    }
    const auto available = pe.bytes.size() - section.PointerToRawData;
    const auto raw_size = std::min<std::size_t>(section.SizeOfRawData, available);
    if (raw_size < signature.size) {
      continue;
    }
    const auto* begin = pe.bytes.data() + section.PointerToRawData;
    for (std::size_t offset = 0; offset + signature.size <= raw_size; ++offset) {
      if (std::equal(signature.bytes, signature.bytes + signature.size, begin + offset)) {
        const auto rva = section.VirtualAddress + static_cast<std::uint32_t>(offset);
        if (matches == 0) {
          first_rva = rva;
        }
        ++matches;
      }
    }
  }
  return matches;
}

bool ValidateMemorySignature(HMODULE module, const profile::Signature& signature) {
  const auto* base = reinterpret_cast<const std::uint8_t*>(module);
  __try {
    return std::equal(signature.bytes, signature.bytes + signature.size, base + signature.rva);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

} // namespace

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return {};
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return {};
  }
  std::wstring result(static_cast<std::size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::string JsonEscape(const std::string& value) {
  std::ostringstream output;
  for (const unsigned char ch : value) {
    switch (ch) {
      case '\\': output << "\\\\"; break;
      case '"': output << "\\\""; break;
      case '\b': output << "\\b"; break;
      case '\f': output << "\\f"; break;
      case '\n': output << "\\n"; break;
      case '\r': output << "\\r"; break;
      case '\t': output << "\\t"; break;
      default:
        if (ch < 0x20) {
          output << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(ch)
                 << std::dec;
        } else {
          output << static_cast<char>(ch);
        }
    }
  }
  return output.str();
}

std::string HexPointer(const void* value) {
  std::ostringstream output;
  output << "0x" << std::hex << std::uppercase << reinterpret_cast<std::uintptr_t>(value);
  return output.str();
}

std::string Sha256File(const std::filesystem::path& path, std::string& error) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  std::vector<std::uint8_t> object;
  std::array<std::uint8_t, 32> digest{};
  DWORD object_size = 0;
  DWORD returned = 0;

  auto cleanup = [&]() {
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  };
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&object_size),
                        sizeof(object_size), &returned, 0) < 0) {
    error = "BCrypt SHA-256 initialisation failed";
    cleanup();
    return {};
  }
  object.resize(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr, 0, 0) < 0) {
    error = "BCryptCreateHash failed";
    cleanup();
    return {};
  }
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    error = "cannot open executable for SHA-256";
    cleanup();
    return {};
  }
  // The MSVC executable default stack is commonly 1 MiB. Keep the streaming
  // buffer on the heap so the standalone verifier cannot exhaust its stack.
  std::vector<char> buffer(1024 * 1024);
  while (input) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const auto count = input.gcount();
    if (count > 0 && BCryptHashData(hash, reinterpret_cast<PUCHAR>(buffer.data()),
                                    static_cast<ULONG>(count), 0) < 0) {
      error = "BCryptHashData failed";
      cleanup();
      return {};
    }
  }
  if (!input.eof() || BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) < 0) {
    error = "cannot finish executable SHA-256";
    cleanup();
    return {};
  }
  cleanup();
  std::ostringstream output;
  for (const auto byte : digest) {
    output << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
  }
  return output.str();
}

ValidationResult ValidatePinnedExecutable(const std::filesystem::path& path) {
  ValidationResult result;
  result.path = std::filesystem::absolute(path);
  ParsedPe pe;
  if (!ReadPe(result.path, pe, result.error)) {
    return result;
  }
  result.pe_timestamp = pe.nt->FileHeader.TimeDateStamp;
  result.image_size = pe.nt->OptionalHeader.SizeOfImage;
  result.machine = pe.nt->FileHeader.Machine;
  result.sha256 = Sha256File(result.path, result.error);
  if (result.sha256.empty()) {
    return result;
  }

  auto add_signature = [&](const profile::Signature& signature) {
    SignatureResult item;
    item.name = signature.name;
    item.expected_rva = signature.rva;
    item.matches = CountSignature(pe, signature, item.observed_rva);
    item.expected_bytes_match = item.matches == 1 && item.observed_rva == item.expected_rva;
    result.signatures.push_back(std::move(item));
  };
  for (const auto& signature : profile::kSignatures) {
    add_signature(signature);
  }
  add_signature(profile::kLuaToLStringSignature);

  const bool signatures_valid = std::all_of(
      result.signatures.begin(), result.signatures.end(),
      [](const SignatureResult& item) { return item.expected_bytes_match; });
  result.valid = result.sha256 == profile::kSha256 && result.pe_timestamp == profile::kPeTimestamp &&
                 result.image_size == profile::kImageSize && result.machine == profile::kMachine &&
                 signatures_valid;
  if (!result.valid) {
    result.error = "executable does not match the pinned Build 35924 profile";
  }
  return result;
}

ValidationResult ValidatePinnedModule(HMODULE module) {
  auto result = ValidatePinnedExecutable(CurrentExecutablePath());
  if (!result.valid) {
    return result;
  }
  for (std::size_t index = 0; index < profile::kSignatures.size(); ++index) {
    if (!ValidateMemorySignature(module, profile::kSignatures[index])) {
      result.signatures[index].expected_bytes_match = false;
      result.valid = false;
    }
  }
  if (!ValidateMemorySignature(module, profile::kLuaToLStringSignature)) {
    result.signatures.back().expected_bytes_match = false;
    result.valid = false;
  }
  if (!result.valid) {
    result.error = "in-memory signatures do not match the pinned executable";
  }
  return result;
}

std::filesystem::path CurrentExecutablePath() {
  std::wstring value(32768, L'\0');
  const DWORD length = GetModuleFileNameW(nullptr, value.data(), static_cast<DWORD>(value.size()));
  if (length == 0 || length >= value.size()) {
    return {};
  }
  value.resize(length);
  return std::filesystem::path(value);
}

std::filesystem::path NativeStatusDirectory() {
  std::wstring temp(32768, L'\0');
  const DWORD length = GetTempPathW(static_cast<DWORD>(temp.size()), temp.data());
  if (length == 0 || length >= temp.size()) {
    return std::filesystem::temp_directory_path() / "tpf2mp_native";
  }
  temp.resize(length);
  return std::filesystem::path(temp) / "tpf2mp_native";
}

std::filesystem::path NativeStatusPath(const DWORD process_id) {
  return NativeStatusDirectory() / ("status-" + std::to_string(process_id) + ".json");
}

bool AtomicWriteUtf8(const std::filesystem::path& path, const std::string& value,
                     std::string& error, const bool durable) {
  std::error_code ec;
  std::filesystem::create_directories(path.parent_path(), ec);
  if (ec) {
    error = "cannot create status directory: " + ec.message();
    return false;
  }
  const auto temporary = path.wstring() + L".tmp-" + std::to_wstring(GetCurrentThreadId());
  {
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) {
      error = "cannot create temporary status file";
      return false;
    }
    output.write(value.data(), static_cast<std::streamsize>(value.size()));
    output.flush();
    if (!output) {
      error = "cannot write complete status file";
      return false;
    }
  }
  const DWORD move_flags = MOVEFILE_REPLACE_EXISTING |
      (durable ? MOVEFILE_WRITE_THROUGH : 0);
  if (!MoveFileExW(temporary.c_str(), path.c_str(), move_flags)) {
    error = "cannot atomically replace status file: Win32 " + std::to_string(GetLastError());
    DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

} // namespace tpf2mp
