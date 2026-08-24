#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace tpf2mp::native_binding {

bool IsInteresting(const char* key);
int Index(const char* key);
int RegistrySlot(std::size_t index);
std::string GlobalName(std::string_view name);
std::size_t Count();
std::string_view At(std::size_t index);

}  // namespace tpf2mp::native_binding
