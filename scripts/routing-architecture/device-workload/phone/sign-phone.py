"""Sign a fresh private app copy using an existing local development profile.

Does not register devices, contact a portal, install, launch or modify DIRT.
The caller must separately obtain authorization for the named physical device.
"""
import argparse, hashlib, json, pathlib, plistlib, shutil, subprocess
p = argparse.ArgumentParser()
p.add_argument('--build', required=True, type=pathlib.Path)
p.add_argument('--out', required=True, type=pathlib.Path)
p.add_argument('--profile', required=True, type=pathlib.Path)
p.add_argument('--identity', required=True)
p.add_argument('--device-udid', required=True)
a = p.parse_args()
if a.out.exists(): raise RuntimeError('Use a fresh signing directory')
build = json.loads((a.build/'build.json').read_text())
if build['returncode'] or build['platform'] != 'iphoneos': raise RuntimeError('Requires successful iPhoneOS build')
profile = plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(a.profile)]))
if a.device_udid not in profile.get('ProvisionedDevices',[]): raise RuntimeError('Device not in local profile')
if a.identity.upper() not in [hashlib.sha1(x).hexdigest().upper() for x in profile['DeveloperCertificates']]:
    raise RuntimeError('Signing certificate does not match profile')
src = a.build/'DIRTPhoneLab.app'
bundle = plistlib.loads((src/'Info.plist').read_bytes())['CFBundleIdentifier']
if bundle != 'local.dirt.experiments.phonelab20260911': raise RuntimeError('Unexpected bundle identifier')
team = profile['TeamIdentifier'][0]
allowed = profile['Entitlements']['application-identifier']
appid = team + '.' + bundle
if not (allowed == appid or allowed.endswith('.*') and appid.startswith(allowed[:-1])):
    raise RuntimeError('Profile does not allow private bundle')
if not profile['Entitlements'].get('get-task-allow'): raise RuntimeError('Requires development profile')
sha = lambda data: hashlib.sha256(data).hexdigest()
if sha((src/'DIRTPhoneLab').read_bytes()) != build['executableSHA256']: raise RuntimeError('Unsigned executable changed')
app = a.out/'DIRTPhoneLab.app'
shutil.copytree(src, app)
shutil.copy2(a.profile, app/'embedded.mobileprovision')
entitlements = {'application-identifier': appid, 'com.apple.developer.team-identifier': team, 'get-task-allow': True}
ent = a.out/'entitlements.plist'; ent.write_bytes(plistlib.dumps(entitlements))
subprocess.run(['codesign','--force','--sign',a.identity,'--entitlements',str(ent),str(app)],check=True)
subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
receipt = {'unsignedBuildReceiptSHA256': sha((a.build/'build.json').read_bytes()),
           'manifestSHA256': sha((app/'probe-manifest.json').read_bytes()),
           'signedExecutableSHA256': sha((app/'DIRTPhoneLab').read_bytes()),
           'profileSHA256': sha(a.profile.read_bytes()), 'signingIdentity': a.identity,
           'bundleIdentifier': bundle, 'installed': False, 'portalOperations': False,
           'appBytes': sum(f.stat().st_size for f in app.rglob('*') if f.is_file())}
(a.out/'signing.json').write_text(json.dumps(receipt,indent=2))
print(json.dumps(receipt))
