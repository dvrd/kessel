// TS2300 — duplicate bare-name interface members.
// Pre-session-5 the kessel parser misparsed `m<U>(): T` and
// `readonly _A: T` as runs of bare TSPropertySignatures, so the
// dup-detection slice C had to skip any slot containing a bare prop.
// After fixing the parser (parse_ts_object_member: recognise generic
// methods via LAngle and absorb the contextual `readonly` modifier),
// the carve-out is gone — bare duplicates like the ones below are
// now correctly flagged TS2300.
interface Bar {
  x;
  x;
}
