"use strict";
// Spend bounded seam attempts on distinct networks before retrying the same
// disconnected fragment. Component size orders attempts, never grants access;
// every selected crossing still needs the normal directed route proof.
function rankSeams(rows, distance) {
  const ordered = rows.map((row, index) => ({ row, index, distance: distance(row) }))
    .sort((a, b) => a.distance - b.distance || a.index - b.index);
  const groups = new Map();
  for (const item of ordered) {
    const key = item.row.componentPair || `legacy:${item.index}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(item);
  }
  const networks = [...groups.values()].sort((a, b) =>
    (Number(b[0].row.networkSize) || 0) - (Number(a[0].row.networkSize) || 0) ||
    a[0].distance - b[0].distance || a[0].index - b[0].index);
  const first = networks.map(group => group[0]);
  const selected = new Set(first.map(item => item.index));
  return [...first, ...ordered.filter(item => !selected.has(item.index))].map(item => item.row);
}
module.exports = { rankSeams };
