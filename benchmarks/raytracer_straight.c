/* Float64 standalone port of the handwritten Nimkey C raytracer.
 * Distributed under the accompanying benchmarks/LICENSE (MIT).
 * Copyright (c) 2021 Andre von Houck and Edin Omeragic.
 * Keep operation order and rounding; compile without fast-math or contraction.
 */
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <inttypes.h>

typedef struct { double x, y, z; } Vec3;
typedef struct { Vec3 forward, right, up, pos; } Camera;
typedef struct { Vec3 start, dir; } Ray;
typedef struct {
  int64_t kind, surface;
  Vec3 center;
  double radius2;
  Vec3 normal;
  double offset;
} Thing;
typedef struct { int64_t thing; double dist; } Intersection;
typedef struct { Vec3 pos, color; } Light;
typedef struct {
  Vec3 diffuse, specular;
  double reflect, roughness;
} Properties;

static const Vec3 White = {1.0, 1.0, 1.0};
static const Vec3 Grey = {0.5, 0.5, 0.5};
static const Vec3 Black = {0.0, 0.0, 0.0};
static const Thing things[] = {
  {.kind=0, .surface=0, .normal={0.0, 1.0, 0.0}},
  {.kind=1, .surface=1, .center={0.0, 1.0, -0.25}, .radius2=1.0},
  {.kind=1, .surface=1, .center={-1.0, 0.5, 1.5}, .radius2=0.25}
};
static const Light lights[] = {
  {{-2.0, 2.5, 0.0}, {0.49, 0.07, 0.07}},
  {{1.5, 2.5, 1.5}, {0.07, 0.07, 0.49}},
  {{1.5, 2.5, -1.5}, {0.07, 0.49, 0.071}},
  {{0.0, 3.5, 0.0}, {0.21, 0.21, 0.35}}
};

/* Constructs a vector with the same scalar component order. */
Vec3 vector(double x, double y, double z) { return (Vec3){x, y, z}; }
/* Adds vector components. */
Vec3 add(Vec3 a, Vec3 b) {
  return vector(a.x + b.x, a.y + b.y, a.z + b.z);
}
/* Subtracts vector components. */
Vec3 subtract(Vec3 a, Vec3 b) {
  return vector(a.x - b.x, a.y - b.y, a.z - b.z);
}
/* Scales vector components. */
Vec3 scale(Vec3 a, double amount) {
  return vector(a.x * amount, a.y * amount, a.z * amount);
}
/* Multiplies color components. */
Vec3 multiply(Vec3 a, Vec3 b) {
  return vector(a.x * b.x, a.y * b.y, a.z * b.z);
}
/* Preserves the source's left-associated scalar dot product. */
double dot(Vec3 a, Vec3 b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
/* Computes the cross product without contraction. */
Vec3 cross(Vec3 a, Vec3 b) {
  return vector(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
    a.x * b.y - a.y * b.x);
}
/* Computes a binary64 vector length. */
double magnitude(Vec3 a) { return sqrt(dot(a, a)); }
/* Uses three divisions, preserving the source's rounding. */
Vec3 normalize(Vec3 a) {
  const double length = magnitude(a);
  return vector(a.x / length, a.y / length, a.z / length);
}
/* Builds the camera basis from the same scene coordinates. */
Camera newCamera(Vec3 pos, Vec3 lookAt) {
  const Vec3 forward = normalize(subtract(lookAt, pos));
  const Vec3 right = cross(forward, vector(0.0, -1.0, 0.0));
  const Vec3 up = cross(forward, right);
  return (Camera){forward, scale(normalize(right), 1.5),
    scale(normalize(up), 1.5), pos};
}
/* Selects the normal of a sphere or the checkerboard plane. */
Vec3 getNormal(int64_t thing, Vec3 pos) {
  const Thing obj = things[thing];
  if (obj.kind == 1) return normalize(subtract(pos, obj.center));
  return obj.normal;
}
/* Matches every branch and arithmetic operation in the Nimkey intersection. */
Intersection objectIntersect(int64_t thing, Ray ray) {
  const Thing obj = things[thing];
  if (obj.kind == 1) {
    const Vec3 eo = subtract(obj.center, ray.start);
    const double projection = dot(eo, ray.dir);
    if (projection >= 0.0) {
      double distance = 0.0;
      const double discriminant = obj.radius2 -
        (dot(eo, eo) - projection * projection);
      if (discriminant >= 0.0) distance = projection - sqrt(discriminant);
      if (distance != 0.0) return (Intersection){thing, distance};
    }
  } else {
    const double denominator = dot(obj.normal, ray.dir);
    if (denominator < 0.0) {
      return (Intersection){thing,
        (dot(obj.normal, ray.start) + obj.offset) / -denominator};
    }
  }
  return (Intersection){-1, 0.0};
}
/* Selects material properties with the same signed integer remainder. */
Properties getProperties(int64_t thing, Vec3 pos) {
  if (things[thing].surface == 1)
    return (Properties){White, Grey, 0.7, 250.0};
  const int64_t value = (int64_t)(floor(pos.z) + floor(pos.x));
  if (value % 2 != 0) return (Properties){White, White, 0.1, 150.0};
  return (Properties){Black, White, 0.7, 150.0};
}
/* Retains the nearest hit in original scene order. */
Intersection intersections(Ray ray) {
  double closest = 1000000.0;
  Intersection nearest = {-1, 0.0};
  for (int64_t i = 0; i < 3; ++i) {
    const Intersection hit = objectIntersect(i, ray);
    if (hit.thing != -1 && hit.dist < closest) {
      nearest = hit;
      closest = hit.dist;
    }
  }
  return nearest;
}
/* Declares the mutually recursive shading function. */
Vec3 shade(Ray ray, Intersection hit, int64_t depth);
/* Traces primary and reflected rays through the same five reflection levels. */
Vec3 traceRay(Ray ray, int64_t depth) {
  const Intersection hit = intersections(ray);
  if (hit.thing != -1) return shade(ray, hit, depth);
  return Black;
}
/* Accumulates diffuse and specular light in source evaluation order. */
Vec3 getNaturalColor(int64_t thing, Vec3 pos, Vec3 normal, Vec3 reflectDir) {
  Vec3 color = Black;
  const Vec3 reflectNorm = normalize(reflectDir);
  const Properties properties = getProperties(thing, pos);
  for (int64_t i = 0; i < 4; ++i) {
    const Light light = lights[i];
    const Vec3 lightDist = subtract(light.pos, pos);
    const Vec3 lightVec = normalize(lightDist);
    const double lightLength = magnitude(lightDist);
    const Ray shadowRay = {pos, lightVec};
    const Intersection shadowHit = intersections(shadowRay);
    const int inShadow = shadowHit.thing != -1 && shadowHit.dist <= lightLength;
    if (!inShadow) {
      const double illumination = dot(lightVec, normal);
      const double specular = dot(lightVec, reflectNorm);
      Vec3 lightColor = Black, specularColor = Black;
      if (illumination > 0.0) lightColor = scale(light.color, illumination);
      if (specular > 0.0)
        specularColor = scale(light.color, pow(specular, properties.roughness));
      lightColor = multiply(lightColor, properties.diffuse);
      specularColor = multiply(specularColor, properties.specular);
      color = add(add(color, lightColor), specularColor);
    }
  }
  return color;
}
/* Combines natural lighting and the original recursive reflection. */
Vec3 shade(Ray ray, Intersection hit, int64_t depth) {
  const Vec3 direction = ray.dir;
  const Vec3 pos = add(scale(direction, hit.dist), ray.start);
  const Vec3 normal = getNormal(hit.thing, pos);
  const Vec3 reflectDir = subtract(direction,
    scale(scale(normal, dot(normal, direction)), 2.0));
  const Vec3 natural = add(Black,
    getNaturalColor(hit.thing, pos, normal, reflectDir));
  Vec3 reflected = Grey;
  if (depth < 5) {
    const Ray reflectedRay = {pos, reflectDir};
    const Vec3 color = traceRay(reflectedRay, depth + 1);
    const Properties properties = getProperties(hit.thing, pos);
    reflected = scale(color, properties.reflect);
  }
  return add(natural, reflected);
}
/* Matches camera projection without reciprocal or reassociation shortcuts. */
Vec3 getPoint(int64_t x, int64_t y, Camera camera, int64_t imageSize) {
  const double width = (double)imageSize, xf = (double)x, yf = (double)y;
  const double recenterX = (xf - width / 2.0) / 2.0 / width;
  const double recenterY = -(yf - width / 2.0) / 2.0 / width;
  const Vec3 horizontal = scale(camera.right, recenterX);
  const Vec3 vertical = scale(camera.up, recenterY);
  return normalize(add(camera.forward, add(horizontal, vertical)));
}
/* Quantizes and wraps exactly as the benchmark source does. */
int64_t channel(double value) { return (int64_t)round(value * 255.0) % 256; }
#ifndef IMAGE_SIZE
#define IMAGE_SIZE 64
#endif
#ifndef REPETITIONS
#define REPETITIONS 1
#endif
#ifndef CLOCK_ID
#define CLOCK_ID CLOCK_MONOTONIC
#endif
#ifndef EMIT_PIXELS
#define EMIT_PIXELS 1
#endif
#if IMAGE_SIZE < 1 || REPETITIONS < 1
#error "IMAGE_SIZE and REPETITIONS must be positive."
#endif

/* Writes one full RGB frame without formatting in the measured work. */
void render(uint8_t *pixels, Camera camera) {
  for (int64_t y = 0; y < IMAGE_SIZE; ++y) {
    for (int64_t x = 0; x < IMAGE_SIZE; ++x) {
      const Ray ray = {camera.pos, getPoint(x, y, camera, IMAGE_SIZE)};
      const Vec3 color = traceRay(ray, 0);
      const size_t offset = ((size_t)y * IMAGE_SIZE + x) * 3;
      pixels[offset] = (uint8_t)channel(color.x);
      pixels[offset + 1] = (uint8_t)channel(color.y);
      pixels[offset + 2] = (uint8_t)channel(color.z);
    }
  }
}

/* Makes each completed frame observable without volatile pixel accesses. */
static volatile uint64_t checksumSink;

/* Times rendering plus RGB sums, with setup and printing outside the timer. */
int main(void) {
  const size_t channelCount = (size_t)IMAGE_SIZE * IMAGE_SIZE * 3;
  uint8_t *pixels = malloc(channelCount);
  if (pixels == NULL) return 1;
  const Camera camera = newCamera(vector(3.0, 2.0, 4.0),
    vector(-1.0, 0.5, 0.0));
  struct timespec started = {0}, finished = {0};
  uint64_t batchChecksum = 0;
  const int startStatus = clock_gettime(CLOCK_ID, &started);
  for (int64_t repetition = 0; repetition < REPETITIONS; ++repetition) {
    render(pixels, camera);
    uint64_t frameChecksum = 0;
    for (size_t i = 0; i < channelCount; ++i)
      frameChecksum += pixels[i];
    checksumSink = frameChecksum;
    batchChecksum += checksumSink;
  }
  const int finishStatus = clock_gettime(CLOCK_ID, &finished);
  uint64_t checksum = 0;
  for (size_t i = 0; i < channelCount; ++i) checksum += pixels[i];
  printf("NIFTY_RAY_V1\nsize %d\nrepeat %d\n", IMAGE_SIZE, REPETITIONS);
  printf("start_sec %lld\nstart_nsec %ld\nend_sec %lld\nend_nsec %ld\n",
    (long long)started.tv_sec, started.tv_nsec,
    (long long)finished.tv_sec, finished.tv_nsec);
  printf("clock_status %d %d\n", startStatus, finishStatus);
  printf("checksum %" PRIu64 "\nbatch_checksum %" PRIu64 "\n",
    checksum, batchChecksum);
#if EMIT_PIXELS == 1
  for (size_t i = 0; i < channelCount; i += 3)
    printf("rgb %u %u %u\n", (unsigned)pixels[i],
      (unsigned)pixels[i + 1], (unsigned)pixels[i + 2]);
#endif
  free(pixels);
  return startStatus != 0 || finishStatus != 0;
}
