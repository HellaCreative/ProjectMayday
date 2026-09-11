"""Refuse benchmark execution if the compiled adapter differs from current sources."""
import pathlib,json,hashlib
def ensure_current(root):
 identity=pathlib.Path(root)/'tools/gh-adapter/build-identity.json'
 data=json.loads(identity.read_text())
 for filename,wanted in data['files'].items():
  path=pathlib.Path(filename)
  if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=wanted:raise RuntimeError('Compiled adapter is stale; build must succeed before benchmarking: '+filename)
 return hashlib.sha256(identity.read_bytes()).hexdigest()
