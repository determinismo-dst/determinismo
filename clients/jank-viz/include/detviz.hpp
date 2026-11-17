// SPDX-License-Identifier: MIT
// determinismo's visualization, the native side: one window (GLFW, Dear ImGui on OpenGL 2), its
// fonts, drawing primitives in points from the window's top left, and its frames recorded to a
// video (ffmpeg reading them from a pipe) for demos. What is drawn, and where, is jank's
// (determinismo.viz): every argument here is a jank object, so jank calls these as they are.
#pragma once

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include <GLFW/glfw3.h>
#if defined(__APPLE__)
/* The framebuffer object extension (GLFW's header leaves the extensions out). */
#  include <OpenGL/glext.h>
#endif
#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl2.h"

#include <jank/runtime/core/math.hpp>
#include <jank/runtime/core/to_string.hpp>
#include <jank/runtime/core/truthy.hpp>

namespace detviz
{
  using obj = jank::runtime::object_ref;

  inline double num(obj const o)
  {
    return jank::runtime::to_real(o);
  }

  inline std::string str(obj const o)
  {
    auto const s(jank::runtime::to_string(o));
    return std::string(s.data(), s.size());
  }

  struct state
  {
    GLFWwindow *window{};
    /* Text sizes: 0 small, 1 normal, 2 large (mono); 3 normal, 4 large (serif). */
    ImFont *fonts[5]{};
    float sizes[5]{ 12.0f, 14.0f, 18.0f, 15.0f, 26.0f };
    FILE *recording{};
    std::vector<unsigned char> pixels;
    /* A recording's frames: drawn into a framebuffer of its own, the size asked, whatever the
     * display gave the window (a laptop's is shorter than 1080 points, and doubles pixels). */
    int frame_width{}, frame_height{};
    unsigned target{}, target_color{};
    std::chrono::steady_clock::time_point recording_start;
    std::chrono::steady_clock::time_point frame_next;
    long frames_written{};
    long frames_drawn{};
    /* The next frame also written here (a PPM image), then cleared. */
    std::string snapshot;
    unsigned background{ 0xfdf6d8 };
  };

  inline state &get()
  {
    static state s;
    return s;
  }

  inline ImU32 color(obj const rgb, double const alpha)
  {
    auto const value(static_cast<unsigned>(num(rgb)));
    return IM_COL32((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff, static_cast<int>(alpha * 255.0));
  }

  /* The window: `hidden` renders without showing (a recording); `record` is the video's path
   * ("" for none), frames written at 30 a second of wall time, its first one's wall-clock time
   * (ms since the epoch) in `<record>.start`. */
  inline bool open(obj const width, obj const height, obj const hidden, obj const record)
  {
    auto &s(get());
    if(s.window)
    {
      return true;
    }
    if(!glfwInit())
    {
      return false;
    }
    auto const path(str(record));
    glfwWindowHint(GLFW_VISIBLE, jank::runtime::truthy(hidden) ? GLFW_FALSE : GLFW_TRUE);
    s.window = glfwCreateWindow(static_cast<int>(num(width)), static_cast<int>(num(height)), "determinismo", nullptr, nullptr);
    if(!s.window)
    {
      return false;
    }
    glfwMakeContextCurrent(s.window);
    glfwSwapInterval(1);
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    auto &io(ImGui::GetIO());
    io.IniFilename = nullptr;
    ImGui::StyleColorsLight();
    int window_width{}, frame_width{}, unused{};
    glfwGetWindowSize(s.window, &window_width, &unused);
    glfwGetFramebufferSize(s.window, &frame_width, &unused);
    /* A recording is drawn at one pixel a point. */
    auto const scale(!path.empty() || window_width <= 0 ? 1.0f : static_cast<float>(frame_width) / static_cast<float>(window_width));
    char const *mono("/System/Library/Fonts/Menlo.ttc");
    char const *serif("/System/Library/Fonts/Supplemental/Georgia.ttf");
    for(int i{}; i < 5; ++i)
    {
      s.fonts[i] = io.Fonts->AddFontFromFileTTF(i < 3 ? mono : serif, s.sizes[i] * scale);
      if(!s.fonts[i])
      {
        s.fonts[i] = io.Fonts->AddFontDefault();
      }
    }
    io.FontGlobalScale = 1.0f / scale;
    ImGui_ImplGlfw_InitForOpenGL(s.window, true);
    ImGui_ImplOpenGL2_Init();
    if(!path.empty())
    {
      s.frame_width = static_cast<int>(num(width));
      s.frame_height = static_cast<int>(num(height));
      glGenTextures(1, &s.target_color);
      glBindTexture(GL_TEXTURE_2D, s.target_color);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB8, s.frame_width, s.frame_height, 0, GL_RGB, GL_UNSIGNED_BYTE, nullptr);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glBindTexture(GL_TEXTURE_2D, 0);
      glGenFramebuffersEXT(1, &s.target);
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, s.target);
      glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, s.target_color, 0);
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
      s.frame_next = std::chrono::steady_clock::now();
      char command[2048];
      std::snprintf(command, sizeof(command),
                    "ffmpeg -loglevel error -y -f rawvideo -pixel_format rgb24 -video_size %dx%d -framerate 30 -i - "
                    "-vf vflip -c:v libx264 -preset veryfast -crf 16 -pix_fmt yuv420p '%s'",
                    s.frame_width, s.frame_height, path.c_str());
      s.recording = popen(command, "w");
      s.pixels.resize(static_cast<size_t>(s.frame_width) * static_cast<size_t>(s.frame_height) * 3);
    }
    return true;
  }

  inline bool alive()
  {
    auto &s(get());
    return s.window && !glfwWindowShouldClose(s.window);
  }

  inline void stop()
  {
    auto &s(get());
    if(s.window)
    {
      glfwSetWindowShouldClose(s.window, GLFW_TRUE);
    }
  }

  inline double width()
  {
    return ImGui::GetIO().DisplaySize.x;
  }

  inline double height()
  {
    return ImGui::GetIO().DisplaySize.y;
  }

  /* Seconds since the window opened: what moves (a cursor's pulse) reads it. */
  inline double seconds()
  {
    return glfwGetTime();
  }

  inline void frame_begin(obj const background)
  {
    auto &s(get());
    s.background = static_cast<unsigned>(num(background));
    glfwPollEvents();
    ImGui_ImplOpenGL2_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    if(s.target)
    {
      ImGui::GetIO().DisplaySize = ImVec2(static_cast<float>(s.frame_width), static_cast<float>(s.frame_height));
      ImGui::GetIO().DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
    }
    ImGui::NewFrame();
    /* One window over everything, nothing of its own drawn: the primitives' canvas. */
    ImGui::SetNextWindowPos(ImVec2(0.0f, 0.0f));
    ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
    ImGui::Begin("canvas", nullptr,
                 ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBackground
                   | ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
  }

  inline void frame_end()
  {
    auto &s(get());
    ImGui::End();
    ImGui::Render();
    int frame_width{ s.frame_width }, frame_height{ s.frame_height };
    if(s.target)
    {
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, s.target);
    }
    else
    {
      glfwGetFramebufferSize(s.window, &frame_width, &frame_height);
    }
    glViewport(0, 0, frame_width, frame_height);
    glClearColor(static_cast<float>((s.background >> 16) & 0xff) / 255.0f,
                 static_cast<float>((s.background >> 8) & 0xff) / 255.0f,
                 static_cast<float>(s.background & 0xff) / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL2_RenderDrawData(ImGui::GetDrawData());
    ++s.frames_drawn;
    if(!s.target)
    {
      glfwSwapBuffers(s.window);
      return;
    }
    if(s.recording)
    {
      glPixelStorei(GL_PACK_ALIGNMENT, 1);
      glReadPixels(0, 0, frame_width, frame_height, GL_RGB, GL_UNSIGNED_BYTE, s.pixels.data());
      auto const now(std::chrono::steady_clock::now());
      if(s.frames_written == 0)
      {
        s.recording_start = now;
        auto const epoch(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
        std::fprintf(stderr, "[detviz] capture %lld\n", static_cast<long long>(epoch));
      }
      /* As many frames as the wall clock asks at 30 a second: one repeated when frames are slow. */
      auto const elapsed(std::chrono::duration<double>(now - s.recording_start).count());
      auto const due(static_cast<long>(elapsed * 30.0) + 1);
      while(s.frames_written < due)
      {
        std::fwrite(s.pixels.data(), 1, s.pixels.size(), s.recording);
        ++s.frames_written;
      }
    }
    if(!s.snapshot.empty())
    {
      if(FILE *out{ std::fopen(s.snapshot.c_str(), "wb") })
      {
        std::fprintf(out, "P6\n%d %d\n255\n", frame_width, frame_height);
        for(int y{ frame_height - 1 }; y >= 0; --y)
        {
          std::fwrite(s.pixels.data() + static_cast<size_t>(y) * static_cast<size_t>(frame_width) * 3, 1, static_cast<size_t>(frame_width) * 3, out);
        }
        std::fclose(out);
      }
      s.snapshot.clear();
    }
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    /* No display paces a framebuffer of its own: 60 frames a second by the clock. */
    s.frame_next += std::chrono::microseconds(16667);
    auto const now(std::chrono::steady_clock::now());
    if(s.frame_next < now)
    {
      s.frame_next = now;
    }
    std::this_thread::sleep_until(s.frame_next);
  }

  inline double frames()
  {
    return static_cast<double>(get().frames_drawn);
  }

  inline void snapshot(obj const path)
  {
    get().snapshot = str(path);
  }

  /* What a command prints (the bytes at an address disassembled: llvm-mc), as it is. */
  inline std::string run(std::string const &command)
  {
    std::string out;
    if(FILE *pipe{ popen(command.c_str(), "r") })
    {
      char buffer[4096];
      size_t size{};
      while((size = std::fread(buffer, 1, sizeof(buffer), pipe)) > 0)
      {
        out.append(buffer, size);
      }
      pclose(pipe);
    }
    return out;
  }

  inline void close()
  {
    auto &s(get());
    if(s.recording)
    {
      pclose(s.recording);
      s.recording = nullptr;
    }
    if(s.window)
    {
      ImGui_ImplOpenGL2_Shutdown();
      ImGui_ImplGlfw_Shutdown();
      ImGui::DestroyContext();
      glfwDestroyWindow(s.window);
      glfwTerminate();
      s.window = nullptr;
    }
  }

  /* The process ended here, after `close` (its video whole: ffmpeg waited for), with no static
   * destructors: jank's own exit destroyed the JIT under the nREPL thread still compiling the
   * evaluation that asked the window to stop, an abort and a crash report at every take's end
   * (2026-11-15). */
  [[noreturn]] inline void quit()
  {
    std::fflush(nullptr);
    std::_Exit(0);
  }

  /* What is drawn until clip_end is cut to this rectangle (the feed's cards roll under the map). */
  inline void clip_begin(obj const x1, obj const y1, obj const x2, obj const y2)
  {
    ImGui::GetWindowDrawList()->PushClipRect(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                             ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))), true);
  }

  inline void clip_end()
  {
    ImGui::GetWindowDrawList()->PopClipRect();
  }

  inline int font_of(obj const size)
  {
    auto const index(static_cast<int>(num(size)));
    return index < 0 ? 0 : (index > 4 ? 4 : index);
  }

  inline void text(obj const x, obj const y, obj const rgb, obj const size, obj const what)
  {
    auto &s(get());
    auto const index(font_of(size));
    auto const said(str(what));
    ImGui::GetWindowDrawList()->AddText(s.fonts[index], s.sizes[index],
                                        ImVec2(static_cast<float>(num(x)), static_cast<float>(num(y))),
                                        color(rgb, 1.0), said.c_str());
  }

  inline double text_width(obj const size, obj const what)
  {
    auto &s(get());
    auto const index(font_of(size));
    auto const said(str(what));
    return s.fonts[index]->CalcTextSizeA(s.sizes[index], 100000.0f, 0.0f, said.c_str()).x;
  }

  inline void line(obj const x1, obj const y1, obj const x2, obj const y2, obj const rgb, obj const thickness)
  {
    ImGui::GetWindowDrawList()->AddLine(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                        ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))),
                                        color(rgb, 1.0), static_cast<float>(num(thickness)));
  }

  /* From (x1, y1) level, down (or up) to (x2, y2) level: a timeline leaving another. */
  inline void curve(obj const x1, obj const y1, obj const x2, obj const y2, obj const rgb, obj const thickness)
  {
    auto const ax(static_cast<float>(num(x1))), ay(static_cast<float>(num(y1)));
    auto const bx(static_cast<float>(num(x2))), by(static_cast<float>(num(y2)));
    auto const mid((ax + bx) / 2.0f);
    ImGui::GetWindowDrawList()->AddBezierCubic(ImVec2(ax, ay), ImVec2(mid, ay), ImVec2(mid, by), ImVec2(bx, by),
                                               color(rgb, 1.0), static_cast<float>(num(thickness)));
  }

  inline void rect(obj const x1, obj const y1, obj const x2, obj const y2, obj const rgb, obj const alpha, obj const rounding)
  {
    ImGui::GetWindowDrawList()->AddRectFilled(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                              ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))),
                                              color(rgb, num(alpha)), static_cast<float>(num(rounding)));
  }

  inline void frame(obj const x1, obj const y1, obj const x2, obj const y2, obj const rgb, obj const thickness)
  {
    ImGui::GetWindowDrawList()->AddRect(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                        ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))),
                                        color(rgb, 1.0), 0.0f, 0, static_cast<float>(num(thickness)));
  }

  inline void circle(obj const x, obj const y, obj const radius, obj const rgb, obj const alpha)
  {
    ImGui::GetWindowDrawList()->AddCircleFilled(ImVec2(static_cast<float>(num(x)), static_cast<float>(num(y))),
                                                static_cast<float>(num(radius)), color(rgb, num(alpha)), 24);
  }

  inline void ring(obj const x, obj const y, obj const radius, obj const rgb, obj const thickness)
  {
    ImGui::GetWindowDrawList()->AddCircle(ImVec2(static_cast<float>(num(x)), static_cast<float>(num(y))),
                                          static_cast<float>(num(radius)), color(rgb, 1.0), 24, static_cast<float>(num(thickness)));
  }
}
