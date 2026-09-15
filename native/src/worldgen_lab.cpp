// Isolated Build 35924 native world-generation worker. No input
// synthesis, component clicks or modifications to the executable on disk.
#include "tpf2mp/native_common.hpp"
#include <MinHook.h>
#include <array>
#include <atomic>
#include <fstream>
#include <cstring>
#include <vector>
#include <unordered_map>
#include <sstream>
#include <map>
#include <new>
#include <memory>
#include "worldgen_preview.hpp"

namespace {
using Update = void(__fastcall*)(void*, void*, void*, void*);
Update original_update{};
using PollEvent = int(__cdecl*)(void*);
PollEvent original_poll{};
void* observed_menu{};
DWORD menu_thread{};
std::uintptr_t base{};
std::filesystem::path marker;
SRWLOCK marker_mutex = SRWLOCK_INIT;
std::atomic<bool> issued{false};
ULONGLONG first_frame{};
ULONGLONG world_frame{};
std::string save_stem;
bool save_issued{};
bool save_completed{};
bool preview_only{};
bool preview_export{};
void* preview_provider{};
void* climate_rep{};
void ExportNativeMapPreview(std::uintptr_t, void*, void*, void*, const std::filesystem::path&);
void Emit(const char* event);
struct Mod { std::string id; std::int32_t version; };
static_assert(sizeof(Mod) == 40);
std::vector<Mod> mods;
using IntMap = std::unordered_map<std::string, int>;
// Native serialized Lua values: 32-byte payload + one-byte discriminator.
// Strings are tag 3; numbers tag 2. Mod parameters contain a tree of these,
// NOT another unordered string/int map. Never pass a guessed nested STL type.
struct Variant {
  alignas(8) std::array<std::byte,32> payload{};
  std::int8_t tag{-1};
  Variant(const char* text) : tag(3) { new(payload.data()) std::string(text); }
  Variant(int number) : tag(2) { const double value = number; std::memcpy(payload.data(),&value,8); }
  Variant(const Variant& other) : tag(other.tag) {
    if (tag == 3) new(payload.data()) std::string(other.text());
    else payload = other.payload;
  }
  ~Variant() { if (tag == 3) reinterpret_cast<std::string*>(payload.data())->~basic_string(); }
  const std::string& text() const { return *reinterpret_cast<const std::string*>(payload.data()); }
  bool operator<(const Variant& other) const {
    if (tag != other.tag) return tag < other.tag;
    if (tag == 3) return text() < other.text();
    double a{}, b{}; std::memcpy(&a,payload.data(),8); std::memcpy(&b,other.payload.data(),8);
    return a < b;
  }
};
using NativeTable = std::map<Variant,Variant>;
using ModParams = std::unordered_map<std::string, NativeTable>;
static_assert(sizeof(Variant) == 40 && offsetof(Variant,tag) == 32);
static_assert(sizeof(NativeTable) == 16 && sizeof(ModParams) == 64);
ModParams mod_params;
IntMap terrain_params{{"hilliness",0},{"water",0},{"forest",2}};
using GeneratorClosure = void*(*)(void*);
GeneratorClosure original_generator{};
using TerrainWidget = void(*)(void*,void*,const void*);
TerrainWidget original_terrain{};
thread_local bool preparing{};
bool configured{};
bool terrain_applied{};
unsigned world_seed{1234567}, world_year{1950}, world_size{};
using LoadConfig = void(*)(void*, void*, void*, void*, void*);
LoadConfig original_config{};
using StartNew = void(*)(void*, void*, void*, void*, void*, void*, std::uint32_t, bool, void*);
StartNew original_start{};
using Resources = std::vector<std::pair<std::string,std::string>>;
Resources world_resources{{"climate","temperate"},{"environment","temperate"},
    {"vehicles","all"},{"nameList","england"},{"difficulty","easy"}};

bool ReadRequest(const std::filesystem::path& path) {
  // Narrow data-only ABI, emitted by the validated launcher worker. No paths,
  // Lua, callbacks, native addresses or arbitrary parameter names are accepted.
  if (!path.is_absolute() || std::filesystem::file_size(path) > 65536) return false;
  std::ifstream input(path);
  std::string magic;
  unsigned terrain{}, towns{}, industries{}, economy{}, agents{}, growth{}, count{};
  if (!(input >> magic >> world_seed >> world_year >> world_size >> terrain >> towns
        >> industries >> economy >> agents >> growth >> count) || magic != "TPF2MP_WORLDGEN_1"
      || world_seed > 2147483647 || world_year < 1850 || world_year > 2050
      || world_size > 2 || terrain > 3 || towns > 2 || industries > 2
      || economy > 3 || agents > 2 || growth > 1 || count < 1 || count > 256) return false;
  mods.clear(); unsigned multiplayer{};
  for (unsigned i=0;i<count;++i) {
    std::string id; unsigned version{};
    if (!(input >> id >> version) || id.empty() || id.size() > 130 || version > 2147483647
        || id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_!*.-") != std::string::npos)
      return false;
    for (const auto& existing : mods) if (existing.id == id) return false;
    if (id == "!tpf2_mp" && version == 1) ++multiplayer;
    mods.push_back({id,static_cast<std::int32_t>(version)});
  }
  std::string extra;
  if (input >> extra || multiplayer != 1) return false;
  terrain_params = {{"hilliness",static_cast<int>(terrain)},{"water",0},{"forest",2}};
  mod_params.clear();
  mod_params["!tpf2_mp_1"] = {{"agentMode",static_cast<int>(agents)},
    {"economyDifficulty",static_cast<int>(economy)},{"townDevelopment",static_cast<int>(growth)},
    {"startupMode",0}};
  mod_params[""] = {{"locations.mapSize",static_cast<int>(world_size)},
    {"locations.towns.frequency",static_cast<int>(towns)},
    {"locations.industry.maxNumberPerArea",static_cast<int>(industries)}};
  configured = true;
  return true;
}

void Config(void* manager, void* config, void* active, void* resources, void* params) {
  original_config(manager, config, preparing && !mods.empty() ? &mods : active,
                  preparing && configured ? &world_resources : resources,
                  preparing && configured ? &mod_params : params);
}
void Start(void* menu, void* active, void* resources, void* params, void* map,
           void* seed, std::uint32_t date, bool editor, void* callback) {
  if (!preparing) { original_start(menu,active,resources,params,map,seed,date,editor,callback); return; }
  if (preview_only || preview_export) {
    // Generation is complete, but CGameUI/World have not been constructed.
    // Preview-only exits here without a save; accepted generation continues
    // below after exporting the same data for the final comparison.
    Emit("native-preview-render-enter");
    try {
      ExportNativeMapPreview(base, preview_provider, climate_rep, map, marker.parent_path());
      Emit("native-preview-ready");
    } catch (const std::exception& error) {
      Emit((std::string("native-preview-failed:") + error.what()).c_str());
      ExitProcess(8);
    }
    if (preview_only) ExitProcess(0);
  }
  if (!mods.empty()) {
    // Incoming native vector is empty in the test backend. Let the game's own
    // copy constructor allocate it; StartNewGame owns/destructs that parameter.
    const auto vector = static_cast<void**>(active);
    if (vector[0] != vector[1]) { Emit("nonempty-mod-vector-rejected"); return; }
    reinterpret_cast<void*(*)(void*, const void*)>(base + 0xaa380)(active, &mods);
    Emit("selected-mods-forwarded");
  }
  std::string seed_text = std::to_string(world_seed);
  if (configured) {
    reinterpret_cast<void(*)(void*,unsigned,unsigned,unsigned)>(base + 0x2855e0)(&date,world_year,1,1);
    reinterpret_cast<void(*)(void*,const void*)>(base + 0x2a7210)(params,&mod_params);
    reinterpret_cast<void*(*)(void*,const void*)>(base + 0xaa150)(resources,&world_resources);
    seed = &seed_text;
    // Observe the game's destination object after its copy constructor, not
    // merely our source request. The verifier binds these to the output save.
    const auto& copied = *static_cast<const ModParams*>(params);
    for (const auto& [group, table] : copied) for (const auto& [key,value] : table) {
      if (key.tag != 3 || value.tag != 2) continue;
      double number{}; std::memcpy(&number,value.payload.data(),8);
      std::ostringstream observed; observed << "native-parameter-" << group << ":" << key.text() << "=" << number;
      Emit(observed.str().c_str());
    }
  }
  original_start(menu, active, resources, params, map, seed, date, editor, callback);
}

struct GeneratorEntry { std::string name; std::shared_ptr<void> resource; };
static_assert(sizeof(GeneratorEntry) == 48);
using GeneratorRep = void*(*)(void*,void*,void*,void*,void*);
GeneratorRep original_rep{};
GeneratorRep original_climate{};
void* ObserveClimate(void* out, void* a, void* b, void* c, void* d) {
  auto result = original_climate(out,a,b,c,d);
  if (preparing) climate_rep = out;
  return result;
}
void* generation_rep{};
using ResourceIndex = int(*)(void*,const std::string*);
ResourceIndex original_index{};
int GenerationIndex(void* rep,const std::string* name) {
  // This rep owns a name->index cache. Reordering entries without updating the
  // lookup would pair temperate parameters with the original desert callback.
  if (rep == generation_rep && configured) {
    const auto& entries = *reinterpret_cast<const std::vector<GeneratorEntry>*>(static_cast<const std::byte*>(rep)+0x28);
    for (std::size_t i=0; i<entries.size() && i<2048; ++i)
      if (entries[i].name == *name) return static_cast<int>(i);
    return -1;
  }
  return original_index(rep,name);
}
void* SelectGenerator(void* out,void* a,void* b,void* c,void* d) {
  auto result = original_rep(out,a,b,c,d);
  if (preparing && configured) {
    auto& entries = *reinterpret_cast<std::vector<GeneratorEntry>*>(static_cast<std::byte*>(out)+0x28);
    bool selected = false;
    if (entries.size() <= 2048) for (auto& entry : entries) {
      if (entry.name == "temperate.gen.lua") {
        std::swap(entries.front(),entry); selected = true; break;
      }
    }
    if (!selected) { Emit("temperate-generator-missing"); ExitProcess(7); }
    generation_rep = out;
    Emit("temperate-generator-selected");
  }
  return result;
}

void Terrain(void* widget, void* definitions, const void* values) {
  if (preparing && configured && !terrain_applied) {
    terrain_applied = true;
    const auto& original = *static_cast<const IntMap*>(values);
    if (original.size() < 32) {
      for (const auto& [key,value] : original) {
        std::ostringstream line; line << "terrain-original-" << key << "-" << value;
        Emit(line.str().c_str());
      }
    }
    for (const auto& [key,value] : terrain_params)
      Emit(("native-terrain-"+key+"="+std::to_string(value)).c_str());
    // The native widget consumes/destructs this by-value argument. Give it a
    // disposable placement-constructed copy: neither a global template nor an
    // automatic C++ variable whose destructor would free it a second time.
    alignas(IntMap) std::array<std::byte,sizeof(IntMap)> native_values;
    new(native_values.data()) IntMap(terrain_params);
    original_terrain(widget,definitions,native_values.data());
  } else original_terrain(widget,definitions,values);
}

void* Generator(void* closure) {
  if (preparing && configured) {
    auto bytes = static_cast<std::byte*>(closure);
    preview_provider = *reinterpret_cast<void**>(bytes + 8);
    // Scalar fields in the native generation closure, before its std::function
    // wrapper adds a vtable. Keep all owning strings/vectors/native objects.
    auto settings = reinterpret_cast<std::byte*(*)()>(base + 0x2a49c0)();
    std::array<std::byte, 0x30> no_override{};
    *reinterpret_cast<int*>(no_override.data()+0x28) = -1;
    *reinterpret_cast<int*>(no_override.data()+0x2c) = -1;
    const auto index = world_size + (*reinterpret_cast<bool*>(settings+0x2fc) ? 1u : 0u);
    const auto dimensions = reinterpret_cast<std::uint64_t(*)(unsigned,unsigned,void*)>(base + 0x674aa0)(index,0,no_override.data());
    std::memcpy(bytes+0x38,&dimensions,sizeof(dimensions));
    *reinterpret_cast<unsigned*>(bytes+0x68) = world_seed;
    Emit(("native-seed="+std::to_string(*reinterpret_cast<unsigned*>(bytes+0x68))).c_str());
    const auto name = *reinterpret_cast<const std::string* const*>(bytes+0x28);
    Emit(("generator-resource-" + *name).c_str());
    std::ostringstream line; line << "configured-dimensions-" << (dimensions & 0xffffffff) << "x" << (dimensions >> 32);
    Emit(line.str().c_str());
  }
  return original_generator(closure);
}

void Emit(const char* event) {
  AcquireSRWLockExclusive(&marker_mutex);
  std::ofstream out(marker, std::ios::app);
  out << "{\"event\":\"" << tpf2mp::JsonEscape(event) << "\",\"pid\":" << GetCurrentProcessId()
      << ",\"tickMs\":" << GetTickCount64() << "}\n";
  out.close();
  ReleaseSRWLockExclusive(&marker_mutex);
}

void Generate(void* menu) {
  if (issued.load() || !menu) return;
  if (!first_frame) { first_frame = GetTickCount64(); Emit("menu-update-observed"); }
  if (GetTickCount64() - first_frame < 15000) return;
  const auto bytes = static_cast<const std::byte*>(menu);
  if (*reinterpret_cast<void* const*>(bytes + 0x4e8) ||
      *reinterpret_cast<const bool*>(bytes + 0x1988) ||
      *reinterpret_cast<void* const*>(bytes + 0x19a0)) return;
  auto app = reinterpret_cast<void*(*)()>(base + 0xbb23c0)();
  if (!app || issued.exchange(true)) return;
  Emit("default-generator-enter");
  std::array<void*, 2> capture{app, menu};
  // Native entry point, with the selected configuration supplied by the
  // scoped adapters above. Never call it while a UI callback holds its locks.
  preparing = true;
  reinterpret_cast<void(*)(void*)>(base + 0xc14ba0)(capture.data());
  generation_rep = nullptr;
  preparing = false;
  Emit("default-generator-return");
}

void __fastcall AfterMenuUpdate(void* menu, void* a2, void* a3, void* a4) {
  original_update(menu, a2, a3, a4);
  observed_menu = menu;
  menu_thread = GetCurrentThreadId();
}

int __cdecl AfterPollEvent(void* event) {
  const int result = original_poll(event);
  if (!result && GetCurrentThreadId() == menu_thread) {
    Generate(observed_menu);
    if (issued.load() && observed_menu && !save_stem.empty()) {
      const auto menu = static_cast<std::byte*>(observed_menu);
      auto game_ui = *reinterpret_cast<std::byte**>(menu + 0x4e8);
      if (game_ui && !*reinterpret_cast<bool*>(menu + 0x1988)) {
        if (!world_frame) { world_frame = GetTickCount64(); Emit("native-world-ready"); }
        if (!save_issued && GetTickCount64() - world_frame > 10000) {
          save_issued = true;
          // This world was generated in our sole-owned process, never loaded
          // from a player's save. Scope native autosave naming/rotation to an
          // unpredictable lab name before requesting a complete native save.
          reinterpret_cast<void*(*)(void*,const char*,std::size_t)>(base + 0x83270)(game_ui + 0x520,save_stem.data(),save_stem.size());
          Emit("native-save-enter");
          reinterpret_cast<void(*)(void*)>(base + 0x563500)(game_ui);
          Emit("native-save-submitted");
        } else if (save_issued && !save_completed && !*reinterpret_cast<bool*>(game_ui + 0xb48)) {
          save_completed = true; Emit("native-save-idle");
        }
      }
    }
  }
  return result;
}

DWORD WINAPI Worker(void*) {
  const auto module = GetModuleHandleW(nullptr);
  const auto validation = tpf2mp::ValidatePinnedModule(module);
  if (!validation.valid) {
    std::string error;
    tpf2mp::AtomicWriteUtf8(tpf2mp::NativeStatusPath(GetCurrentProcessId()),
        "{\"stage\":\"rejected\",\"active\":false,\"worldgenLab\":true}", error);
    return 3;
  }
  wchar_t buffer[32768]{};
  const DWORD length = GetEnvironmentVariableW(L"TPF2MP_WORLDGEN_LAB_MARKER", buffer, 32768);
  if (!length || length >= 32768) return 1;
  marker = buffer;
  if (!marker.is_absolute() || !std::filesystem::is_directory(marker.parent_path()) ||
      std::filesystem::exists(marker)) return 2;
  base = reinterpret_cast<std::uintptr_t>(module);
  wchar_t preview_flag[8]{};
  preview_only = GetEnvironmentVariableW(L"TPF2MP_WORLDGEN_PREVIEW_ONLY",preview_flag,8) && std::wstring(preview_flag) == L"1";
  preview_export = GetEnvironmentVariableW(L"TPF2MP_WORLDGEN_PREVIEW_EXPORT",preview_flag,8) && std::wstring(preview_flag) == L"1";
  wchar_t save[128]{};
  if (GetEnvironmentVariableW(L"TPF2MP_WORLDGEN_LAB_SAVE", save, 128)) {
    save_stem = tpf2mp::WideToUtf8(save);
    if (!save_stem.starts_with("tpf2mp_worldgen_lab_") ||
        save_stem.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") != std::string::npos)
      return 5;
  }
  wchar_t selected[64]{};
  if (GetEnvironmentVariableW(L"TPF2MP_WORLDGEN_LAB_MOD", selected, 64) &&
      std::wstring(selected) == L"tpf2_mp") mods.push_back({"!tpf2_mp",1});
  configured = GetEnvironmentVariableW(L"TPF2MP_WORLDGEN_LAB_CONFIGURED", selected, 64) && std::wstring(selected) == L"1";
  if (configured) {
    mod_params["!tpf2_mp_1"] = {{"agentMode",0},{"economyDifficulty",2},{"startupMode",0}};
    mod_params[""] = {{"locations.mapSize",0},{"locations.towns.frequency",1},
        {"locations.industry.maxNumberPerArea",1}};
  }
  wchar_t request[32768]{};
  const auto request_length = GetEnvironmentVariableW(L"TPF2MP_WORLDGEN_REQUEST",request,32768);
  if (request_length) {
    try {
      if (request_length >= 32768 || !ReadRequest(request)) { Emit("invalid-request"); return 6; }
    } catch (...) { Emit("unreadable-request"); return 6; }
  }
  if (MH_Initialize() != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(base + 0x672b10),
                    reinterpret_cast<void*>(AfterMenuUpdate),
                    reinterpret_cast<void**>(&original_update)) != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"SDL2.dll"), "SDL_PollEvent")),
                    reinterpret_cast<void*>(AfterPollEvent), reinterpret_cast<void**>(&original_poll)) != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(base + 0xb2f520), reinterpret_cast<void*>(Config), reinterpret_cast<void**>(&original_config)) != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(base + 0x677d00), reinterpret_cast<void*>(Start), reinterpret_cast<void**>(&original_start)) != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(base + 0xc10830), reinterpret_cast<void*>(Generator), reinterpret_cast<void**>(&original_generator)) != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(base + 0x39b420), reinterpret_cast<void*>(SelectGenerator), reinterpret_cast<void**>(&original_rep)) != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(base + 0x36c2c0), reinterpret_cast<void*>(ObserveClimate), reinterpret_cast<void**>(&original_climate)) != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(base + 0x2c61b0), reinterpret_cast<void*>(GenerationIndex), reinterpret_cast<void**>(&original_index)) != MH_OK ||
      MH_CreateHook(reinterpret_cast<void*>(base + 0x22e0c10), reinterpret_cast<void*>(Terrain), reinterpret_cast<void**>(&original_terrain)) != MH_OK ||
      MH_EnableHook(MH_ALL_HOOKS) != MH_OK) {
    Emit("hook-failed"); return 4;
  }
  Emit("lab-active");
  std::string error;
  tpf2mp::AtomicWriteUtf8(tpf2mp::NativeStatusPath(GetCurrentProcessId()),
      "{\"processId\":" + std::to_string(GetCurrentProcessId()) +
      ",\"stage\":\"active\",\"active\":true,\"worldgenLab\":true}", error);
  return 0;
}
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    DisableThreadLibraryCalls(instance);
    HANDLE worker = CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr);
    if (!worker) return FALSE;
    CloseHandle(worker);
  }
  return TRUE;
}
