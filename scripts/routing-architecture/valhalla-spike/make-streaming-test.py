import pathlib
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');out=root/'valhalla-spike'
def extract(s):return s[s.index('class culdesac_processor {'):s.index('// Construct PBFGraphParser based')]
old=extract((root/'sources/valhalla/src/mjolnir/pbfgraphparser.cc').read_text());new=extract((out/'pbfgraphparser.streaming.cc').read_text())
s='''#include <valhalla/midgard/sequence.h>
#include <valhalla/mjolnir/osmdata.h>
#include <valhalla/mjolnir/osmway.h>
#include <unordered_map>
#include <iostream>
#include <cassert>
#define SCOPED_TIMER()
#define LOG_INFO(...)
using namespace valhalla::midgard;
using namespace valhalla::mjolnir;
using namespace valhalla::baldr;
// Fixture-only setter; fixture ways have <=4 nodes, below saturation limit.
void OSMWay::set_node_count(uint32_t count) { assert(count<100); nodecount_=count; }
namespace before {
'''+old+'\n}\nnamespace after {\n'+new+'\n}\n'+r'''
int main(int argc,char**argv) {
 std::filesystem::path root(argv[1]);
 size_t tested=0;
 for(unsigned mask=0;mask<128;++mask){
  std::string paths[2][2];
  for(int variant=0;variant<2;++variant){
   paths[variant][0]=(root/("test-"+std::to_string(variant)+"-nodes.bin")).string();
   paths[variant][1]=(root/("test-"+std::to_string(variant)+"-ways.bin")).string();
   sequence<OSMWayNode> ns(paths[variant][0],true,1024);
   sequence<OSMWay> ws(paths[variant][1],true,1024);
   auto add=[&](uint64_t id,std::vector<uint64_t>nodes,Use use){
    OSMWay way(id);way.set_node_count(nodes.size());way.set_use(use);
    unsigned index=ws.size();ws.push_back(way);
    for(size_t j=0;j<nodes.size();++j){OSMWayNode n{};n.node.osmid_=nodes[j];n.way_index=index;n.way_shape_node_index=j;ns.push_back(n);}
   };
   add(100,{10,11,12,10},Use::kRoad);
   add(200,{20,21,22,20},Use::kRoad);
   for(unsigned i=0;i<7;++i)if(mask&(1<<i))add(300+i,{i<3?10+i:20+i-3,100+i},i==6?Use::kFootway:Use::kRoad);
   if(variant==0){before::culdesac_processor p;p.add_candidate(100,0,{10,11,12,10});p.add_candidate(200,1,{20,21,22,20});p.clarify_and_fix(ns,ws);}
   else {after::culdesac_processor p;p.add_candidate(100,0,{10,11,12,10});p.add_candidate(200,1,{20,21,22,20});p.clarify_and_fix(ns,ws,paths[variant][0],paths[variant][1]);}
  }
  for(int file=0;file<2;++file){std::ifstream a(paths[0][file],std::ios::binary),b(paths[1][file],std::ios::binary);std::string aa((std::istreambuf_iterator<char>(a)),{}),bb((std::istreambuf_iterator<char>(b)),{});if(aa!=bb){std::cerr<<"mismatch "<<mask<<" "<<file<<"\n";return 2;}}
  ++tested;
 }
 std::cout<<"Compared "<<tested<<" fixtures, both way and node files byte-identical. OSMWay="<<sizeof(OSMWay)<<" OSMWayNode="<<sizeof(OSMWayNode)<<"\n";
}
'''
(out/'streaming-test.cc').write_text(s)
