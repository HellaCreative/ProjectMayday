"""Build a private macOS diagnostic from actual native source snapshots.

No iOS app build, device installation, pack conversion or engine rewrite.
POIFeature and FuelGap are extracted byte-for-byte to avoid UI dependencies.
Optional cancellation checks modify only the generated diagnostic source; the
app's source remains unchanged and both input/output source hashes are retained.
The source tree must be present; missing files fail instead of using substitutes.
"""
import argparse, hashlib, json, pathlib, subprocess
p = argparse.ArgumentParser()
p.add_argument('--source', required=True, type=pathlib.Path)
p.add_argument('--out', required=True, type=pathlib.Path)
p.add_argument('--cancellation-prototype', action='store_true')
a = p.parse_args()
names = ['Routing/RoutingModels.swift', 'Routing/GeoMath.swift',
         'Routing/HopSearchPolicy.swift', 'Routing/UrbanCore.swift', 'Routing/PackedFuel.swift', 'Routing/FuelItinerary.swift',
         *['Routing/OnDevice/' + x + '.swift' for x in [
             'GraphV2Pack', 'GraphV4Pack', 'GeometryV1Pack', 'OnDeviceRouter',
             'OnDeviceProfileCosts', 'OnDevicePathPruning', 'SurfaceFamily', 'RoadTier',
             'PathRetrace', 'RoadCompass', 'CustomerEndpointAccess']],
         'Features/RoutePlanning/RidePreferences.swift']
sources = [a.source/'Dirt'/name for name in names]
poi = a.source/'Dirt/Map/POIManager.swift'
gap = a.source/'Dirt/Features/RoutePlanning/Itinerary/BuiltItinerary.swift'
driver = pathlib.Path(__file__).with_name('NativeWorkloadProbe.swift')
resource = a.source/'Dirt/Routing/UrbanSettlements.json'
original = {str(f): f.read_bytes() for f in [*sources, poi, gap, driver, resource]}
if a.out.exists(): raise RuntimeError('Use a new build directory')
a.out.mkdir(parents=True)
for src in sources: (a.out/src.name).write_bytes(original[str(src)])
if a.cancellation_prototype:
    target = a.out/'OnDeviceRouter.swift'
    text = target.read_text()
    head = 'nonisolated struct OnDeviceRouter {'
    loop = 'while let cur = heap.pop() {'
    compass = 'deadline: Date().addingTimeInterval(ctx.timeCapSeconds ?? HopSearchPolicy.pass2TimeCapSeconds)) { state, visit in'
    if text.count(head) != 1 or text.count(loop) != 5 or text.count(compass) != 1:
        raise RuntimeError('Native cancellation anchors changed; review source before patching')
    text = text.replace(head, head + '\n    var executionCancelled: @Sendable () -> Bool = { false }')
    text = text.replace(loop, loop + '\n            if executionCancelled() { break }')
    text = text.replace(compass, 'deadline: Date().addingTimeInterval(ctx.timeCapSeconds ?? HopSearchPolicy.pass2TimeCapSeconds), cancelled: executionCancelled) { state, visit in')
    target.write_text(text)
(a.out/resource.name).write_bytes(original[str(resource)])
model = original[str(poi)].decode()
start = model.index('struct POIFeature: Sendable {')
end = model.index('\n/// Collapse OSM duplicates', start)
(a.out/'POIFeature.swift').write_text('import Foundation\n' + model[start:end])
model = original[str(gap)].decode()
start = model.index('struct FuelGap: Equatable, Sendable {')
end = model.index('\nenum LegStatus:', start)
(a.out/'FuelGap.swift').write_text('import Foundation\n' + model[start:end])
(a.out/driver.name).write_bytes(original[str(driver)])
command = ['xcrun', 'swiftc', '-O', '-parse-as-library',
           *(['-D', 'DEVICE_CANCELLATION_PROTOTYPE'] if a.cancellation_prototype else []),
           *map(str, sorted(a.out.glob('*.swift'))), '-o', str(a.out/'native-probe')]
with (a.out/'build.log').open('w') as log:
    rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
changed = [name for name,data in original.items() if pathlib.Path(name).read_bytes() != data]
receipt = {'sourceRoot': str(a.source), 'files': {name: hashlib.sha256(data).hexdigest()
           for name,data in original.items()}, 'changedDuringBuild': changed,
           'returncode': rc, 'command': command, 'cancellationPrototype': a.cancellation_prototype,
           'compiledSwiftHashes': {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in a.out.glob('*.swift')},
           'scope': 'Native source on macOS. Not an iPhone capacity qualification.'}
(a.out/'build.json').write_text(json.dumps(receipt, indent=2))
print(json.dumps({'returncode': rc, 'changedDuringBuild': changed, 'out': str(a.out)}))
raise SystemExit(rc or bool(changed))
