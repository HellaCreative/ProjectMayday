"use strict";
// Keep search, final proof and destination escape consistent at floating-point
// boundaries. This existing proof tolerance is one micrometre in road distance,
// not an allowance to spend the rider's protected reserve.
const ROUNDING_METERS=1e-6;
function fuelCovers(remainingMeters,distanceMeters) {
  return distanceMeters<=remainingMeters+ROUNDING_METERS;
}
module.exports={fuelCovers};
