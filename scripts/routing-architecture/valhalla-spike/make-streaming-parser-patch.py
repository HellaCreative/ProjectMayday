"""Generate review-only cul-de-sac streaming patch. Never edits shared source/build."""
import pathlib,hashlib,difflib,json
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');src=root/'sources/valhalla/src/mjolnir/pbfgraphparser.cc';out=root/'valhalla-spike';s=src.read_text();old=s
s=s.replace('void clarify_and_fix(sequence<OSMWayNode>& osm_way_node_seq, sequence<OSMWay>& osm_way_seq) {','''void clarify_and_fix(sequence<OSMWayNode>& osm_way_node_seq, sequence<OSMWay>& osm_way_seq,
                       const std::string& way_nodes_file, const std::string& ways_file) {''')
a='''    for (const auto& osm_way_node : osm_way_node_seq) {
      // Reads a new way only after its nodes are read.
      if (number_of_nodes == count_node) {
        osm_way = *osm_way_seq[osm_way_node.way_index];'''
b='''    // Sequential read streams do not fault both complete mmap files into process RSS.
    // Keep the existing sequences for flush and the small final cul-de-sac updates.
    std::ifstream nodes_stream(way_nodes_file, std::ios::binary);
    std::ifstream ways_stream(ways_file, std::ios::binary);
    if (!nodes_stream || !ways_stream)
      throw std::runtime_error("Unable to open cul-de-sac input streams");
    OSMWayNode osm_way_node;
    while (nodes_stream.read(reinterpret_cast<char*>(&osm_way_node), sizeof(OSMWayNode))) {
      // Reads a new way only after its nodes are read.
      if (number_of_nodes == count_node) {
        ways_stream.seekg(static_cast<std::streamoff>(osm_way_node.way_index) * sizeof(OSMWay));
        if (!ways_stream.read(reinterpret_cast<char*>(&osm_way), sizeof(OSMWay)))
          throw std::runtime_error("Unable to read cul-de-sac way record");'''
assert a in s;s=s.replace(a,b,1)
a='''    fix(osm_way_seq);
  }

private:''';b='''    if (!nodes_stream.eof() || nodes_stream.gcount() != 0)
      throw std::runtime_error("Truncated cul-de-sac node record");
    fix(osm_way_seq);
  }

private:''';assert a in s;s=s.replace(a,b,1)
a='parser.culdesac_processor_.clarify_and_fix(*parser.way_nodes_, *parser.ways_);';b='parser.culdesac_processor_.clarify_and_fix(*parser.way_nodes_, *parser.ways_, way_nodes_file, ways_file);';assert a in s;s=s.replace(a,b,1)
(out/'pbfgraphparser.streaming.cc').write_text(s)
patch=''.join(difflib.unified_diff(old.splitlines(True),s.splitlines(True),fromfile='a/src/mjolnir/pbfgraphparser.cc',tofile='b/src/mjolnir/pbfgraphparser.cc'))
(out/'culdesac-streaming.patch').write_text(patch)
(out/'culdesac-streaming-proposal.json').write_text(json.dumps({'status':'Review-only generated patch; not compiled or run','sourceSha256':hashlib.sha256(old.encode()).hexdigest(),'patchedSha256':hashlib.sha256(s.encode()).hexdigest(),'patchSha256':hashlib.sha256(patch.encode()).hexdigest()},indent=2));print(patch)
