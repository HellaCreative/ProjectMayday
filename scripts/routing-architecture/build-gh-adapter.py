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
querySource=r/'sources/graphhopper/core/src/main/java/com/graphhopper/routing/querygraph/QueryGraph.java'
qs=querySource.read_text();old='private QueryGraph(BaseGraph graph, List<Snap> snaps)';assert qs.count(old)==1
(b/'QueryGraph.java').write_text(qs.replace(old,'protected QueryGraph(BaseGraph graph, List<Snap> snaps)'))
subprocess.run(['/opt/homebrew/opt/openjdk/bin/javac','-cp',str(r/'tools/graphhopper-web-11.0.jar'),'-d',str(b),str(b/'RestrictionSetter.java'),str(b/'QueryGraph.java'),str(here/'ExactQueryGraph.java'),str(here/'VerifiedHopper.java'),str(here/'FuelSearch.java'),str(here/'ConcurrentVerifiedHopper.java')],check=True)
identity_files = [source, querySource, b/'RestrictionSetter.java', b/'QueryGraph.java',
                  here/'ExactQueryGraph.java', here/'VerifiedHopper.java', here/'FuelSearch.java', here/'ConcurrentVerifiedHopper.java',
                  r/'tools/graphhopper-web-11.0.jar']
(b/'build-identity.json').write_text(json.dumps({
    'files': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in identity_files},
    'scope': 'Pinned upstream inputs and every compiled private Java extension.'
}, indent=2))
