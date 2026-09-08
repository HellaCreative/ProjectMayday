'use strict';
const {surfaceKind}=require('./surface');
// Relative candidate-search costs, not forbidden road classes. Service roads
// stay available for fuel/anchors but must not become cheap highway bypasses.
const roadFactors=Object.freeze({primary:4,primary_link:4,trunk:8,trunk_link:8,
 motorway:32,motorway_link:32,freeway:32,service:6});
function pavedBackroadCost(arc) {
 return arc.distanceMeters*(roadFactors[arc.roadClassLeaf]||1)*(surfaceKind(arc.surfaceLeaf)==='paved'?1:100);
}
module.exports={pavedBackroadCost};
