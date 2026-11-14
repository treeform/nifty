/* Ported from Supersnappy (MIT); see ../lib/SNAPPY_LICENSE. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <inttypes.h>

typedef struct { uint8_t *data; size_t len, cap; } SnappyBuffer;
#ifndef SNAPPY_REALLOC
#define SNAPPY_REALLOC realloc
#endif
#ifdef SNAPPY_HAND_ASM
extern int snappyCompress(const uint8_t *, size_t, SnappyBuffer *);
extern int snappyUncompress(const uint8_t *, size_t, SnappyBuffer *, size_t);
#else
/* Grows retained storage without changing it on allocation failure. */
static int reserve(SnappyBuffer *b, size_t n) {
  if (n <= b->cap) return 0;
  void *p = SNAPPY_REALLOC(b->data, n);
  if (!p) return 2;
  b->data = p;
  b->cap = n;
  return 0;
}
/* Loads an unaligned little-endian word with no aliasing violation. */
static uint32_t word(const uint8_t *p) {
  uint32_t v;
  memcpy(&v, p, 4);
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  v = __builtin_bswap32(v);
#endif
  return v;
}
/* Finds equal bytes using only fully initialized, in-bounds words. */
static size_t match(const uint8_t *a, const uint8_t *b, size_t n) {
  size_t i = 0;
  while (n - i >= 8) {
    uint64_t x, y;
    memcpy(&x, a + i, 8);
    memcpy(&y, b + i, 8);
    if (x != y) {
#if !defined(__BYTE_ORDER__) || __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
      return i + (size_t)__builtin_ctzll(x ^ y) / 8;
#else
      break;
#endif
    }
    i += 8;
  }
  while (i < n && a[i] == b[i]) ++i;
  return i;
}
/* Emits a literal, including the original guarded sixteen-byte fast path. */
static uint8_t *literal(uint8_t *o, const uint8_t *p, size_t n,
                        size_t available) {
  size_t v = n - 1;
  if (v < 60) {
    *o++ = (uint8_t)(v << 2);
    if (n <= 16 && available >= 16) {
      memcpy(o, p, 16);
      return o + n;
    }
  } else {
    uint8_t *tag = o++;
    unsigned count = 0;
    do { *o++ = (uint8_t)v; v >>= 8; ++count; } while (v);
    *tag = (uint8_t)((59 + count) << 2);
  }
  memcpy(o, p, n);
  return o + n;
}
/* Emits one compact copy tag. */
static uint8_t *copyPart(uint8_t *o, size_t offset, size_t n) {
  if (n < 12 && offset < 2048) {
    *o++ = (uint8_t)(1 + ((n - 4) << 2) + ((offset >> 8) << 5));
    *o++ = (uint8_t)offset;
  } else {
    *o++ = (uint8_t)(2 + ((n - 1) << 2));
    *o++ = (uint8_t)offset;
    *o++ = (uint8_t)(offset >> 8);
  }
  return o;
}
/* Splits long matches with the original sixty-four/sixty-byte rules. */
static uint8_t *emitCopy(uint8_t *o, size_t offset, size_t n) {
  while (n >= 68) { o = copyPart(o, offset, 64); n -= 64; }
  if (n > 64) { o = copyPart(o, offset, 60); n -= 60; }
  return copyPart(o, offset, n);
}
/* Compresses one independent fragment with adaptive hashing and skipping. */
static uint8_t *fragment(uint8_t *o, const uint8_t *p, size_t n,
                         uint16_t *table) {
  size_t tableSize = 256, ip = 0, nextEmit = 0;
  unsigned shift = 24;
  while (tableSize < 16384 && tableSize < n) {
    tableSize *= 2; --shift;
  }
  memset(table, 0, tableSize * sizeof(*table));
#define HASH(v) ((uint32_t)((v) * UINT32_C(506832829)) >> shift)
  if (n >= 15) {
    size_t limit = n - 15;
    ip = 1;
    uint32_t nextHash = HASH(word(p + ip));
    for (;;) {
      size_t skip = 32, nextIp = ip, candidate;
      for (;;) {
        ip = nextIp;
        uint32_t h = nextHash;
        nextIp = ip + (skip++ >> 5);
        if (nextIp > limit) goto remainder;
        nextHash = HASH(word(p + nextIp));
        candidate = table[h];
        table[h] = (uint16_t)ip;
        if (word(p + ip) == word(p + candidate)) break;
      }
      o = literal(o, p + nextEmit, ip - nextEmit, n - nextEmit);
      for (;;) {
        size_t matched = 4 + match(p + candidate + 4, p + ip + 4,
                                   n - ip - 4);
        o = emitCopy(o, ip - candidate, matched);
        ip += matched;
        nextEmit = ip;
        if (ip >= limit) goto remainder;
        uint32_t previous = HASH(word(p + ip - 1));
        uint32_t current = HASH(word(p + ip));
        table[previous] = (uint16_t)(ip - 1);
        candidate = table[current];
        table[current] = (uint16_t)ip;
        if (word(p + ip) != word(p + candidate)) break;
      }
      nextHash = HASH(word(p + ip + 1));
      ++ip;
    }
  }
remainder:
  if (nextEmit < n)
    o = literal(o, p + nextEmit, n - nextEmit, n - nextEmit);
#undef HASH
  return o;
}
/* Compresses raw Snappy and clears the logical output on every failure. */
int snappyCompress(const uint8_t *input, size_t length, SnappyBuffer *output) {
  output->len = 0;
  if (length > UINT32_MAX || length > SIZE_MAX - 32 - length / 6)
    return 3;
  int error = reserve(output, 32 + length + length / 6);
  if (error) return error;
  uint8_t *o = output->data;
  size_t v = length;
  while (v >= 128) { *o++ = (uint8_t)(v | 128); v >>= 7; }
  *o++ = (uint8_t)v;
  uint16_t table[16384];
  for (size_t ip = 0; ip < length;) {
    size_t n = length - ip;
    if (n > 65536) n = 65536;
    o = fragment(o, input + ip, n, table);
    ip += n;
  }
  output->len = (size_t)(o - output->data);
  return 0;
}
/* Decodes all raw tags with strict lengths, offsets, and trailing checks. */
int snappyUncompress(const uint8_t *input, size_t length,
                     SnappyBuffer *output, size_t maxOutput) {
  output->len = 0;
  size_t ip = 0, op = 0;
  uint32_t expected = 0;
  for (unsigned i = 0;; ++i) {
    if (ip == length) return 1;
    unsigned byte = input[ip++];
    if (i == 4 && byte > 15) return 1;
    expected |= (uint32_t)(byte & 127) << (7 * i);
    if (byte < 128) break;
    if (i == 4) return 1;
  }
  if ((uint64_t)expected > maxOutput) return 3;
  int error = reserve(output, expected);
  if (error) return error;
  while (ip < length) {
    unsigned tag = input[ip++], kind = tag & 3;
    uint64_t n;
    uint32_t offset = 0;
    if (!kind) {
      n = (tag >> 2) + 1;
      if (n >= 61) {
        unsigned count = (unsigned)n - 60;
        if (length - ip < count) return 1;
        uint32_t v = 0;
        for (unsigned j = 0; j < count; ++j)
          v |= (uint32_t)input[ip++] << (8 * j);
        n = (uint64_t)v + 1;
      }
    } else {
      unsigned count = kind == 1 ? 1 : kind == 2 ? 2 : 4;
      n = kind == 1 ? ((tag >> 2) & 7) + 4 : (tag >> 2) + 1;
      if (length - ip < count) return 1;
      for (unsigned j = 0; j < count; ++j)
        offset |= (uint32_t)input[ip++] << (8 * j);
      if (kind == 1) offset += (tag >> 5) << 8;
      if (!offset || offset > op) return 1;
    }
    if (n > (size_t)expected - op) return 1;
    if (!kind) {
      if (n > length - ip) return 1;
      memcpy(output->data + op, input + ip, (size_t)n);
      ip += (size_t)n;
    } else {
      /* Seed short distances, then double initialized spans without overlap. */
      size_t done = 0, count = (size_t)n;
      if (offset == 1) {
        memset(output->data + op, output->data[op - 1], count);
      } else {
        size_t seed = count < offset ? count : offset;
        memcpy(output->data + op, output->data + op - offset, seed);
        done = seed;
        while (done < count) {
          size_t chunk = count - done;
          if (chunk > done) chunk = done;
          memcpy(output->data + op + done, output->data + op, chunk);
          done += chunk;
        }
      }
    }
    op += (size_t)n;
  }
  if (op != expected) return 1;
  output->len = op;
  return 0;
}
#endif

#ifndef SNAPPY_NO_MAIN
#ifndef SNAPPY_SIZE
#define SNAPPY_SIZE 262144
#endif
#ifndef SNAPPY_REPETITIONS
#define SNAPPY_REPETITIONS 10
#endif
#ifndef SNAPPY_CLOCK_ID
#define SNAPPY_CLOCK_ID CLOCK_MONOTONIC
#endif
/* Hashes every byte outside timed intervals. */
static uint64_t digest(const uint8_t *p, size_t n) {
  uint64_t v = 0;
  for (size_t i = 0; i < n; ++i) v = (v * 257 + p[i]) % 1000000007;
  return v;
}
/* Runs one fixture with retained codec buffers and full payload comparison. */
static int run(int kind) {
  const size_t size = SNAPPY_SIZE;
  uint8_t *input = malloc(size ? size : 1);
  SnappyBuffer compressed = {0}, decoded = {0};
  uint64_t state = 1;
  static const char text[] = "The quick brown fox jumps over the lazy dog.\n";
  if (!input) { puts("setup_error"); return 1; }
  for (size_t i = 0; i < size; ++i) {
    unsigned byte;
    if (!kind) byte = (unsigned char)text[i % (sizeof(text) - 1)];
    else if (kind == 1) {
      byte = 32 + (unsigned)((i / 97 + i % 13) % 95);
      if (i % 97 < 70) byte = 65 + (unsigned)(i % 7);
    } else {
      state = (state * 48271) % 2147483647;
      byte = (unsigned)(state % 256);
    }
    input[i] = (uint8_t)byte;
  }
  int result = 1;
  if (snappyCompress(input, size, &compressed)) {
    puts("compress_error"); goto cleanup;
  }
  if (snappyUncompress(compressed.data, compressed.len, &decoded, size)) {
    puts("decode_error"); goto cleanup;
  }
  if (decoded.len != size || (size && memcmp(input, decoded.data, size))) {
    puts("mismatch"); goto cleanup;
  }
  printf("NIFTY_SNAPPY_V1\nkind %d\nsize %zu\nrepeat %d\ncompressed_hex ",
         kind, size, SNAPPY_REPETITIONS);
  for (size_t i = 0; i < compressed.len; ++i) printf("%02x", compressed.data[i]);
  putchar('\n');
  for (int i = 0; i < SNAPPY_REPETITIONS; ++i) {
    struct timespec cs = {0}, ce = {0}, ds = {0}, de = {0};
    int ca = clock_gettime(SNAPPY_CLOCK_ID, &cs);
    int cok = snappyCompress(input, size, &compressed);
    int cb = clock_gettime(SNAPPY_CLOCK_ID, &ce);
    int da = clock_gettime(SNAPPY_CLOCK_ID, &ds);
    int dok = snappyUncompress(compressed.data, compressed.len, &decoded, size);
    int db = clock_gettime(SNAPPY_CLOCK_ID, &de);
    if (cok || dok || decoded.len != size ||
        (size && memcmp(input, decoded.data, size))) {
      puts("roundtrip_error"); goto cleanup;
    }
    printf("iteration %d %lld %ld %lld %ld %lld %ld %lld %ld "
           "%d %d %d %d %zu %" PRIu64 " %" PRIu64 "\n",
           i, (long long)cs.tv_sec, cs.tv_nsec, (long long)ce.tv_sec,
           ce.tv_nsec, (long long)ds.tv_sec, ds.tv_nsec,
           (long long)de.tv_sec, de.tv_nsec, ca, cb, da, db, compressed.len,
           digest(compressed.data, compressed.len), digest(decoded.data, size));
  }
  result = 0;
cleanup:
  free(input); free(compressed.data); free(decoded.data);
  return result;
}
/* Runs the three protocol fixtures. */
int main(void) {
  for (int kind = 0; kind < 3; ++kind) if (run(kind)) return 1;
  return 0;
}
#endif
