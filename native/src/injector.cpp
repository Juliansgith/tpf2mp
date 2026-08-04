#include "tpf2mp/native_common.hpp"

#include <Windows.h>
#include <TlHelp32.h>

#include <chrono>
#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Handle {
  HANDLE value = nullptr;
  Handle() = default;
  explicit Handle(HANDLE raw) : value(raw) {}
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value(other.value) { other.value = nullptr; }
  Handle& operator=(Handle&& other) noexcept {
    if (this != &other) {
      if (value != nullptr && value != INVALID_HANDLE_VALUE) CloseHandle(value);
      value = other.value;
      other.value = nullptr;
    }
    return *this;
  }
  ~Handle() {
    if (value != nullptr && value != INVALID_HANDLE_VALUE) CloseHandle(value);
  }
  explicit operator bool() const { return value != nullptr && value != INVALID_HANDLE_VALUE; }
};

std::wstring Win32Error(const DWORD code = GetLastError()) {
  wchar_t* buffer = nullptr;
  const DWORD length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                                          FORMAT_MESSAGE_IGNORE_INSERTS,
                                      nullptr, code, 0, reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
  std::wstring result = length > 0 ? std::wstring(buffer, length) : L"unknown error";
  if (buffer != nullptr) LocalFree(buffer);
  return result;
}

std::wstring Quote(const std::wstring& value) {
  if (value.find_first_of(L" \t\"") == std::wstring::npos) return value;
  std::wstring result = L"\"";
  std::size_t slashes = 0;
  for (const wchar_t ch : value) {
    if (ch == L'\\') {
      ++slashes;
    } else if (ch == L'"') {
      result.append(slashes * 2 + 1, L'\\');
      result.push_back(L'"');
      slashes = 0;
    } else {
      result.append(slashes, L'\\');
      slashes = 0;
      result.push_back(ch);
    }
  }
  result.append(slashes * 2, L'\\');
  result.push_back(L'"');
  return result;
}

std::filesystem::path ProcessPath(const DWORD process_id, std::wstring& error) {
  Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id));
  if (!process) {
    error = L"OpenProcess(query) failed: " + Win32Error();
    return {};
  }
  std::wstring path(32768, L'\0');
  DWORD length = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process.value, 0, path.data(), &length)) {
    error = L"QueryFullProcessImageNameW failed: " + Win32Error();
    return {};
  }
  path.resize(length);
  return path;
}

std::optional<std::uintptr_t> RemoteModuleBase(const DWORD process_id, const std::wstring& name) {
  Handle snapshot;
  for (int attempt = 0; attempt < 20; ++attempt) {
    snapshot = Handle(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, process_id));
    if (snapshot || GetLastError() != ERROR_BAD_LENGTH) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  if (!snapshot) return std::nullopt;
  MODULEENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (!Module32FirstW(snapshot.value, &entry)) return std::nullopt;
  do {
    if (_wcsicmp(entry.szModule, name.c_str()) == 0) {
      return reinterpret_cast<std::uintptr_t>(entry.modBaseAddr);
    }
  } while (Module32NextW(snapshot.value, &entry));
  return std::nullopt;
}

bool ModuleAlreadyLoaded(const DWORD process_id, const std::filesystem::path& dll) {
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, process_id));
  if (!snapshot) return false;
  MODULEENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (!Module32FirstW(snapshot.value, &entry)) return false;
  const auto wanted = std::filesystem::weakly_canonical(dll).wstring();
  do {
    std::error_code ec;
    const auto observed = std::filesystem::weakly_canonical(entry.szExePath, ec).wstring();
    if (!ec && _wcsicmp(observed.c_str(), wanted.c_str()) == 0) return true;
  } while (Module32NextW(snapshot.value, &entry));
  return false;
}

bool Inject(const DWORD process_id, const std::filesystem::path& dll, std::wstring& error) {
  if (ModuleAlreadyLoaded(process_id, dll)) {
    std::wcout << L"hook DLL is already loaded in process " << process_id << L"\n";
    return true;
  }
  Handle process(OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION |
                                 PROCESS_VM_WRITE | PROCESS_VM_READ,
                             FALSE, process_id));
  if (!process) {
    error = L"OpenProcess(inject) failed: " + Win32Error();
    return false;
  }

  const auto full_path = std::filesystem::absolute(dll).wstring();
  const SIZE_T byte_count = (full_path.size() + 1) * sizeof(wchar_t);
  void* remote_path = VirtualAllocEx(process.value, nullptr, byte_count, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  if (remote_path == nullptr) {
    error = L"VirtualAllocEx failed: " + Win32Error();
    return false;
  }
  auto release_remote = [&]() { VirtualFreeEx(process.value, remote_path, 0, MEM_RELEASE); };
  SIZE_T written = 0;
  if (!WriteProcessMemory(process.value, remote_path, full_path.c_str(), byte_count, &written) ||
      written != byte_count) {
    error = L"WriteProcessMemory failed: " + Win32Error();
    release_remote();
    return false;
  }

  HMODULE local_kernel = GetModuleHandleW(L"kernel32.dll");
  FARPROC local_load_library = local_kernel != nullptr ? GetProcAddress(local_kernel, "LoadLibraryW") : nullptr;
  HMODULE local_owner = nullptr;
  if (local_load_library != nullptr) {
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(local_load_library), &local_owner);
  }
  wchar_t owner_path[32768]{};
  const DWORD owner_length = local_owner != nullptr
      ? GetModuleFileNameW(local_owner, owner_path, static_cast<DWORD>(std::size(owner_path)))
      : 0;
  const auto owner_name = owner_length > 0
      ? std::filesystem::path(std::wstring(owner_path, owner_length)).filename().wstring()
      : std::wstring();
  const auto remote_owner = owner_name.empty() ? std::nullopt : RemoteModuleBase(process_id, owner_name);
  if (local_owner == nullptr || local_load_library == nullptr) {
    error = L"cannot resolve the remote owner of LoadLibraryW (local owner " + owner_name + L")";
    release_remote();
    return false;
  }
  const auto load_offset = reinterpret_cast<std::uintptr_t>(local_load_library) -
                           reinterpret_cast<std::uintptr_t>(local_owner);
  std::uintptr_t remote_load_address = remote_owner ? *remote_owner + load_offset : 0;
  if (remote_load_address == 0) {
    // Some protected executables do not expose their loader modules through a
    // Toolhelp snapshot while the initial thread is suspended. System DLLs are
    // section-mapped at a shared per-boot address. Use that address only after
    // proving the target bytes are readable and identical in both processes.
    std::array<std::uint8_t, 32> local_bytes{};
    std::array<std::uint8_t, 32> remote_bytes{};
    std::memcpy(local_bytes.data(), reinterpret_cast<const void*>(local_load_library), local_bytes.size());
    SIZE_T bytes_read = 0;
    if (!ReadProcessMemory(process.value, reinterpret_cast<const void*>(local_load_library),
                           remote_bytes.data(), remote_bytes.size(), &bytes_read) ||
        bytes_read != remote_bytes.size() || local_bytes != remote_bytes) {
      error = L"remote loader module is hidden and its shared LoadLibraryW address could not be verified";
      release_remote();
      return false;
    }
    remote_load_address = reinterpret_cast<std::uintptr_t>(local_load_library);
  }
  const auto remote_load_library = reinterpret_cast<LPTHREAD_START_ROUTINE>(remote_load_address);
  Handle thread(CreateRemoteThread(process.value, nullptr, 0, remote_load_library, remote_path, 0, nullptr));
  if (!thread) {
    error = L"CreateRemoteThread failed: " + Win32Error();
    release_remote();
    return false;
  }
  const DWORD waited = WaitForSingleObject(thread.value, 30000);
  DWORD exit_code = 0;
  GetExitCodeThread(thread.value, &exit_code);
  release_remote();
  if (waited != WAIT_OBJECT_0 || exit_code == 0) {
    error = L"remote LoadLibraryW failed or timed out";
    return false;
  }
  if (!ModuleAlreadyLoaded(process_id, dll)) {
    error = L"LoadLibraryW returned but the hook DLL is absent from the target module list";
    return false;
  }
  return true;
}

std::string ReadText(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) return {};
  std::ostringstream output;
  output << input.rdbuf();
  return output.str();
}

bool WaitForHook(const DWORD process_id, const DWORD timeout_ms, std::string& status) {
  const auto path = tpf2mp::NativeStatusPath(process_id);
  Handle process(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id));
  if (!process) {
    status = "target process could not be opened while waiting for hook activation";
    return false;
  }
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (std::chrono::steady_clock::now() < deadline) {
    if (WaitForSingleObject(process.value, 0) == WAIT_OBJECT_0) {
      status = "target process exited before hook activation";
      return false;
    }
    status = ReadText(path);
    if (status.find("\"processId\":" + std::to_string(process_id)) != std::string::npos) {
      if (status.find("\"stage\":\"active\"") != std::string::npos &&
          status.find("\"active\":true") != std::string::npos) {
        return true;
      }
      if (status.find("\"stage\":\"rejected\"") != std::string::npos ||
          status.find("\"stage\":\"hook-error\"") != std::string::npos) {
        return false;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  return false;
}

bool InitialiseLoaderThenSuspend(HANDLE process, HANDLE primary_thread, const DWORD process_id,
                                 const DWORD timeout_ms, std::wstring& error) {
  if (ResumeThread(primary_thread) == static_cast<DWORD>(-1)) {
    error = L"cannot resume the primary thread for loader initialisation: " + Win32Error();
    return false;
  }
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  bool entered_executable = false;
  while (std::chrono::steady_clock::now() < deadline) {
    DWORD exit_code = STILL_ACTIVE;
    if (!GetExitCodeProcess(process, &exit_code) || exit_code != STILL_ACTIVE) {
      error = L"game exited while Windows was initialising its loader";
      return false;
    }
    const auto executable_base = RemoteModuleBase(process_id, L"TransportFever2.exe");
    if (executable_base && RemoteModuleBase(process_id, L"kernel32.dll")) {
      if (SuspendThread(primary_thread) == static_cast<DWORD>(-1)) {
        error = L"cannot sample the primary thread during loader initialisation: " + Win32Error();
        return false;
      }
      CONTEXT context{};
      context.ContextFlags = CONTEXT_CONTROL;
      if (!GetThreadContext(primary_thread, &context)) {
        ResumeThread(primary_thread);
        error = L"GetThreadContext failed while locating the executable entry: " + Win32Error();
        return false;
      }
      const auto instruction = static_cast<std::uintptr_t>(context.Rip);
      if (instruction >= *executable_base &&
          instruction < *executable_base + tpf2mp::profile::kImageSize) {
        entered_executable = true;
        break; // retain the suspend count for injection
      }
      if (ResumeThread(primary_thread) == static_cast<DWORD>(-1)) {
        error = L"cannot resume the sampled loader thread: " + Win32Error();
        return false;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  if (!entered_executable) {
    error = L"primary thread did not enter TransportFever2.exe before timeout";
    return false;
  }
  return true;
}

void PrintValidation(const tpf2mp::ValidationResult& result) {
  std::cout << "profile=" << tpf2mp::profile::kProfileName << "\n"
            << "path=" << tpf2mp::WideToUtf8(result.path.wstring()) << "\n"
            << "valid=" << (result.valid ? "true" : "false") << "\n"
            << "sha256=" << result.sha256 << "\n"
            << "pe_timestamp=0x" << std::hex << result.pe_timestamp << std::dec << "\n"
            << "image_size=0x" << std::hex << result.image_size << std::dec << "\n";
  for (const auto& signature : result.signatures) {
    std::cout << "signature=" << signature.name << " matches=" << signature.matches
              << " expected_rva=0x" << std::hex << signature.expected_rva
              << " observed_rva=0x" << signature.observed_rva << std::dec
              << " valid=" << (signature.expected_bytes_match ? "true" : "false") << "\n";
  }
  if (!result.error.empty()) std::cout << "error=" << result.error << "\n";
}

void Usage() {
  std::wcerr << L"Usage:\n"
             << L"  tpf2mp_injector --verify <TransportFever2.exe>\n"
             << L"  tpf2mp_injector --pid <pid> --dll <tpf2mp_hook.dll> [--wait-ms 30000]\n"
             << L"  tpf2mp_injector --launch <TransportFever2.exe> --dll <tpf2mp_hook.dll> "
                L"[--workdir <dir>] [--wait-ms 30000] [-- <game args>]\n";
}

} // namespace

int wmain(int argc, wchar_t** argv) {
  std::optional<std::filesystem::path> verify_path;
  std::optional<std::filesystem::path> launch_path;
  std::optional<std::filesystem::path> dll_path;
  std::optional<std::filesystem::path> workdir;
  std::optional<DWORD> process_id;
  DWORD wait_ms = 30000;
  std::vector<std::wstring> game_arguments;
  bool pass_through = false;

  for (int index = 1; index < argc; ++index) {
    const std::wstring argument = argv[index];
    if (pass_through) {
      game_arguments.push_back(argument);
    } else if (argument == L"--") {
      pass_through = true;
    } else if (argument == L"--verify" && index + 1 < argc) {
      verify_path = argv[++index];
    } else if (argument == L"--launch" && index + 1 < argc) {
      launch_path = argv[++index];
    } else if (argument == L"--dll" && index + 1 < argc) {
      dll_path = argv[++index];
    } else if (argument == L"--workdir" && index + 1 < argc) {
      workdir = argv[++index];
    } else if (argument == L"--pid" && index + 1 < argc) {
      process_id = static_cast<DWORD>(std::stoul(argv[++index]));
    } else if (argument == L"--wait-ms" && index + 1 < argc) {
      wait_ms = static_cast<DWORD>(std::stoul(argv[++index]));
    } else {
      Usage();
      return 64;
    }
  }

  if (verify_path && !launch_path && !process_id && !dll_path) {
    const auto validation = tpf2mp::ValidatePinnedExecutable(*verify_path);
    PrintValidation(validation);
    return validation.valid ? 0 : 2;
  }
  if (!dll_path || (launch_path.has_value() == process_id.has_value())) {
    Usage();
    return 64;
  }
  std::error_code ec;
  *dll_path = std::filesystem::weakly_canonical(*dll_path, ec);
  if (ec || !std::filesystem::is_regular_file(*dll_path)) {
    std::wcerr << L"hook DLL does not exist: " << dll_path->wstring() << L"\n";
    return 3;
  }

  PROCESS_INFORMATION created{};
  Handle created_process;
  Handle created_thread;
  bool launched = false;
  if (launch_path) {
    const auto validation = tpf2mp::ValidatePinnedExecutable(*launch_path);
    PrintValidation(validation);
    if (!validation.valid) return 2;
    auto executable = std::filesystem::absolute(*launch_path);
    auto directory = workdir.value_or(executable.parent_path());
    std::wstring command_line = Quote(executable.wstring());
    for (const auto& argument : game_arguments) command_line += L" " + Quote(argument);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
    mutable_command.push_back(L'\0');
    if (!CreateProcessW(executable.c_str(), mutable_command.data(), nullptr, nullptr, FALSE,
                        CREATE_SUSPENDED, nullptr, directory.c_str(), &startup, &created)) {
      std::wcerr << L"CreateProcessW failed: " << Win32Error() << L"\n";
      return 4;
    }
    created_process = Handle(created.hProcess);
    created_thread = Handle(created.hThread);
    process_id = created.dwProcessId;
    launched = true;
    std::wcout << L"launched pinned game suspended as pid " << *process_id << L"\n";
    std::wstring loader_error;
    if (!InitialiseLoaderThenSuspend(created_process.value, created_thread.value, *process_id,
                                     wait_ms, loader_error)) {
      std::wcerr << L"early loader initialisation failed: " << loader_error << L"\n";
      TerminateProcess(created_process.value, 4);
      return 4;
    }
    std::wcout << L"Windows loader initialised; primary game thread re-suspended before hook install\n";
  } else {
    std::wstring path_error;
    const auto target_path = ProcessPath(*process_id, path_error);
    if (target_path.empty()) {
      std::wcerr << path_error << L"\n";
      return 4;
    }
    const auto validation = tpf2mp::ValidatePinnedExecutable(target_path);
    PrintValidation(validation);
    if (!validation.valid) return 2;
  }

  std::wstring injection_error;
  if (!Inject(*process_id, *dll_path, injection_error)) {
    std::wcerr << L"injection failed: " << injection_error << L"\n";
    if (launched) TerminateProcess(created_process.value, 5);
    return 5;
  }
  if (launched) {
    // Threads created from DllMain are not guaranteed to execute while the
    // process's primary initialisation thread remains suspended. The DLL is
    // already mapped at this point, so resume and let its fail-closed worker
    // validate/install while normal game startup continues.
    if (ResumeThread(created_thread.value) == static_cast<DWORD>(-1)) {
      std::wcerr << L"ResumeThread failed: " << Win32Error() << L"\n";
      TerminateProcess(created_process.value, 7);
      return 7;
    }
    std::wcout << L"resumed game pid " << *process_id << L" with hook DLL mapped\n";
  }
  std::string status;
  if (!WaitForHook(*process_id, wait_ms, status)) {
    std::cerr << "hook did not reach active state; status=" << status << "\n";
    if (launched) TerminateProcess(created_process.value, 6);
    return 6;
  }
  std::cout << "hook active; status="
            << tpf2mp::WideToUtf8(tpf2mp::NativeStatusPath(*process_id).wstring()) << "\n";
  return 0;
}
