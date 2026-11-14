/* Handwritten owning DOM baseline. Bounded recursive descent and movable
 * children differ from Nifty's explicit stack and subtree copies. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <inttypes.h>
#include <time.h>
#ifndef JSON_MALLOC
#define JSON_MALLOC malloc
#endif
#ifndef JSON_REALLOC
#define JSON_REALLOC realloc
#endif
#ifndef JSON_FREE
#define JSON_FREE free
#endif

typedef enum {
  JsonNull, JsonBool, JsonNumber, JsonString, JsonArray, JsonObject
} JsonKind;
typedef struct { unsigned char *data; size_t length; } JsonText;
typedef struct JsonNode JsonNode;
typedef struct JsonPair JsonPair;
struct JsonNode {
  JsonKind kind;
  union {
    bool boolean;
    JsonText text;
    struct { JsonNode *items; size_t length, capacity; } array;
    struct { JsonPair *items; size_t length, capacity; } object;
  } as;
};
struct JsonPair { JsonText key; JsonNode value; };
typedef struct { size_t offset; const char *message; } JsonError;
typedef struct {
  const unsigned char *data;
  size_t length, position;
  JsonError *error;
} JsonParser;

#ifdef JSON_HAND_ASM
/* The assembly implementation shares the same owned-tree API and layout. */
void jsonDrop(JsonNode *node);
bool jsonParse(const unsigned char *data, size_t length, JsonNode *output,
               JsonError *error);
uint64_t jsonDigest(const JsonNode *node);
_Static_assert(sizeof(JsonNode) == 32 && offsetof(JsonNode, as) == 8,
               "Assembly requires the ARM64 node layout");
_Static_assert(sizeof(JsonPair) == 48 && offsetof(JsonPair, value) == 16,
               "Assembly requires the ARM64 object pair layout");
_Static_assert(sizeof(JsonParser) == 32 && offsetof(JsonParser, error) == 24,
               "Assembly requires the ARM64 parser layout");
#else
/* Releases all owned memory, leaving a reusable null node. */
void jsonDrop(JsonNode *node) {
  if (node->kind == JsonString || node->kind == JsonNumber) {
    JSON_FREE(node->as.text.data);
  } else if (node->kind == JsonArray) {
    for (size_t i = 0; i < node->as.array.length; ++i)
      jsonDrop(&node->as.array.items[i]);
    JSON_FREE(node->as.array.items);
  } else if (node->kind == JsonObject) {
    for (size_t i = 0; i < node->as.object.length; ++i) {
      JSON_FREE(node->as.object.items[i].key.data);
      jsonDrop(&node->as.object.items[i].value);
    }
    JSON_FREE(node->as.object.items);
  }
  memset(node, 0, sizeof(*node));
}
/* Records the first syntax or allocation failure. */
static bool jsonFail(JsonParser *p, const char *message) {
  if (p->error && !p->error->message) {
    p->error->offset = p->position;
    p->error->message = message;
  }
  return false;
}
/* Consumes only the four JSON whitespace bytes. */
static void jsonSpace(JsonParser *p) {
  while (p->position < p->length) {
    unsigned char c = p->data[p->position];
    if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
    ++p->position;
  }
}
/* Grows an allocation without invalidating it on failure. */
static bool jsonReserve(JsonParser *p, void **data, size_t *capacity,
                        size_t needed, size_t width) {
  if (needed <= *capacity) return true;
  size_t next = *capacity ? *capacity : 8;
  while (next < needed) {
    if (next > SIZE_MAX / 2) { next = needed; break; }
    next *= 2;
  }
  if (next > SIZE_MAX / width) return jsonFail(p, "Allocation overflow");
  void *grown = *data ? JSON_REALLOC(*data, next * width) :
    JSON_MALLOC(next * width);
  if (!grown) return jsonFail(p, "Out of memory");
  *data = grown;
  *capacity = next;
  return true;
}
/* Appends decoded bytes to a separately owned string allocation. */
static bool jsonBytes(JsonParser *p, JsonText *text, size_t *capacity,
                      const unsigned char *bytes, size_t count) {
  if (text->length > SIZE_MAX - count - 1)
    return jsonFail(p, "Allocation overflow");
  void *data = text->data;
  if (!jsonReserve(p, &data, capacity, text->length + count + 1, 1))
    return false;
  text->data = data;
  memcpy(text->data + text->length, bytes, count);
  text->length += count;
  text->data[text->length] = 0;
  return true;
}
/* Reads a four-digit Unicode escape. */
static bool jsonHex(JsonParser *p, uint32_t *value) {
  *value = 0;
  for (unsigned i = 0; i < 4; ++i) {
    if (p->position == p->length) return jsonFail(p, "Short Unicode escape");
    unsigned char c = p->data[p->position++];
    unsigned digit;
    if (c >= '0' && c <= '9') digit = c - '0';
    else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
    else return jsonFail(p, "Invalid Unicode escape");
    *value = (*value << 4) | digit;
  }
  return true;
}
/* Decodes escapes and validates shortest-form scalar UTF-8 sequences. */
static bool jsonString(JsonParser *p, JsonText *text) {
  size_t capacity = 0;
  ++p->position;
  while (p->position < p->length) {
    unsigned char c = p->data[p->position++];
    if (c == '"') {
      return jsonBytes(p, text, &capacity, (const unsigned char *)"", 0);
    }
    if (c < 32) return jsonFail(p, "Control byte in string");
    if (c == '\\') {
      if (p->position == p->length) return jsonFail(p, "Short escape");
      c = p->data[p->position++];
      switch (c) {
        case '"': case '\\': case '/': break;
        case 'b': c = 8; break;
        case 'f': c = 12; break;
        case 'n': c = 10; break;
        case 'r': c = 13; break;
        case 't': c = 9; break;
        case 'u': {
          uint32_t scalar;
          if (!jsonHex(p, &scalar)) return false;
          if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (p->length - p->position < 2 ||
                p->data[p->position] != '\\' ||
                p->data[p->position + 1] != 'u')
              return jsonFail(p, "Missing low surrogate");
            p->position += 2;
            uint32_t low;
            if (!jsonHex(p, &low)) return false;
            if (low < 0xdc00 || low > 0xdfff)
              return jsonFail(p, "Invalid low surrogate");
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
          } else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
            return jsonFail(p, "Unpaired low surrogate");
          }
          unsigned char bytes[4];
          size_t count;
          if (scalar < 0x80) { bytes[0] = (unsigned char)scalar; count = 1; }
          else if (scalar < 0x800) {
            bytes[0] = 0xc0 | (scalar >> 6);
            bytes[1] = 0x80 | (scalar & 63); count = 2;
          } else if (scalar < 0x10000) {
            bytes[0] = 0xe0 | (scalar >> 12);
            bytes[1] = 0x80 | ((scalar >> 6) & 63);
            bytes[2] = 0x80 | (scalar & 63); count = 3;
          } else {
            bytes[0] = 0xf0 | (scalar >> 18);
            bytes[1] = 0x80 | ((scalar >> 12) & 63);
            bytes[2] = 0x80 | ((scalar >> 6) & 63);
            bytes[3] = 0x80 | (scalar & 63); count = 4;
          }
          if (!jsonBytes(p, text, &capacity, bytes, count)) return false;
          continue;
        }
        default: return jsonFail(p, "Invalid escape");
      }
    } else if (c >= 0x80) {
      size_t start = p->position - 1;
      unsigned count;
      uint32_t scalar, minimum;
      if (c >= 0xc2 && c <= 0xdf) {
        count = 1; scalar = c & 31; minimum = 0x80;
      } else if (c >= 0xe0 && c <= 0xef) {
        count = 2; scalar = c & 15; minimum = 0x800;
      } else if (c >= 0xf0 && c <= 0xf4) {
        count = 3; scalar = c & 7; minimum = 0x10000;
      } else return jsonFail(p, "Invalid UTF-8 leading byte");
      if (p->length - p->position < count)
        return jsonFail(p, "Short UTF-8 sequence");
      for (unsigned i = 0; i < count; ++i) {
        unsigned char next = p->data[p->position++];
        if ((next & 0xc0) != 0x80)
          return jsonFail(p, "Invalid UTF-8 continuation");
        scalar = (scalar << 6) | (next & 63);
      }
      if (scalar < minimum || scalar > 0x10ffff ||
          (scalar >= 0xd800 && scalar <= 0xdfff))
        return jsonFail(p, "Invalid UTF-8 scalar");
      if (!jsonBytes(p, text, &capacity, p->data + start, count + 1))
        return false;
      continue;
    }
    if (!jsonBytes(p, text, &capacity, &c, 1)) return false;
  }
  return jsonFail(p, "Unterminated string");
}
/* Tests the ASCII decimal digit range independently of locale. */
static bool jsonDigit(JsonParser *p) {
  return p->position < p->length && p->data[p->position] >= '0' &&
    p->data[p->position] <= '9';
}
/* Preserves the complete validated numeric spelling in its own allocation. */
static bool jsonNumber(JsonParser *p, JsonNode *node) {
  size_t start = p->position;
  if (p->data[p->position] == '-') ++p->position;
  if (!jsonDigit(p)) return jsonFail(p, "Expected number digit");
  if (p->data[p->position] == '0') ++p->position;
  else while (jsonDigit(p)) ++p->position;
  if (p->position < p->length && p->data[p->position] == '.') {
    ++p->position;
    if (!jsonDigit(p)) return jsonFail(p, "Expected fraction digit");
    while (jsonDigit(p)) ++p->position;
  }
  if (p->position < p->length &&
      (p->data[p->position] == 'e' || p->data[p->position] == 'E')) {
    ++p->position;
    if (p->position < p->length &&
        (p->data[p->position] == '+' || p->data[p->position] == '-'))
      ++p->position;
    if (!jsonDigit(p)) return jsonFail(p, "Expected exponent digit");
    while (jsonDigit(p)) ++p->position;
  }
  node->kind = JsonNumber;
  size_t capacity = 0;
  return jsonBytes(p, &node->as.text, &capacity, p->data + start,
                   p->position - start);
}
/* Parses one value with at most 512 simultaneously open containers. */
static bool jsonValue(JsonParser *p, JsonNode *node, unsigned depth) {
  jsonSpace(p);
  if (p->position == p->length) return jsonFail(p, "Expected JSON value");
  unsigned char c = p->data[p->position];
  if (c == '"') {
    node->kind = JsonString;
    return jsonString(p, &node->as.text);
  }
  if (c == '-' || (c >= '0' && c <= '9')) return jsonNumber(p, node);
  if (c == '[' || c == '{') {
    if (depth == 512) return jsonFail(p, "JSON nesting depth exceeded");
    bool object = c == '{';
    node->kind = object ? JsonObject : JsonArray;
    ++p->position;
    jsonSpace(p);
    unsigned char closing = object ? '}' : ']';
    if (p->position < p->length && p->data[p->position] == closing) {
      ++p->position; return true;
    }
    for (;;) {
      JsonPair pair = {0};
      if (object) {
        if (p->position == p->length || p->data[p->position] != '"')
          return jsonFail(p, "Expected object key");
        if (!jsonString(p, &pair.key)) { JSON_FREE(pair.key.data); return false; }
        jsonSpace(p);
        if (p->position == p->length || p->data[p->position] != ':') {
          JSON_FREE(pair.key.data); return jsonFail(p, "Expected colon");
        }
        ++p->position;
      }
      if (!jsonValue(p, &pair.value, depth + 1)) {
        JSON_FREE(pair.key.data); jsonDrop(&pair.value); return false;
      }
      if (object) {
        void *items = node->as.object.items;
        if (!jsonReserve(p, &items, &node->as.object.capacity,
                         node->as.object.length + 1, sizeof(JsonPair))) {
          JSON_FREE(pair.key.data); jsonDrop(&pair.value); return false;
        }
        node->as.object.items = items;
        node->as.object.items[node->as.object.length++] = pair;
      } else {
        void *items = node->as.array.items;
        if (!jsonReserve(p, &items, &node->as.array.capacity,
                         node->as.array.length + 1, sizeof(JsonNode))) {
          jsonDrop(&pair.value); return false;
        }
        node->as.array.items = items;
        node->as.array.items[node->as.array.length++] = pair.value;
      }
      jsonSpace(p);
      if (p->position == p->length) return jsonFail(p, "Unclosed container");
      c = p->data[p->position++];
      if (c == closing) return true;
      if (c != ',') return jsonFail(p, "Expected comma or closing delimiter");
      jsonSpace(p);
    }
  }
  const char *literal;
  size_t length;
  if (c == 'n') { literal = "null"; length = 4; }
  else if (c == 't') { literal = "true"; length = 4; }
  else if (c == 'f') { literal = "false"; length = 5; }
  else return jsonFail(p, "Invalid JSON value");
  if (p->length - p->position < length ||
      memcmp(p->data + p->position, literal, length) != 0)
    return jsonFail(p, "Invalid literal");
  p->position += length;
  if (c != 'n') { node->kind = JsonBool; node->as.boolean = c == 't'; }
  return true;
}
/* Replaces an initialized output; failure leaves null with no allocations.
 * Before first use, callers must initialize output with {0}. */
bool jsonParse(const unsigned char *data, size_t length, JsonNode *output,
               JsonError *error) {
  jsonDrop(output);
  if (error) { error->offset = 0; error->message = NULL; }
  JsonParser parser = { data, length, 0, error };
  if (!data && length) return jsonFail(&parser, "Null input");
  bool ok = jsonValue(&parser, output, 0);
  if (ok) {
    jsonSpace(&parser);
    if (parser.position != length) ok = jsonFail(&parser, "Trailing input");
  }
  if (!ok) jsonDrop(output);
  return ok;
}
/* Feeds a typed checksum byte with bounded unsigned arithmetic. */
static uint64_t jsonFeed(uint64_t checksum, unsigned byte) {
  return (checksum * 257 + byte) % UINT64_C(1000000007);
}
/* Includes every string byte, embedded NUL, and its terminating delimiter. */
static uint64_t jsonDigestText(const JsonText *text, uint64_t checksum) {
  for (size_t i = 0; i < text->length; ++i)
    checksum = jsonFeed(checksum, text->data[i]);
  return jsonFeed(checksum, 0);
}
/* Visits every typed value and every ordered object pair, including duplicates. */
static uint64_t jsonVisit(const JsonNode *node, uint64_t checksum) {
  checksum = jsonFeed(checksum, (unsigned)node->kind + 1);
  switch (node->kind) {
    case JsonNull: return checksum;
    case JsonBool: return jsonFeed(checksum, node->as.boolean ? 1 : 0);
    case JsonNumber: case JsonString:
      return jsonDigestText(&node->as.text, checksum);
    case JsonArray:
      for (size_t i = 0; i < node->as.array.length; ++i)
        checksum = jsonVisit(&node->as.array.items[i], checksum);
      break;
    case JsonObject:
      for (size_t i = 0; i < node->as.object.length; ++i) {
        checksum = jsonDigestText(&node->as.object.items[i].key, checksum);
        checksum = jsonVisit(&node->as.object.items[i].value, checksum);
      }
      break;
  }
  return jsonFeed(checksum, 255);
}
/* Returns the complete typed tree checksum used by the Python oracle. */
uint64_t jsonDigest(const JsonNode *node) { return jsonVisit(node, 0); }
#endif

#ifndef JSON_STRAIGHT_NO_MAIN
#ifndef RECORDS
#define RECORDS 128
#endif
#ifndef REPETITIONS
#define REPETITIONS 10
#endif
#ifndef CLOCK_ID
#define CLOCK_ID CLOCK_MONOTONIC
#endif
#if RECORDS < 1 || RECORDS > 4096 || REPETITIONS < 1 || REPETITIONS > 1000
#error Invalid benchmark workload bounds
#endif
/* Builds the fixture outside timing and times fresh parse, consume, and drop. */
int main(void) {
  static const char record[] =
    "{\"name\":\"Nifty\\nJSON\",\"unicode\":\"\\u00e9\\uD83D\\uDE03\","
    "\"nul\":\"a\\u0000b\",\"integer\":9007199254740993,"
    "\"fraction\":-12.50e+2,\"enabled\":true,\"disabled\":false,"
    "\"nothing\":null,\"nested\":[1,\"x\",{\"k\":false},[]],\"empty\":{}}";
  size_t length = RECORDS * (sizeof(record) - 1) + RECORDS + 1;
  unsigned char *input = JSON_MALLOC(length);
  if (!input) { fputs("Input allocation failed\n", stderr); return 1; }
  size_t position = 0;
  input[position++] = '[';
  for (size_t i = 0; i < RECORDS; ++i) {
    if (i) input[position++] = ',';
    memcpy(input + position, record, sizeof(record) - 1);
    position += sizeof(record) - 1;
  }
  input[position++] = ']';
  uint64_t results[REPETITIONS], batch = 0;
  struct timespec start, end;
  if (clock_gettime(CLOCK_ID, &start)) {
    JSON_FREE(input); fputs("Start clock failed\n", stderr); return 1;
  }
  for (size_t i = 0; i < REPETITIONS; ++i) {
    JsonNode tree = {0};
    JsonError error;
    if (!jsonParse(input, length, &tree, &error)) {
      JSON_FREE(input);
      fprintf(stderr, "Parse failed at %zu: %s\n", error.offset, error.message);
      return 1;
    }
    results[i] = jsonDigest(&tree);
    jsonDrop(&tree);
  }
  if (clock_gettime(CLOCK_ID, &end)) {
    JSON_FREE(input); fputs("End clock failed\n", stderr); return 1;
  }
  JSON_FREE(input);
  printf("NIFTY_JSON_V1\nrecords %d\nrepeat %d\ninput_bytes %zu\n",
         RECORDS, REPETITIONS, length);
  printf("start_sec %" PRIdMAX "\nstart_nsec %ld\n", (intmax_t)start.tv_sec,
         start.tv_nsec);
  printf("end_sec %" PRIdMAX "\nend_nsec %ld\n", (intmax_t)end.tv_sec,
         end.tv_nsec);
  printf("clock_status 0 0\nsuccesses %d\n", REPETITIONS);
  for (size_t i = 0; i < REPETITIONS; ++i) {
    printf("parse_checksum %zu %" PRIu64 "\n", i, results[i]);
    batch += results[i];
  }
  printf("batch_checksum %" PRIu64 "\n", batch);
  return 0;
}
#endif
