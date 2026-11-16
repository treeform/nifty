## Typed heap operations included by the C backend.

proc putLines(g: var Gen, source: string) =
  ## Emit a C helper body using the current indentation.
  for line in source.strip.splitLines:
    g.put line

proc emitOwnedHelpers(g: var Gen, t: Typ) =
  ## Emits bounded-stack destruction and transactional copying for an owner.
  if not hasOwned(t) or (t.dynamic and not t.opt):
    return
  let
    key = mangle(t)
    marker = "owned:" & key
  if marker in g.emitted:
    return
  g.emitted.incl marker
  let
    drop = "ni_drop_" & key
    copy = "ni_copy_" & key
  g.put "static void " & drop & "(" & cDecl("(*s)", t) & ") {"
  g.put "  ni_frame *stack = NULL;"
  g.put "  ni_walk_" & key & "(s, &stack);"
  g.put "  ni_drain(&stack);"
  g.put "  memset(s, 0, sizeof(*s));"
  g.put "}"
  g.put "static bool " & copy & "(" & cDecl("(*s)", t) &
    ", const " & cDecl("(*d)", t) & ") {"
  g.put "  if (s == d) return true;"
  g.put "  " & cDecl("(*tmp)", t) & " = ni_realloc(NULL, sizeof(*tmp));"
  g.put "  if (tmp == NULL) return false;"
  g.put "  memset(tmp, 0, sizeof(*tmp));"
  g.put "  ni_task *tasks = NULL;"
  g.put "  bool ok = ni_clone_" & key & "(tmp, d, &tasks) && ni_clone_drain(&tasks);"
  g.put "  ni_tasks_clear(&tasks);"
  g.put "  if (ok) { " & drop & "(s); memcpy(s, tmp, sizeof(*s)); }"
  g.put "  else " & drop & "(tmp);"
  g.put "  ni_free(tmp); return ok;"
  g.put "}"

proc emitDynamicType(g: var Gen, t: Typ) =
  ## Emit a growable container and its fallible allocation operations.
  let key = mangle(t)
  if key in g.emitted:
    return
  g.emitted.incl key
  let
    n = cBase(t)
    elem = if t.kind == StringType: "uint8_t" else: cBase(t.elem)
    ownsElements = t.kind == SeqType and hasOwned(t.elem)
    child = if ownsElements: mangle(t.elem) else: ""
    drop = "ni_drop_" & key
    copy = "ni_copy_" & key
  g.put ""
  g.putLines("""
static bool $N_reserve($N *s, int64_t k) {
  if (k < 0) return false;
  if (k <= s->m_cap) return true;
  if ((uint64_t)k > (SIZE_MAX - sizeof(ni_frame)) / sizeof(*s->m_data)) return false;
  int64_t cap = s->m_cap > 0 ? s->m_cap : 8;
  while (cap < k) {
    if (cap > INT64_MAX / 2) { cap = k; break; }
    cap *= 2;
  }
  if ((uint64_t)cap > (SIZE_MAX - sizeof(ni_frame)) / sizeof(*s->m_data)) cap = k;
  void *data = ni_realloc(s->m_data, (size_t)cap * sizeof(*s->m_data) + sizeof(ni_frame));
  if (data == NULL) return false;
  memset(($E *)data + s->m_cap, 0,
    (size_t)(cap - s->m_cap) * sizeof(*s->m_data));
  s->m_data = ($E *)data;
  s->m_cap = cap;
  return true;
}
""".replace("$N", n).replace("$E", elem))
  g.put "static void " & n & "_clear(" & n & " *s) {"
  if ownsElements:
    g.put "  for (int64_t i = s->m_len; i > 0; --i)"
    g.put "    ni_drop_" & child & "(&s->m_data[i - 1]);"
  g.put "  if (s->m_len > 0)"
  g.put "    memset(s->m_data, 0, (size_t)s->m_len * sizeof(*s->m_data));"
  g.put "  s->m_len = 0;"
  g.put "}"
  g.put "static void " & drop & "(" & n & " *s) {"
  g.put "  ni_frame *stack = NULL;"
  g.put "  ni_walk_" & key & "(s, &stack); ni_drain(&stack);"
  g.put "  memset(s, 0, sizeof(*s));"
  g.put "}"
  g.put "static bool " & n & "_resize(" & n & " *s, int64_t k) {"
  g.put "  if (k < 0) return false;"
  g.put "  if (!" & n & "_reserve(s, k)) return false;"
  if ownsElements:
    g.put "  for (int64_t i = s->m_len; i > k; --i)"
    g.put "    ni_drop_" & child & "(&s->m_data[i - 1]);"
  if t.kind == SeqType and needsDefaultInit(t.elem):
    g.put "  for (int64_t i = s->m_len; i < k; ++i)"
    g.put "    ni_init_" & mangle(t.elem) & "(&s->m_data[i]);"
  else:
    g.put "  if (k > s->m_len)"
    g.put "    memset(s->m_data + s->m_len, 0,"
    g.put "      (size_t)(k - s->m_len) * sizeof(*s->m_data));"
  g.put "  s->m_len = k; return true;"
  g.put "}"
  g.put "static bool " & n & "_setLen(" & n & " *s, int64_t k) {"
  g.put "  if (k < 0 || k > s->m_cap) return false;"
  if ownsElements:
    g.put "  for (int64_t i = s->m_len; i > k; --i)"
    g.put "    ni_drop_" & child & "(&s->m_data[i - 1]);"
  if t.kind == SeqType and needsDefaultInit(t.elem):
    g.put "  for (int64_t i = s->m_len; i < k; ++i)"
    g.put "    ni_init_" & mangle(t.elem) & "(&s->m_data[i]);"
  g.put "  s->m_len = k; return true;"
  g.put "}"
  g.put "static bool " & copy & "(" & n & " *s, const " & n & " *d) {"
  g.put "  if (s == d) return true;"
  g.put "  " & n & " tmp = {0}; ni_task *tasks = NULL;"
  g.put "  bool ok = ni_clone_" & key & "(&tmp, d, &tasks) && ni_clone_drain(&tasks);"
  g.put "  ni_tasks_clear(&tasks);"
  g.put "  if (ok) { " & drop & "(s); *s = tmp; } else " & drop & "(&tmp);"
  g.put "  return ok;"
  g.put "}"
  if t.kind == SeqType:
    g.put "static bool " & n & "_copyFrom(" & n & " *s, const " &
      n & " *d) { return " & copy & "(s, d); }"
    let arg = if ownsElements: "const " & elem & " *v" else: elem & " v"
    g.put "static bool " & n & "_push(" & n & " *s, " & arg & ") {"
    g.put "  if (s->m_len == INT64_MAX) return false;"
    if ownsElements:
      let
        heapElement = typeSize(t.elem) > arenaThreshold
        tmp = if heapElement: "(*tmp)" else: "tmp"
        tmpPtr = "&" & tmp
      if heapElement:
        g.put "  " & elem & " *tmp = ni_realloc(NULL, sizeof(*tmp));"
        g.put "  if (tmp == NULL) return false;"
        g.put "  memset(tmp, 0, sizeof(*tmp));"
      else:
        g.put "  " & elem & " tmp = {0};"
      g.put "  if (!ni_copy_" & child & "(" & tmpPtr & ", v)) {"
      if heapElement:
        g.put "    ni_free(tmp);"
      g.put "    return false;"
      g.put "  }"
      g.put "  if (!" & n & "_reserve(s, s->m_len + 1)) {"
      g.put "    ni_drop_" & child & "(" & tmpPtr & ");"
      if heapElement:
        g.put "    ni_free(tmp);"
      g.put "    return false;"
      g.put "  }"
      g.put "  s->m_data[s->m_len++] = " & tmp & ";"
      if heapElement:
        g.put "  ni_free(tmp);"
      g.put "  return true;"
    else:
      g.put "  if (!" & n & "_reserve(s, s->m_len + 1)) return false;"
      g.put "  s->m_data[s->m_len++] = v; return true;"
    g.put "}"
    g.put "static bool " & n & "_add(" & n & " *s, " & arg & ") {"
    g.put "  return " & n & "_push(s, v);"
    g.put "}"
    if not ownsElements:
      g.put "static " & elem & " " & n & "_pop(" & n & " *s) {"
      g.put "  return s->m_data[--s->m_len];"
      g.put "}"
      let optional = cBase(optOf(t.elem))
      if bigRet(optOf(t.elem)):
        g.put "static void " & n & "_getInto(const " & n &
          " *s, int64_t i, " & optional & " *out) {"
        g.put "  if (i >= 0 && i < s->m_len) {"
        if t.elem.opt:
          g.put "    memmove(out, &s->m_data[i], sizeof(*out));"
        else:
          g.put "    memmove(&out->m_val, &s->m_data[i],"
          g.put "      sizeof(out->m_val));"
          g.put "    out->m_ok = true;"
        g.put "  } else {"
        g.put "    memset(out, 0, sizeof(*out));"
        g.put "  }"
      else:
        g.put "static " & optional & " " & n & "_get(const " & n &
          " *s, int64_t i) {"
        g.put "  " & optional & " out = {0};"
        g.put "  if (i >= 0 && i < s->m_len) {"
        if t.elem.opt:
          g.put "    out = s->m_data[i];"
        else:
          g.put "    out.m_val = s->m_data[i]; out.m_ok = true;"
        g.put "  }"
        g.put "  return out;"
      g.put "}"
    return
  g.putLines("""
static bool $N_adds($N *s, const uint8_t *d, int64_t k) {
  if (k < 0 || k > INT64_MAX - s->m_len) return false;
  if (!$N_reserve(s, s->m_len + k)) return false;
  if (k > 0) memcpy(s->m_data + s->m_len, d, (size_t)k);
  s->m_len += k; return true;
}
static bool $N_addByte($N *s, int64_t b) {
  uint8_t value = (uint8_t)b;
  return $N_adds(s, &value, 1);
}
static bool $N_addNum($N *s, int64_t v) {
  char text[24];
  int k = snprintf(text, sizeof text, "%lld", (long long)v);
  if (k < 0 || k >= (int)sizeof text) return false;
  return $N_adds(s, (const uint8_t *)text, k);
}
static bool $N_copyFrom($N *s, const uint8_t *d, int64_t k) {
  if (k < 0) return false;
  $N tmp = {0};
  if (!$N_adds(&tmp, d, k)) return false;
  $DROP(s); *s = tmp; return true;
}
static bool $N_copyRange($N *s, const uint8_t *d,
    int64_t dlen, int64_t lo, int64_t hi) {
  if (lo < 0) lo = 0;
  if (lo > dlen) lo = dlen;
  if (hi < lo) hi = lo;
  if (hi > dlen) hi = dlen;
  return $N_copyFrom(s, hi > lo ? d + lo : d, hi - lo);
}
static bool $N_startsWith(const $N *s, const uint8_t *d, int64_t k) {
  if (k < 0 || k > s->m_len) return false;
  return k == 0 || memcmp(s->m_data, d, (size_t)k) == 0;
}
static bool $N_endsWith(const $N *s, const uint8_t *d, int64_t k) {
  if (k < 0 || k > s->m_len) return false;
  return k == 0 || memcmp(s->m_data + s->m_len - k, d, (size_t)k) == 0;
}
static int64_t $N_findRaw(const $N *s, const uint8_t *d, int64_t k) {
  if (k == 0) return 0;
  if (k < 0 || k > s->m_len) return -1;
  for (int64_t i = 0; i <= s->m_len - k; ++i)
    if (memcmp(s->m_data + i, d, (size_t)k) == 0) return i;
  return -1;
}
static bool $N_contains(const $N *s, const uint8_t *d, int64_t k) {
  return $N_findRaw(s, d, k) >= 0;
}
static int64_t $N_findByteRaw(const $N *s, int64_t b) {
  for (int64_t i = 0; i < s->m_len; ++i)
    if (s->m_data[i] == (uint8_t)b) return i;
  return -1;
}
static bool $N_toIntRaw(const $N *s, int64_t *out) {
  if (s->m_len == 0) return false;
  int64_t i = 0;
  bool negative = s->m_data[0] == (uint8_t)'-';
  if (negative) ++i;
  if (i == s->m_len) return false;
  uint64_t value = 0;
  uint64_t limit = (uint64_t)INT64_MAX + (negative ? 1U : 0U);
  for (; i < s->m_len; ++i) {
    uint8_t byte = s->m_data[i];
    if (byte < '0' || byte > '9') return false;
    uint64_t digit = byte - '0';
    if (value > (limit - digit) / 10) return false;
    value = value * 10 + digit;
  }
  *out = negative ?
    (value == (uint64_t)INT64_MAX + 1U ? INT64_MIN : -(int64_t)value) :
    (int64_t)value;
  return true;
}
static NS_pi $N_find(const $N *s, const uint8_t *d, int64_t k) {
  int64_t index = $N_findRaw(s, d, k);
  NS_pi out = {0};
  if (index >= 0) { out.m_val = index; out.m_ok = true; }
  return out;
}
static NS_pi $N_findByte(const $N *s, int64_t b) {
  int64_t index = $N_findByteRaw(s, b);
  NS_pi out = {0};
  if (index >= 0) { out.m_val = index; out.m_ok = true; }
  return out;
}
static NS_pi $N_toInt(const $N *s) {
  NS_pi out = {0};
  out.m_ok = $N_toIntRaw(s, &out.m_val);
  return out;
}
static NS_pi $N_get(const $N *s, int64_t i) {
  NS_pi out = {0};
  if (i >= 0 && i < s->m_len) {
    out.m_val = s->m_data[i]; out.m_ok = true;
  }
  return out;
}
""".replace("$N", n).replace("$DROP", drop))

proc emitWalkers(g: var Gen) =
  ## Uses allocation tail frames to release arbitrary depth without allocating.
  let owned = g.pendingOwners & g.pendingDynamics
  if owned.len == 0:
    return
  g.put "typedef struct ni_frame { struct ni_frame *next; void *owner; int64_t kind; } ni_frame;"
  for t in owned:
    g.put "static void ni_walk_" & mangle(t) & "(" & cDecl("(*s)", t) & ", ni_frame **stack);"
  for index, t in owned:
    g.put "static void ni_walk_" & mangle(t) & "(" & cDecl("(*s)", t) & ", ni_frame **stack) {"
    if t.opt:
      g.put "  if (s->m_ok) ni_walk_" & mangle(deOpt(t)) & "(&s->m_val, stack);"
    else:
      case t.kind
      of UnionType:
        g.put "  switch (s->m_tag) {"
        for member in t.members:
          if hasOwned(member):
            g.put "  case " & $member.typeId & "ULL: ni_walk_" & mangle(member) &
              "(&s->m_payload.m_" & member.name & ", stack); break;"
        g.put "  default: break; }"
      of ObjectType:
        for field in t.fields:
          if hasOwned(field.typ):
            g.put "  ni_walk_" & mangle(field.typ) & "(&s->m_" & field.name & ", stack);"
      of ArrayType:
        g.put "  for (int64_t i = 0; i < " & $t.len & "LL; ++i)"
        g.put "    ni_walk_" & mangle(t.elem) & "(&(*s)[i], stack);"
      of SeqType:
        if t.dynamic:
          if hasOwned(t.elem):
            g.put "  if (s->m_data != NULL) {"
            g.put "    ni_frame *frame = (ni_frame *)(s->m_data + s->m_cap);"
            g.put "    *frame = (ni_frame){*stack, s, " & $index & "}; *stack = frame;"
            g.put "  }"
          else:
            g.put "  ni_free(s->m_data);"
        elif hasOwned(t.elem):
          g.put "  for (int64_t i = 0; i < s->m_len; ++i)"
          g.put "    ni_walk_" & mangle(t.elem) & "(&s->m_data[i], stack);"
      of StringType:
        if t.dynamic:
          g.put "  ni_free(s->m_data);"
      else:
        discard
    g.put "}"
  g.put "static void ni_drain(ni_frame **stack) {"
  g.put "  while (*stack != NULL) {"
  g.put "    ni_frame *frame = *stack;"
  g.put "    switch (frame->kind) {"
  for index, t in owned:
    if t.dynamic and t.kind == SeqType and hasOwned(t.elem):
      g.put "    case " & $index & ": {"
      g.put "      " & cBase(t) & " *s = frame->owner;"
      g.put "      if (s->m_len > 0) {"
      g.put "        --s->m_len; ni_walk_" & mangle(t.elem) & "(&s->m_data[s->m_len], stack);"
      g.put "      } else {"
      g.put "        *stack = frame->next; ni_free(s->m_data);"
      g.put "      } break; }"
  g.put "    default: abort();"
  g.put "    }"
  g.put "  }"
  g.put "}"
  g.put "typedef struct ni_task { struct ni_task *next; void *dst; const void *src; int64_t kind; } ni_task;"
  g.put "static void ni_tasks_clear(ni_task **tasks) { while (*tasks) { ni_task *t = *tasks; *tasks = t->next; ni_free(t); } }"
  for t in owned:
    g.put "static bool ni_clone_" & mangle(t) & "(" & cDecl("(*s)", t) & ", const " & cDecl("(*d)", t) & ", ni_task **tasks);"
  for index, t in owned:
    g.put "static bool ni_clone_" & mangle(t) & "(" & cDecl("(*s)", t) & ", const " & cDecl("(*d)", t) & ", ni_task **tasks) {"
    if t.opt:
      g.put "  s->m_ok = d->m_ok;"
      g.put "  if (d->m_ok && !ni_clone_" & mangle(deOpt(t)) & "(&s->m_val, &d->m_val, tasks)) return false;"
    else:
      case t.kind
      of ObjectType:
        for field in t.fields:
          let path = "m_" & field.name
          if hasOwned(field.typ):
            g.put "  if (!ni_clone_" & mangle(field.typ) & "(&s->" & path & ", &d->" & path & ", tasks)) return false;"
          else:
            g.put "  memcpy(&s->" & path & ", &d->" & path & ", sizeof(s->" & path & "));"
      of UnionType:
        g.put "  s->m_tag = d->m_tag; switch (d->m_tag) {"
        for member in t.members:
          let path = "m_payload.m_" & member.name
          g.put "  case " & $member.typeId & "ULL:"
          if hasOwned(member):
            g.put "    if (!ni_clone_" & mangle(member) & "(&s->" & path & ", &d->" & path & ", tasks)) return false;"
          else:
            g.put "    memcpy(&s->" & path & ", &d->" & path & ", sizeof(s->" & path & "));"
          g.put "    break;"
        g.put "  default: break; }"
      of ArrayType:
        g.put "  for (int64_t i = 0; i < " & $t.len & "LL; ++i)"
        g.put "    if (!ni_clone_" & mangle(t.elem) & "(&(*s)[i], &(*d)[i], tasks)) return false;"
      of SeqType, StringType:
        if t.dynamic:
          g.put "  if (d->m_len > 0) {"
          g.put "    if ((uint64_t)d->m_len > (SIZE_MAX - sizeof(ni_frame)) / sizeof(*s->m_data)) return false;"
          g.put "    s->m_data = ni_realloc(NULL, (size_t)d->m_len * sizeof(*s->m_data) + sizeof(ni_frame));"
          g.put "    if (s->m_data == NULL) return false;"
          g.put "    s->m_cap = s->m_len = d->m_len;"
          g.put "    memset(s->m_data, 0, (size_t)s->m_len * sizeof(*s->m_data));"
        else:
          g.put "  { s->m_len = d->m_len;"
        if t.kind == SeqType and hasOwned(t.elem):
          g.put "    ni_task *task = ni_realloc(NULL, sizeof(*task));"
          g.put "    if (task == NULL) return false;"
          g.put "    *task = (ni_task){*tasks, s, d, " & $index & "}; *tasks = task;"
        else:
          g.put "    if (d->m_len > 0) memcpy(s->m_data, d->m_data, (size_t)d->m_len * sizeof(*s->m_data));"
        g.put "  }"
      else:
        discard
    g.put "  return true; }"
  g.put "static bool ni_clone_drain(ni_task **tasks) {"
  g.put "  while (*tasks) { ni_task *task = *tasks; *tasks = task->next;"
  g.put "    bool ok = true; switch (task->kind) {"
  for index, t in owned:
    if t.kind == SeqType and hasOwned(t.elem):
      g.put "    case " & $index & ": {"
      g.put "      " & cBase(t) & " *s = task->dst; const " & cBase(t) & " *d = task->src;"
      g.put "      for (int64_t i = 0; ok && i < d->m_len; ++i)"
      g.put "        ok = ni_clone_" & mangle(t.elem) & "(&s->m_data[i], &d->m_data[i], tasks);"
      g.put "      break; }"
  g.put "    default: abort(); } ni_free(task); if (!ok) return false;"
  g.put "  } return true; }"
