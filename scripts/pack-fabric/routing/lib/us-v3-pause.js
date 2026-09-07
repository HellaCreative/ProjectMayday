"use strict";

/**
 * Safety lock after the Highway 104 wrong-way defect.
 *
 * Every V3 pack from the two-way encoder must be rebuilt with directed travel.
 * Stamp, candidate upload, and promote stay paused for every region until a
 * human sets DIRT_RESUME_PACK_FACTORY=1. LIVE deploy and --assert stay open so
 * the NS directed canary can still be tested.
 */
const PACK_FACTORY_PAUSED_FOR_DIRECTION = true;
const PACK_FACTORY_PAUSE_MESSAGE =
  "Pack factory is paused. Directed travel requires every V3 region to be rebuilt. Do not stamp, candidate-upload, or promote until DIRT_RESUME_PACK_FACTORY=1.";

function resumeRequested({ resumeEnv, usResumeEnv } = {}) {
  const factory = resumeEnv == null ? process.env.DIRT_RESUME_PACK_FACTORY : resumeEnv;
  const us = usResumeEnv == null ? process.env.DIRT_RESUME_US_V3 : usResumeEnv;
  return factory === "1" || us === "1";
}

function assertPackFactoryNotPaused(regionId, options = {}) {
  if (!PACK_FACTORY_PAUSED_FOR_DIRECTION) return;
  if (resumeRequested(options)) return;
  throw new Error(PACK_FACTORY_PAUSE_MESSAGE);
}

function assertUsV3NotPaused(regionId, options = {}) {
  assertPackFactoryNotPaused(regionId, options);
}

module.exports = {
  PACK_FACTORY_PAUSED_FOR_DIRECTION,
  PACK_FACTORY_PAUSE_MESSAGE,
  US_V3_PAUSED_FOR_DIRECTION: PACK_FACTORY_PAUSED_FOR_DIRECTION,
  US_V3_PAUSE_MESSAGE: PACK_FACTORY_PAUSE_MESSAGE,
  assertPackFactoryNotPaused,
  assertUsV3NotPaused
};
