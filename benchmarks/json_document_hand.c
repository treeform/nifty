/* Pooled document baseline: fixed nodes, stable IDs and one byte pool.
 * Shares the original driver's input, Unicode rules and digest protocol. */
#define JSON_STRAIGHT_NO_MAIN
#include "json_parser_straight.c"

typedef struct {
  int64_t kind;
  bool boolean;
  size_t offset, limit, nameOffset, nameLimit, after;
} JsonDocumentNode;
typedef struct {
  JsonDocumentNode *nodes;
  size_t length, capacity;
  unsigned char *bytes;
  size_t byteLength, byteCapacity;
} JsonDocument;

void jsonDocumentDrop(JsonDocument *doc) {
  JSON_FREE(doc->nodes);
  JSON_FREE(doc->bytes);
  memset(doc, 0, sizeof(*doc));
}
static bool docBytes(JsonParser *p, JsonDocument *doc,
                     const unsigned char *data, size_t count) {
  if(count > SIZE_MAX-doc->byteLength) return jsonFail(p,"Byte pool overflow");
  void *bytes=doc->bytes;
  if(!jsonReserve(p,&bytes,&doc->byteCapacity,doc->byteLength+count,1)) return false;
  doc->bytes=bytes;
  if(count) memcpy(doc->bytes+doc->byteLength,data,count);
  doc->byteLength+=count;
  return true;
}
static bool docString(JsonParser *p, JsonDocument *doc) {
  ++p->position;
  while (p->position < p->length) {
    unsigned char c = p->data[p->position++];
    if (c == '"') {
      return docBytes(p, doc, (const unsigned char *)"", 0);
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
          if (!docBytes(p, doc, bytes, count)) return false;
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
      if (!docBytes(p, doc, p->data + start, count + 1))
        return false;
      continue;
    }
    if (!docBytes(p, doc, &c, 1)) return false;
  }
  return jsonFail(p, "Unterminated string");
}

static bool docNumber(JsonParser *p, JsonDocumentNode *node) {
  size_t start=p->position;
  if(p->data[p->position]=='-') ++p->position;
  if(!jsonDigit(p)) return jsonFail(p,"Expected number digit");
  if(p->data[p->position]=='0') ++p->position;
  else while(jsonDigit(p)) ++p->position;
  if(p->position<p->length && p->data[p->position]=='.') {
    ++p->position;
    if(!jsonDigit(p)) return jsonFail(p,"Expected fraction digit");
    while(jsonDigit(p)) ++p->position;
  }
  if(p->position<p->length && (p->data[p->position]=='e'||p->data[p->position]=='E')) {
    ++p->position;
    if(p->position<p->length && (p->data[p->position]=='+'||p->data[p->position]=='-')) ++p->position;
    if(!jsonDigit(p)) return jsonFail(p,"Expected exponent digit");
    while(jsonDigit(p)) ++p->position;
  }
  node->kind=JsonNumber; node->offset=start; node->limit=p->position;
  return true;
}
static bool docValue(JsonParser *p, JsonDocument *doc, unsigned depth,
                     size_t nameOffset, size_t nameLimit) {
  jsonSpace(p);
  if(p->position==p->length) return jsonFail(p,"Expected JSON value");
  if(doc->length==SIZE_MAX) return jsonFail(p,"Node pool overflow");
  void *nodes=doc->nodes;
  if(!jsonReserve(p,&nodes,&doc->capacity,doc->length+1,sizeof(*doc->nodes))) return false;
  doc->nodes=nodes;
  size_t id=doc->length++;
  JsonDocumentNode *node=&doc->nodes[id];
  memset(node,0,sizeof(*node));
  node->nameOffset=nameOffset; node->nameLimit=nameLimit;
  unsigned char c=p->data[p->position];
  if(c=='"') {
    node->kind=JsonString; node->offset=doc->byteLength;
    if(!docString(p,doc)) return false;
    node->limit=doc->byteLength;
  } else if(c=='-' || (c>='0' && c<='9')) {
    if(!docNumber(p,node)) return false;
  } else if(c=='[' || c=='{') {
    if(depth==512) return jsonFail(p,"JSON nesting depth exceeded");
    bool object=c=='{'; unsigned char closing=object?'}':']';
    node->kind=object?JsonObject:JsonArray;
    ++p->position; jsonSpace(p);
    if(p->position<p->length && p->data[p->position]==closing) ++p->position;
    else for(;;) {
      size_t keyStart=0,keyEnd=0;
      if(object) {
        if(p->position==p->length || p->data[p->position]!='"') return jsonFail(p,"Expected object key");
        keyStart=doc->byteLength;
        if(!docString(p,doc)) return false;
        keyEnd=doc->byteLength; jsonSpace(p);
        if(p->position==p->length || p->data[p->position]!=':') return jsonFail(p,"Expected colon");
        ++p->position;
      }
      if(!docValue(p,doc,depth+1,keyStart,keyEnd)) return false;
      jsonSpace(p);
      if(p->position==p->length) return jsonFail(p,"Unclosed container");
      c=p->data[p->position++];
      if(c==closing) break;
      if(c!=',') return jsonFail(p,"Expected comma or closing delimiter");
      jsonSpace(p);
    }
  } else {
    const char *literal; size_t length;
    if(c=='n') {literal="null";length=4;}
    else if(c=='t') {literal="true";length=4;}
    else if(c=='f') {literal="false";length=5;}
    else return jsonFail(p,"Invalid JSON value");
    if(p->length-p->position<length || memcmp(p->data+p->position,literal,length)) return jsonFail(p,"Invalid literal");
    p->position+=length;
    if(c!='n') {node->kind=JsonBool;node->boolean=c=='t';}
  }
  /* Recursive calls may move the node pool: reacquire by ID. */
  doc->nodes[id].after=doc->length;
  return true;
}
bool jsonDocumentParse(const unsigned char *data,size_t length,
                        JsonDocument *doc,JsonError *error) {
  jsonDocumentDrop(doc);
  if(error) {error->offset=0;error->message=NULL;}
  JsonParser parser={data,length,0,error};
  if(!data && length) return jsonFail(&parser,"Null input");
  bool ok=docBytes(&parser,doc,data,length) && docValue(&parser,doc,0,0,0);
  if(ok) {
    jsonSpace(&parser);
    if(parser.position!=length) ok=jsonFail(&parser,"Trailing input");
  }
  if(!ok) jsonDocumentDrop(doc);
  return ok;
}
static uint64_t docDigestText(const JsonDocument *doc,size_t start,size_t end,uint64_t value) {
  for(size_t i=start;i<end;++i) value=jsonFeed(value,doc->bytes[i]);
  return jsonFeed(value,0);
}
static uint64_t docVisit(const JsonDocument *doc,size_t id,uint64_t value) {
  const JsonDocumentNode *node=&doc->nodes[id];
  value=jsonFeed(value,(unsigned)node->kind+1);
  switch(node->kind) {
    case JsonNull: return value;
    case JsonBool: return jsonFeed(value,node->boolean);
    case JsonNumber: case JsonString: return docDigestText(doc,node->offset,node->limit,value);
    case JsonArray: case JsonObject:
      for(size_t child=id+1;child<node->after;child=doc->nodes[child].after) {
        if(node->kind==JsonObject) value=docDigestText(doc,doc->nodes[child].nameOffset,doc->nodes[child].nameLimit,value);
        value=docVisit(doc,child,value);
      }
      return jsonFeed(value,255);
  }
  return value;
}
uint64_t jsonDocumentDigest(const JsonDocument *doc) { return docVisit(doc,0,0); }

#ifndef JSON_DOCUMENT_NO_MAIN
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
    JsonDocument tree = {0};
    JsonError error;
    if (!jsonDocumentParse(input, length, &tree, &error)) {
      JSON_FREE(input);
      fprintf(stderr, "Parse failed at %zu: %s\n", error.offset, error.message);
      return 1;
    }
    results[i] = jsonDocumentDigest(&tree);
    jsonDocumentDrop(&tree);
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
