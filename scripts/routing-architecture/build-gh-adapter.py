"""Compile isolated extension against pinned GH 11 jar; never alter upstream source."""
import pathlib,subprocess,hashlib,json
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');here=pathlib.Path(__file__).resolve().parent
source=r/'sources/graphhopper/core/src/main/java/com/graphhopper/routing/util/parsers/RestrictionSetter.java'
s=source.read_text();needle='        disableRedundantRestrictions(internalRestrictions, encBits);'
assert s.count(needle)==1
extension='''        setInternalRestrictions(internalRestrictions, encBits);
    }

    // Private DIRT extension: direction is already resolved by the verified topology.
    public void setDirectedRestrictions(List<IntArrayList> keys, List<IntArrayList> nodes, List<BitSet> bits) {
        if(keys.size()!=nodes.size() || keys.size()!=bits.size()) throw new IllegalArgumentException("restriction sizes");
        List<InternalRestriction> list = new java.util.ArrayList<>();
        for(int i=0;i<keys.size();i++) {
            IntArrayList k=keys.get(i), n=nodes.get(i);
            if(k.size()<2 || n.size()!=k.size()-1) throw new IllegalArgumentException("restriction length");
            for(int j=0;j<n.size();j++) {
                if(baseGraph.getEdgeIteratorStateForKey(k.get(j)).getAdjNode()!=n.get(j) ||
                   baseGraph.getEdgeIteratorStateForKey(k.get(j+1)).getBaseNode()!=n.get(j))
                    throw new IllegalArgumentException("disconnected directed restriction");
            }
            list.add(new InternalRestriction(n,k));
        }
        setInternalRestrictions(list,bits);
    }

    private void setInternalRestrictions(List<InternalRestriction> internalRestrictions, List<BitSet> encBits) {
'''
s=s.replace(needle,extension+needle)
b=r/'tools/gh-adapter';b.mkdir(exist_ok=True);(b/'RestrictionSetter.java').write_text(s)
subprocess.run(['/opt/homebrew/opt/openjdk/bin/javac','-cp',str(r/'tools/graphhopper-web-11.0.jar'),'-d',str(b),str(b/'RestrictionSetter.java'),str(here/'VerifiedHopper.java')],check=True)
(b/'build-identity.json').write_text(json.dumps({'upstreamSha256':hashlib.sha256(source.read_bytes()).hexdigest(),'extensionSha256':hashlib.sha256(s.encode()).hexdigest(),'adapterSha256':hashlib.sha256((here/'VerifiedHopper.java').read_bytes()).hexdigest()},indent=2))
