/* Original line-only A, with the same integer scanline algorithm as Nifty. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

#ifndef IMAGE_SIZE
#define IMAGE_SIZE 128
#endif
#ifndef REPETITIONS
#define REPETITIONS 256
#endif
#ifndef CLOCK_ID
#define CLOCK_ID CLOCK_MONOTONIC
#endif
#define PIXELS (IMAGE_SIZE * IMAGE_SIZE)
#define SUB_SIZE (IMAGE_SIZE * 4)
#define EDGES 11
#define MAX_CHECKSUM ((int64_t)PIXELS * PIXELS * 16)

typedef struct { int64_t x, y, dx, dy; } Edge;
typedef struct { int64_t sec, nsec; } Stamp;

static int benchmark_clock(Stamp *value) {
#ifdef _WIN32
  LARGE_INTEGER frequency, counter;
  if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0 ||
      !QueryPerformanceCounter(&counter) || counter.QuadPart < 0) return -1;
  int64_t remainder = counter.QuadPart % frequency.QuadPart;
  if (remainder > 9223372036LL) return -1;
  value->sec = counter.QuadPart / frequency.QuadPart;
  value->nsec = remainder * 1000000000LL / frequency.QuadPart;
  return 0;
#else
  struct timespec stamp;
  int status = clock_gettime(CLOCK_ID, &stamp);
  if (!status) { value->sec = stamp.tv_sec; value->nsec = stamp.tv_nsec; }
  return status;
#endif
}

static Edge edge(int x0, int y0, int x1, int y1) {
  Edge value = {x0 * IMAGE_SIZE, y0 * IMAGE_SIZE,
                (x1 - x0) * IMAGE_SIZE, (y1 - y0) * IMAGE_SIZE};
  return value;
}

static void glyph(Edge edges[EDGES]) {
  edges[0] = edge(25, 4, 4, 60);
  edges[1] = edge(25, 4, 39, 4);
  edges[2] = edge(39, 4, 60, 60);
  edges[3] = edge(60, 60, 47, 60);
  edges[4] = edge(42, 46, 47, 60);
  edges[5] = edge(42, 46, 22, 46);
  edges[6] = edge(22, 46, 17, 60);
  edges[7] = edge(17, 60, 4, 60);
  edges[8] = edge(32, 17, 26, 35);
  edges[9] = edge(32, 17, 38, 35);
  edges[10] = edge(38, 35, 26, 35);
}

static int fill(uint8_t pixels[PIXELS], const Edge edges[EDGES], int phase) {
  int64_t shift_x = (phase % 4) * 16, shift_y = (phase / 4) * 16;
  for (int i = 0; i < PIXELS; ++i) pixels[i] = 0;
  for (int row = 0; row < SUB_SIZE; ++row) {
    int64_t sample_y = row * 16 + 8 - shift_y;
    int64_t crossings[EDGES] = {0};
    int count = 0;
    for (int i = 0; i < EDGES; ++i) {
      Edge e = edges[i];
      if (e.dy > 0 && sample_y >= e.y && sample_y < e.y + e.dy) {
        int64_t numerator = (e.x + shift_x) * e.dy +
                            (sample_y - e.y) * e.dx + 8 * e.dy - 1;
        int64_t denominator = 16 * e.dy;
        if (denominator <= 0) return 0;
        int64_t first = numerator / denominator;
        int64_t clipped = first >= SUB_SIZE ? SUB_SIZE : first > 0 ? first : 0;
        if (count < EDGES) crossings[count++] = clipped;
      }
    }
    if (count % 2) return 0;
    for (int i = 1; i < EDGES; ++i) {
      if (i < count) {
        int64_t key = crossings[i];
        int j = i - 1;
        while (j >= 0 && crossings[j] > key) {
          crossings[j + 1] = crossings[j];
          --j;
        }
        crossings[j + 1] = key;
      }
    }
    for (int pair = 0; pair < EDGES / 2; ++pair) {
      if (pair * 2 + 1 < count) {
        for (int64_t x = crossings[pair * 2]; x < crossings[pair * 2 + 1]; ++x) {
          int64_t pixel = (row / 4) * IMAGE_SIZE + x / 4;
          if (pixel >= 0 && pixel < PIXELS) {
            uint8_t previous = pixels[pixel];
            if (previous < 16) pixels[pixel] = previous + 1;
            else return 0;
          }
        }
      }
    }
  }
  return 1;
}

static int64_t digest(const uint8_t pixels[PIXELS]) {
  int64_t checksum = 0;
  for (int i = 0; i < PIXELS; ++i) {
    uint8_t coverage = pixels[i];
    if (coverage <= 16) {
      int64_t next = checksum + (int64_t)coverage * (i + 1);
      if (next <= MAX_CHECKSUM) checksum = next;
    }
  }
  return checksum;
}

int main(void) {
  Edge edges[EDGES];
  glyph(edges);
  uint8_t pixels[PIXELS];
  int64_t checksums[REPETITIONS];
  Stamp started = {0}, finished = {0};
  int start_status = benchmark_clock(&started);
  for (int repetition = 0; repetition < REPETITIONS; ++repetition) {
    if (!fill(pixels, edges, repetition % 16)) return 1;
    checksums[repetition] = digest(pixels);
  }
  int finish_status = benchmark_clock(&finished);
  puts("NIFTY_PATH_FILL_V1");
  printf("size %d\nrepeat %d\n", IMAGE_SIZE, REPETITIONS);
  printf("start_sec %lld\nstart_nsec %lld\nend_sec %lld\nend_nsec %lld\n",
         (long long)started.sec, (long long)started.nsec,
         (long long)finished.sec, (long long)finished.nsec);
  printf("clock_status %d %d\n", start_status, finish_status);
  for (int repetition = 0; repetition < REPETITIONS; ++repetition)
    printf("fill_checksum %d %lld\n", repetition, (long long)checksums[repetition]);
  for (int phase = 0; phase < 16; ++phase) {
    if (!fill(pixels, edges, phase)) return 1;
    printf("coverage %d ", phase);
    for (int i = 0; i < PIXELS; ++i) putchar('a' + pixels[i]);
    putchar('\n');
  }
  return 0;
}
