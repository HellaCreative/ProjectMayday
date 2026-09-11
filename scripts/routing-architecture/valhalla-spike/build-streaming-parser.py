"""Compile one private replacement object and link ahead of read-only upstream archive.
Invoke without --run to produce reviewable exact command plan only.
"""
import pathlib,shlex,json,subprocess,sys
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');src=root/'sources/valhalla';build=src/'build';out=root/'valhalla-spike'
flags={}
for line in (build/'src/mjolnir/CMakeFiles/valhalla-mjolnir.dir/flags.make').read_text().splitlines():
 if ' = ' in line:
  k,v=line.split(' = ',1);flags[k]=shlex.split(v)
compile=['/usr/bin/c++','-I'+str(src/'src/mjolnir')]+flags['CXX_DEFINES']+flags['CXX_INCLUDES']+flags['CXX_FLAGS']+['-c',str(out/'pbfgraphparser.streaming.cc'),'-o',str(out/'pbfgraphparser.streaming.o')]
link=shlex.split((build/'CMakeFiles/valhalla_build_tiles.dir/link.txt').read_text());link[link.index('-o')+1]=str(out/'valhalla_build_tiles_streaming');link.insert(link.index('src/libvalhalla.a'),str(out/'pbfgraphparser.streaming.o'))
(out/'streaming-build-plan.json').write_text(json.dumps({'cwd':str(build),'commands':[compile,link],'scope':'Only private output object/executable; original source/archive/executable read-only'},indent=2))
if '--run' in sys.argv:
 for command in [compile,link]:subprocess.run(command,cwd=build,check=True)
else:print(out/'streaming-build-plan.json')
