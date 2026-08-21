"use strict";

function lineRuntime() {
  const nodes = [];
  for (let i = 0; i <= 8; i += 1) nodes.push([i * 0.5, 45]);
  const edges = [];
  const adjacency = Array.from({ length: nodes.length }, () => []);
  const edgeGrid = new Map();
  const GRID = 0.01;
  for (let i = 0; i < nodes.length - 1; i += 1) {
    const edge = {
      a: i, b: i + 1, m: 39_313, s: 0, ac: 0, t: 0,
      rt: "local", i: `e${i}`, c: 0, g: [nodes[i], nodes[i + 1]]
    };
    const edgeIndex = edges.length;
    edges.push(edge);
    adjacency[i].push(edgeIndex);
    adjacency[i + 1].push(edgeIndex);
    const x0 = Math.floor(nodes[i][0] / GRID);
    const x1 = Math.floor(nodes[i + 1][0] / GRID);
    const y = Math.floor(45 / GRID);
    for (let x = x0; x <= x1; x += 1) {
      const key = `${x}:${y}`;
      if (!edgeGrid.has(key)) edgeGrid.set(key, []);
      edgeGrid.get(key).push(edgeIndex);
    }
  }
  return {
    data: { nodeCount: nodes.length, nodes, edges, regionId: "fixture" },
    adjacency, edgeGrid, GRID,
    enums: {
      SURFACE_NAME: ["paved"],
      ACCESS_NAME: ["motorized_permissive"],
      STRUCTURE_NAME: ["none"]
    }
  };
}

module.exports = { lineRuntime };
