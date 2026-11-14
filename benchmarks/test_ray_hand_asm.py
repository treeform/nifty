#!/usr/bin/env python3
"""Native Darwin ARM64 RGB, boundary, differential and ABI checks."""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

Root = Path(__file__).resolve().parent
Symbols = ('vector add subtract scale multiply dot cross magnitude normalize '
           'newCamera getNormal objectIntersect getProperties intersections '
           'traceRay getNaturalColor shade getPoint channel render').split()


def abi_probe():
  """Generate a test-only Darwin trampoline with preserved-register sentinels."""
  lines = ['.text', '.p2align 2', '.globl _rayAbiProbe', '_rayAbiProbe:',
           'sub sp, sp, #176', 'stp x29, x30, [sp, #160]']
  for i in range(5):
    lines += [f'stp x{19+2*i}, x{20+2*i}, [sp, #{16*i}]']
  for i in range(4):
    lines += [f'stp d{8+2*i}, d{9+2*i}, [sp, #{80+16*i}]']
  lines += ['mov x29, sp', 'mov x16, x0', 'mov x0, x1',
            'mov x1, x2', 'mov x2, x3', 'mov x3, x4', 'fmov d0, x5']
  for i in range(19, 29):
    lines += [f'mov x{i}, #{i*137}']
  for i in range(8, 16):
    lines += [f'mov x9, #{i*251}', f'fmov d{i}, x9']
  lines += ['blr x16', 'mov x0, #0', 'mov x9, sp', 'cmp x9, x29',
            'b.ne LrayFail']
  for i in range(19, 29):
    lines += [f'cmp x{i}, #{i*137}', 'b.ne LrayFail']
  for i in range(8, 16):
    lines += [f'fmov x9, d{i}', f'cmp x9, #{i*251}', 'b.ne LrayFail']
  lines += ['b LrayRestore', 'LrayFail:', 'mov x0, #1', 'LrayRestore:']
  for i in range(5):
    lines += [f'ldp x{19+2*i}, x{20+2*i}, [sp, #{16*i}]']
  for i in range(4):
    lines += [f'ldp d{8+2*i}, d{9+2*i}, [sp, #{80+16*i}]']
  lines += ['ldp x29, x30, [sp, #160]', 'add sp, sp, #176', 'ret']
  return '\n'.join(lines) + '\n'


Harness = r'''
#include <assert.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
extern Camera newCamera(Vec3, Vec3);
extern Vec3 getPoint(int64_t, int64_t, Camera, int64_t);
extern Intersection objectIntersect(int64_t, Ray);
extern Intersection intersections(Ray);
extern Vec3 traceRay(Ray, int64_t);
extern Vec3 shade(Ray, Intersection, int64_t);
extern void render(uint8_t *, Camera, int64_t);
extern int rayAbiProbe(void (*)(void), uintptr_t, uintptr_t, uintptr_t,
  uintptr_t, uint64_t);
static uint32_t state = 17;
static double sample(void) {
  state = state * 1664525u + 1013904223u;
  return ((double)(state >> 8) / 16777216.0 - 0.5) * 12.0;
}
static void same(const void *a, const void *b, size_t n) {
  assert(memcmp(a, b, n) == 0);
}
int main(int argc, char **argv) {
  assert(argc == 2);
  Camera camera = ref_newCamera((Vec3){3,2,4}, (Vec3){-1,.5,0});
  Camera actual = newCamera((Vec3){3,2,4}, (Vec3){-1,.5,0});
  same(&camera, &actual, sizeof camera);
  for (int trial = 0; trial < 10000; ++trial) {
    Vec3 pos = {sample(), sample(), sample()};
    Vec3 look = {sample(), sample(), sample()};
    Camera a = ref_newCamera(pos, look), b = newCamera(pos, look);
    same(&a, &b, sizeof a);
    int64_t n = trial % 127 + 1, x = trial % n, y = trial * 7 % n;
    Vec3 p = ref_getPoint(x,y,a,n), q = getPoint(x,y,a,n);
    same(&p, &q, sizeof p);
    Ray ray = {pos, ref_normalize(look)};
    for (int i = 0; i < 3; ++i) {
      Intersection u = ref_objectIntersect(i,ray), v = objectIntersect(i,ray);
      same(&u, &v, sizeof u);
    }
    Intersection u = ref_intersections(ray), v = intersections(ray);
    same(&u, &v, sizeof u);
    if (trial < 1000) {
      Vec3 c = ref_traceRay(ray,trial % 7), d = traceRay(ray,trial % 7);
      same(&c, &d, sizeof c);
    }
    if (u.thing >= 0 && trial < 1000) {
      Vec3 c = ref_shade(ray,u,0), d = shade(ray,u,0);
      same(&c, &d, sizeof c);
    }
  }
  int sizes[] = {1,2,3,4,7,15,16,17,31,63,64,65,127,256,512};
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  for (size_t j = 0; j < sizeof sizes/sizeof *sizes; ++j) {
    int n = sizes[j]; size_t count = (size_t)n*n*3;
    uint8_t *expected = malloc(count); assert(expected);
    ref_render(expected,camera,n);
    size_t span = (count + page - 1)/page*page;
    uint8_t *map = mmap(NULL,span+2*page,PROT_READ|PROT_WRITE,
      MAP_PRIVATE|MAP_ANON,-1,0); assert(map != MAP_FAILED);
    assert(!mprotect(map,page,PROT_NONE));
    assert(!mprotect(map+page+span,page,PROT_NONE));
    for (int side = 0; side < 2; ++side) {
      memset(map+page,0xa5,span);
      uint8_t *pixels = side ? map+page+span-count : map+page;
      render(pixels,camera,n); same(pixels,expected,count);
      for (uint8_t *p = map+page; p < pixels; ++p) assert(*p == 0xa5);
      for (uint8_t *p = pixels+count; p < map+page+span; ++p)
        assert(*p == 0xa5);
    }
    if (n == 4 || n == 16 || n == 64) {
      char path[4096]; snprintf(path,sizeof path,"%s/%d.rgb",argv[1],n);
      FILE *f = fopen(path,"rb"); assert(f);
      for (size_t k = 0; k < count; ++k) assert(fgetc(f) == expected[k]);
      assert(fgetc(f) == EOF); fclose(f);
    }
    munmap(map,span+2*page); free(expected);
  }
  render(NULL,camera,0); render(NULL,camera,-1); render(NULL,camera,INT64_MIN);
  uint8_t pixels[4*4*3];
  assert(!rayAbiProbe((void (*)(void))render,(uintptr_t)pixels,
    (uintptr_t)&camera,4,0,0));
  Ray ray = {{0,3,0},{0,-1,0}};
  assert(!rayAbiProbe((void (*)(void))intersections,(uintptr_t)&ray,0,0,0,0));
  assert(!rayAbiProbe((void (*)(void))traceRay,(uintptr_t)&ray,0,0,0,0));
  /* Darwin passes the mixed Intersection aggregate in integer registers. */
  Intersection hit = ref_intersections(ray);
  assert(hit.thing >= 0);
  uint64_t distance; memcpy(&distance,&hit.dist,8);
  assert(!rayAbiProbe((void (*)(void))shade,(uintptr_t)&ray,
    (uintptr_t)hit.thing,distance,0,0));
  puts("Hand ASM raytracer: RGB goldens, differential, guards and ABI passed");
  return 0;
}
'''


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--assembly', type=Path,
                      default=Root / 'arm64/raytracer_hand.S')
  args = parser.parse_args()
  if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    print('SKIP: ray Hand ASM requires native macOS ARM64')
    return
  with tempfile.TemporaryDirectory(prefix='ray-hand-test-') as temp:
    folder = Path(temp)
    source = folder / 'test.c'
    prefix = '#define _DARWIN_C_SOURCE\n#define RAY_STRAIGHT_NO_MAIN\n'
    prefix += ''.join(f'#define {s} ref_{s}\n' for s in Symbols)
    prefix += '#include "raytracer_straight.c"\n'
    prefix += ''.join(f'#undef {s}\n' for s in Symbols)
    source.write_text(prefix + Harness)
    probe = folder / 'probe.S'
    probe.write_text(abi_probe())
    executable = folder / 'test'
    subprocess.run(['clang', '-O2', '-fno-fast-math', '-ffp-contract=off',
                    '-fsanitize=address,undefined', '-I', str(Root), str(source),
                    str(args.assembly.resolve()), str(probe), '-o',
                    str(executable)], check=True)
    subprocess.run([str(executable), str(Root / 'reference')], check=True)


if __name__ == '__main__':
  main()
