#include "tpf2mp/native_common.hpp"

#include <Windows.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) {
    std::wcerr << L"usage: tpf2mp_dll_load_test <hook.dll>\n";
    return 64;
  }
  const auto status_path = tpf2mp::NativeStatusPath(GetCurrentProcessId());
  DeleteFileW(status_path.c_str());
  HMODULE module = LoadLibraryW(std::filesystem::absolute(argv[1]).c_str());
  if (module == nullptr) {
    std::wcerr << L"LoadLibraryW failed with Win32 " << GetLastError() << L"\n";
    return 2;
  }
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  std::string content;
  while (std::chrono::steady_clock::now() < deadline) {
    std::ifstream input(status_path, std::ios::binary);
    if (input) {
      std::ostringstream output;
      output << input.rdbuf();
      content = output.str();
      if (content.find("\"stage\":\"rejected\"") != std::string::npos) break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  std::cout << content << "\n";
  // The worker exits immediately on an unrecognised host. Do not unload an
  // active hook; this harness can only ever exercise the fail-closed path.
  if (content.find("\"stage\":\"rejected\"") == std::string::npos ||
      content.find("\"active\":false") == std::string::npos) {
    std::cerr << "hook DLL did not publish a fail-closed rejection\n";
    return 3;
  }
  FreeLibrary(module);
  return 0;
}
