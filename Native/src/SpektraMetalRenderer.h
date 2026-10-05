#pragma once

#include <memory>
#include <string>

#include "SpektraRenderer.h"

namespace spektrafilm {

using MetalPassDiagnostics = RendererPassDiagnostics;
using MetalRenderDiagnostics = RendererDiagnostics;

struct MetalBufferImageView {
  void *buffer = nullptr;
  int32_t x1 = 0;
  int32_t y1 = 0;
  int32_t width = 0;
  int32_t height = 0;
  int32_t rowBytes = 0;
  int32_t components = 0;
  int32_t bytesPerComponent = 0;
};

class MetalRenderer final : public Renderer {
public:
  MetalRenderer();
  ~MetalRenderer() override;

  MetalRenderer(const MetalRenderer &) = delete;
  MetalRenderer &operator=(const MetalRenderer &) = delete;

  bool isAvailable() const override;
  const MetalRenderDiagnostics &lastDiagnostics() const override;
  const std::string &lastError() const override;
  void releaseTransientResources() override;
  bool startGpuTraceCapture(const std::string &path);
  void stopGpuTraceCapture();

  bool render(
    const ImageView &source,
    const MutableImageView &destination,
    const RenderWindow &window,
    const RenderParams &params,
    double time
  ) override;

  bool renderMetalBuffers(
    const MetalBufferImageView &source,
    const MetalBufferImageView &destination,
    const RenderWindow &window,
    const RenderParams &params,
    double time,
    void *commandQueue
  );

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace spektrafilm
