#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <stdio.h>

/* Read-only pbuffer probe; no app data, windows, files, or network access. */
int main(void) {
  EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  EGLint major = 0, minor = 0;
  if (!eglInitialize(display, &major, &minor)) {
    printf("egl_initialize_error=0x%x\n", eglGetError());
    return 1;
  }
  printf("egl_version=%d.%d vendor=%s\n", major, minor, eglQueryString(display, EGL_VENDOR));
  for (int version = 2; version <= 3; ++version) {
    for (int samples = 0; samples <= 4; samples += 4) {
      EGLint attrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
        version == 3 ? 0x0040 : EGL_OPENGL_ES2_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_SAMPLE_BUFFERS, samples == 0 ? 0 : 1, EGL_SAMPLES, samples, EGL_NONE };
      EGLConfig config;
      EGLint count = 0;
      if (!eglChooseConfig(display, attrs, &config, 1, &count) || count == 0) {
        printf("requested_es=%d samples=%d config_unavailable error=0x%x\n", version, samples, eglGetError());
        continue;
      }
      EGLint context_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, version, EGL_NONE };
      EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
      EGLint surface_attrs[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
      EGLSurface surface = eglCreatePbufferSurface(display, config, surface_attrs);
      if (context == EGL_NO_CONTEXT || surface == EGL_NO_SURFACE || !eglMakeCurrent(display, surface, surface, context)) {
        printf("requested_es=%d samples=%d context_unavailable error=0x%x\n", version, samples, eglGetError());
      } else {
        GLint vectors = 0;
        glGetIntegerv(GL_MAX_FRAGMENT_UNIFORM_VECTORS, &vectors);
        printf("requested_es=%d samples=%d fragment_uniform_vectors=%d gl=%s renderer=%s\n",
          version, samples, vectors, glGetString(GL_VERSION), glGetString(GL_RENDERER));
      }
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
      if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
    }
  }
  eglTerminate(display);
  return 0;
}
