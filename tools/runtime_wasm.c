#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
static unsigned char io_buffer[65536];
__attribute__((import_module("wasi_snapshot_preview1"),
               import_name("fd_write"))) extern uint32_t
nf_host_write(uint32_t, uint32_t, uint32_t, uint32_t);
uint16_t __wasi_fd_write(uint32_t fd, const __wasi_ciovec_t *raw, size_t count,
                         size_t *out) {
  const uint64_t *iov = (const uint64_t *)raw;
  *out = 0;
  for (size_t i = 0; i < count; i++) {
    const unsigned char *p = (const void *)(uintptr_t)iov[i * 2];
    uint64_t len = iov[i * 2 + 1];
    while (len) {
      uint32_t n = len > 65536 ? 65536 : (uint32_t)len;
      for (uint32_t j = 0; j < n; j++)
        io_buffer[j] = p[j];
      uint32_t v[2] = {(uint32_t)(uintptr_t)io_buffer, n}, written = 0;
      uint32_t err = nf_host_write(fd, (uint32_t)(uintptr_t)v, 1,
                                   (uint32_t)(uintptr_t)&written);
      if (err)
        return err;
      if (!written || written > n)
        return 29;
      p += written;
      len -= written;
      *out += written;
    }
  }
  return 0;
}
uint16_t __wasi_fd_close(uint32_t fd) { return 0; }
uint16_t __wasi_fd_seek(uint32_t fd, int64_t offset, uint8_t whence,
                        uint64_t *out) {
  return 70;
}

/* These regions have stable addresses in the precompiled memory64 runtime. */
unsigned char nifty_metadata[1048576];
/* Reserve entry and failed-call header space below the charged script stack. */
unsigned char nifty_stack[4194304 + 64] __attribute__((aligned(16)));

__attribute__((noinline, used, export_name("nifty_entry"))) void
nifty_entry(void *context, void *arena) {
  __asm__ volatile("" : : "r"(context), "r"(arena) : "memory");
}

/* Preserve the replaceable entry across development-time whole-module passes. */
static void (*volatile script_entry)(void *, void *) = nifty_entry;
uintptr_t nf_get_entry(void) { return (uintptr_t)script_entry; }

extern void NimMain(void);
extern void __wasm_call_ctors(void);
__attribute__((export_name("_start"))) void _start(void) {
  __wasm_call_ctors();
  NimMain();
}

__attribute__((import_module("wasi_snapshot_preview1"),
               import_name("proc_exit"))) extern void
nf_host_exit(uint32_t status);

__attribute__((noreturn)) void nf_exit(uint32_t status) {
  nf_host_exit(status);
  __builtin_unreachable();
}

void nf_emit(uint32_t fd, const void *data, size_t size) {
  uint64_t iov[2] = {(uintptr_t)data, size};
  size_t written;
  if (__wasi_fd_write(fd, (const __wasi_ciovec_t *)iov, 1, &written))
    nf_exit(1);
}

/* Hosts obtain fresh memory views on each I/O callback. */
void emscripten_notify_memory_growth(size_t memory_index) { (void)memory_index; }

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define NF_EXPORT(name) __attribute__((used, export_name("nf_ext_" #name)))
NF_EXPORT(write) int64_t nf_ext_write(int64_t fd, uint64_t address, int64_t size) {
  if (size < 0 || fd < 0 || fd > UINT32_MAX) return -1;
  uint64_t iov[2] = {address, (uint64_t)size};
  size_t written = 0;
  if (__wasi_fd_write((uint32_t)fd, (const __wasi_ciovec_t *)iov, 1, &written)) return -1;
  return (int64_t)written;
}
NF_EXPORT(fflush) int64_t nf_ext_fflush(uint64_t stream) {
  return (int64_t)fflush((FILE *)(uintptr_t)stream);
}
NF_EXPORT(_Exit) void nf_ext__Exit(int64_t status) { nf_exit((uint32_t)status); }
NF_EXPORT(nifty_stdout_stream) uint64_t nf_ext_nifty_stdout_stream(void) {
  return (uintptr_t)stdout;
}
NF_EXPORT(nifty_stdout_lock) void nf_ext_nifty_stdout_lock(void) {}
NF_EXPORT(nifty_stdout_unlock) void nf_ext_nifty_stdout_unlock(void) {}
NF_EXPORT(nifty_format_float) int64_t nf_ext_nifty_format_float(
    double value, uint64_t buffer, uint64_t count) {
  return (int64_t)snprintf((char *)(uintptr_t)buffer, (size_t)count, "%g", value);
}
NF_EXPORT(strlen) uint64_t nf_ext_strlen(uint64_t address) {
  return strlen((const char *)(uintptr_t)address);
}
NF_EXPORT(memset) uint64_t nf_ext_memset(uint64_t address, int64_t value,
    int64_t count) {
  return (uintptr_t)memset((void *)(uintptr_t)address, (int)value, (size_t)count);
}
#define NF_COPY(name) NF_EXPORT(name) uint64_t nf_ext_##name(uint64_t a, \
    uint64_t b, int64_t n) { return (uintptr_t)name((void *)(uintptr_t)a, \
      (const void *)(uintptr_t)b, (size_t)n); }
NF_COPY(memcpy)
NF_COPY(memmove)
NF_EXPORT(memcmp) int64_t nf_ext_memcmp(uint64_t a, uint64_t b, int64_t n) {
  return (int64_t)memcmp((const void *)(uintptr_t)a,
    (const void *)(uintptr_t)b, (size_t)n);
}
NF_EXPORT(strcmp) int64_t nf_ext_strcmp(uint64_t a, uint64_t b) {
  return (int64_t)strcmp((const char *)(uintptr_t)a, (const char *)(uintptr_t)b);
}
NF_EXPORT(strncmp) int64_t nf_ext_strncmp(uint64_t a, uint64_t b, int64_t n) {
  return (int64_t)strncmp((const char *)(uintptr_t)a,
    (const char *)(uintptr_t)b, (size_t)n);
}
NF_EXPORT(abs) int64_t nf_ext_abs(int64_t a) { return (int64_t)abs((int32_t)a); }
NF_EXPORT(labs) int64_t nf_ext_labs(int64_t a) { return (int64_t)llabs(a); }
NF_EXPORT(llabs) int64_t nf_ext_llabs(int64_t a) { return (int64_t)llabs(a); }
#define NF_UNARY(name, type) NF_EXPORT(name) type nf_ext_##name(type a) { return name(a); }
#define NF_BINARY(name, type) NF_EXPORT(name) type nf_ext_##name(type a, type b) { return name(a, b); }
#define NF_MATH(name) NF_UNARY(name, double) NF_UNARY(name##f, float)
NF_MATH(sqrt)
NF_MATH(floor)
NF_MATH(round)
NF_MATH(ceil)
NF_MATH(trunc)
NF_MATH(fabs)
NF_MATH(sin)
NF_MATH(cos)
NF_MATH(tan)
NF_MATH(asin)
NF_MATH(acos)
NF_MATH(atan)
NF_MATH(exp)
NF_MATH(log)
NF_MATH(log10)
#define NF_MATH2(name) NF_BINARY(name, double) NF_BINARY(name##f, float)
NF_MATH2(pow)
NF_MATH2(atan2)
NF_MATH2(fmod)
NF_MATH2(hypot)
__attribute__((import_module("wasi_snapshot_preview1"),
               import_name("clock_time_get"))) extern uint32_t
nf_host_clock_time_get(uint32_t, uint64_t, uint32_t);
static uint64_t clock_result;
NF_EXPORT(clock_gettime) int64_t nf_ext_clock_gettime(int64_t clock,
    uint64_t address) {
  if (clock != 0 && clock != 1) return -1;
  if (nf_host_clock_time_get((uint32_t)clock, 1,
      (uint32_t)(uintptr_t)&clock_result)) return -1;
  int64_t *out = (int64_t *)(uintptr_t)address;
  out[0] = (int64_t)(clock_result / 1000000000);
  out[1] = (int64_t)(clock_result % 1000000000);
  return 0;
}
NF_EXPORT(gettimeofday) int64_t nf_ext_gettimeofday(uint64_t address,
    uint64_t timezone) {
  (void)timezone;
  if (nf_host_clock_time_get(0, 1000,
      (uint32_t)(uintptr_t)&clock_result)) return -1;
  if (address) {
    int64_t *out = (int64_t *)(uintptr_t)address;
    out[0] = (int64_t)(clock_result / 1000000000);
    out[1] = (int64_t)((clock_result % 1000000000) / 1000);
  }
  return 0;
}
