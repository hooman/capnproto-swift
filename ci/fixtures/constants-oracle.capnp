@0xc0c5000000000002;
# Not generated: the oracle value is a struct constant, which stays diagnosed (D-14).
# Each field references a constant in constants.capnp, so capnp itself evaluates them.

using C = import "constants.capnp";

const values :C.Oracle = (
  answer = C.answer, minInt64 = C.minInt64, maxUInt64 = C.maxUInt64, minInt8 = C.minInt8,
  minInt16 = C.minInt16, maxUInt8 = C.maxUInt8, maxUInt16 = C.maxUInt16,
  maxUInt32 = C.maxUInt32, yes = C.yes, no = C.no, notANumber = C.notANumber,
  negativeInfinity = C.negativeInfinity, negativeZero = C.negativeZero,
  subnormal = C.subnormal, large = C.large, third = C.third, floor = C.Limits.floor,
  depth = C.Limits.Inner.depth);
