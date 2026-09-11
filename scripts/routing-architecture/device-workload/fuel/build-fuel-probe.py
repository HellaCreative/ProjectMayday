"""Snapshot the actual PackRoutingSource fuel algorithm into a local diagnostic.

The algorithm is extracted unchanged; a single-region, instrumented pack facade
calls the pinned real native router. This does not modify or build the main app.
"""
import argparse,pathlib,json,hashlib,subprocess
from prepare_matching import patch
p=argparse.ArgumentParser()
p.add_argument('--snapshot',required=True,type=pathlib.Path)
p.add_argument('--source',required=True,type=pathlib.Path)
p.add_argument('--out',required=True,type=pathlib.Path)
a=p.parse_args()
if a.out.exists():raise RuntimeError('Use a new build directory')
sha=lambda b:hashlib.sha256(b).hexdigest()
receipt=json.loads((a.snapshot/'build.json').read_text())
assert receipt['returncode']==0 and not receipt['changedDuringBuild'] and receipt['cancellationPrototype']
a.out.mkdir(parents=True)
for name,digest in receipt['compiledSwiftHashes'].items():
 data=(a.snapshot/name).read_bytes()
 assert sha(data)==digest,name
 if name!='NativeWorkloadProbe.swift':(a.out/name).write_bytes(data)
(a.out/'UrbanSettlements.json').write_bytes((a.snapshot/'UrbanSettlements.json').read_bytes())
src=a.source/'Dirt/Features/RoutePlanning/Itinerary/RoutingSource.swift'
original=src.read_bytes(); text=original.decode()
start=text.index('    func fuelChain(_ req: FuelChainRequest)',text.index('final class PackRoutingSource'))
end=text.index('\n    func fuelStation(',start)
original_method=text[start:end]
anchor='''            if let direct,
               destinationLimit'''
assert original_method.count(anchor)==1
method=original_method.replace(anchor,'''            if (!NativeFuelPreparation.skipUnusedDirect || !mustPump), let direct,
               destinationLimit''')
(a.out/'CapturedFuelMethod.original.txt').write_text(original_method)
facade='''import Foundation
import CoreLocation
@MainActor final class CapturedNativeFuelPlanner {
    let packs: NativePackFacade
    init(packs: NativePackFacade) { self.packs = packs }
'''+method+'\n}\n'
(a.out/'CapturedNativeFuelPlanner.swift').write_text(facade)
for f in pathlib.Path(__file__).parent.glob('*.swift'):(a.out/f.name).write_bytes(f.read_bytes())
patch(a.out)
cmd=['xcrun','swiftc','-O','-parse-as-library',*map(str,sorted(a.out.glob('*.swift'))),'-o',str(a.out/'native-fuel-probe')]
with (a.out/'build.log').open('w') as log: rc=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT).returncode
changed=src.read_bytes()!=original
out={'returncode':rc,'command':cmd,'fuelSourcePath':str(src),'fuelSourceSHA256':sha(original),
     'capturedOriginalFuelMethodSHA256':sha(original_method.encode()),'generatedFuelMethodSHA256':sha(method.encode()),
     'fuelMethodChange':'Optional skip of direct route that cannot be used while a mandatory stop is outstanding; flag DIRT_FUEL_SKIP_UNUSED_DIRECT=0 retains original control flow.',
     'sourceChangedDuringBuild':changed,
     'pinnedNativeReceiptSHA256':sha((a.snapshot/'build.json').read_bytes()),
     'compiledSwiftHashes':{f.name:sha(f.read_bytes()) for f in a.out.glob('*.swift')},
     'preparationPatchHashes':{f.name:sha(f.read_bytes()) for f in pathlib.Path(__file__).parent.iterdir() if f.suffix in ('.fragment','.py')},
     'scope':'macOS fuel diagnostic with real captured algorithm and real native engine; single installed NS pack facade; no phone or full-app qualification'}
(a.out/'build.json').write_text(json.dumps(out,indent=2))
print(json.dumps({'returncode':rc,'sourceChangedDuringBuild':changed,'out':str(a.out)}))
raise SystemExit(rc or changed)
