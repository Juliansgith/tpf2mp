// Build 35924 isolated generator only. Off-screen MapPreviewComp uses the
// game's own CPU terrain shader; no camera, desktop capture, or playable world.
#pragma once
#include <stdexcept>
#include <cmath>
namespace {
constexpr unsigned PreviewCrop(unsigned tiles, unsigned resolution, unsigned factor, unsigned extent) {
  const unsigned samples = (tiles*(1u<<resolution)+factor)/factor;
  return samples > extent ? extent : samples;
}
static_assert(PreviewCrop(32,6,2,1024) == 1024); // exact power-of-two + border
static_assert(PreviewCrop(44,6,4,1024) == 705);
static_assert(PreviewCrop(56,6,4,1024) == 897);
void ExportNativeMapPreview(std::uintptr_t image, void* provider, void* climate,
                            void* map, const std::filesystem::path& directory) {
  if (!provider || !climate || !map) throw std::runtime_error("missing native preview inputs");
  const auto data = static_cast<const std::byte*>(map);
  const int tiles_x = *reinterpret_cast<const int*>(data);
  const int tiles_y = *reinterpret_cast<const int*>(data+4);
  const int resolution = *reinterpret_cast<const int*>(data+8);
  if (tiles_x < 1 || tiles_x > 64 || tiles_y < 1 || tiles_y > 64 || resolution < 1 || resolution > 10)
    throw std::runtime_error("unexpected generated map dimensions");
  const auto& heights = *reinterpret_cast<const std::vector<float>*>(data+0x20);
  const std::size_t expected = (std::size_t(tiles_x)*(std::size_t(1)<<resolution)+1)*(std::size_t(tiles_y)*(std::size_t(1)<<resolution)+1);
  if (heights.size() != expected || expected > 40000000) throw std::runtime_error("unexpected native heightmap extent");
  using Allocate = void*(*)(std::size_t);
  using Construct = void*(*)(void*,void*,void*,bool);
  auto allocation = reinterpret_cast<Allocate>(image+0x2bf3a80)(0x498);
  if (!allocation) throw std::bad_alloc();
  // Same constructor/size/font argument as the native map-generation page.
  const auto font = *reinterpret_cast<void**>(image+0x4133390);
  auto component = static_cast<std::byte*>(reinterpret_cast<Construct>(image+0x63a190)(allocation,climate,font,false));
  const auto destroy = [image](std::byte* value) {
    reinterpret_cast<void(*)(void*,unsigned)>(image+0x63b780)(value,1);
  };
  const std::unique_ptr<std::byte,decltype(destroy)> owned_component(component,destroy);
  auto state = *reinterpret_cast<std::byte**>(component+0x448);
  alignas(8) std::array<std::byte,64> status{};
  alignas(8) std::array<std::byte,64> no_overlay{};
  using Render = void(*)(void*,void*,void*,void*,void*,void*,void*,void*);
  reinterpret_cast<Render>(image+0x63ca90)(provider,climate,map,
      *reinterpret_cast<void**>(state+0x78),*reinterpret_cast<void**>(state+0x80),
      state+0x88,status.data(),no_overlay.data());
  const auto& pixels = *reinterpret_cast<const std::vector<unsigned char>*>(state+0x88);
  unsigned width=1, height=1;
  while (width < unsigned(tiles_x)*(1u<<resolution)) width *= 2;
  while (height < unsigned(tiles_y)*(1u<<resolution)) height *= 2;
  unsigned factor = 1;
  while (width/factor > 1024 || height/factor > 1024) factor *= 2;
  width /= factor; height /= factor;
  if (pixels.size() != std::size_t(width)*height*4) throw std::runtime_error("native preview pixel extent mismatch");
  const auto path = directory / "preview-native.rgba";
  if (std::filesystem::exists(path)) throw std::runtime_error("preview output already exists");
  std::ofstream output(path,std::ios::binary);
  // The native widget applies UV bounds to its power-of-two texture. Export
  // those same bounds, rather than the unused transparent texture padding.
  unsigned crop_width = PreviewCrop(tiles_x,resolution,factor,width);
  unsigned crop_height = PreviewCrop(tiles_y,resolution,factor,height);
  // At exact powers of two the native UV extends by one border sample;
  // its sampler clamps at the texture edge. Never read a nonexistent row.
  output.write(reinterpret_cast<const char*>(&crop_width),4);
  output.write(reinterpret_cast<const char*>(&crop_height),4);
  for (unsigned y=0; y<crop_height; ++y)
    output.write(reinterpret_cast<const char*>(pixels.data()+std::size_t(y)*width*4),crop_width*4);
  output.close();
  if (!output) throw std::runtime_error("preview output write failed");
  const float sx = *reinterpret_cast<const float*>(data+0xc);
  const float sy = *reinterpret_cast<const float*>(data+0x10);
  std::ofstream landmarks(directory / "preview-markers.json");
  landmarks << "[";
  bool first = true;
  for (int kind=0; kind<2; ++kind) {
    const auto pointers = reinterpret_cast<const std::byte* const*>(data+(kind==0 ? 0x118 : 0x130));
    const auto stride = kind==0 ? 128 : 56;
    if (!pointers[0] && !pointers[1]) continue;
    if (!pointers[0] || !pointers[1]) throw std::runtime_error("incomplete landmark extent");
    const auto bytes = pointers[1]-pointers[0];
    if (bytes < 0 || bytes % stride || bytes/stride > 4096) throw std::runtime_error("invalid landmark extent");
    for (auto item=pointers[0]; item!=pointers[1]; item+=stride) {
      const auto pos = reinterpret_cast<const float*>(item);
      const auto& name = *reinterpret_cast<const std::string*>(item+(kind==0 ? 8 : 16));
      const float x=(pos[0]+float(tiles_x/2*(1u<<resolution))*sx)/(float(tiles_x*(1u<<resolution)+1)*sx);
      const float y=(pos[1]+float(tiles_y/2*(1u<<resolution))*sy)/(float(tiles_y*(1u<<resolution)+1)*sy);
      if (!std::isfinite(x) || !std::isfinite(y) || x<0 || x>1 || y<0 || y>1 || name.size()>256)
        throw std::runtime_error("invalid native landmark");
      if (!first) landmarks << ",";
      first=false;
      landmarks << "{\"kind\":\"" << (kind==0 ? "town" : "industry") << "\",\"x\":" << x
                << ",\"y\":" << y << ",\"name\":\"" << tpf2mp::JsonEscape(name) << "\"}";
    }
  }
  landmarks << "]"; landmarks.close();
  if (!landmarks) throw std::runtime_error("landmark write failed");
  // Native destructor releases the component's full child tree and textures
  // before generation can proceed. Required by CCore's shutdown instance gate.
}
}
