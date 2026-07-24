requires "kontrol.md"

// SwapVM shared lemma library.
//
// Nearly every SwapVM pricing instruction reduces to the same arithmetic skeleton: a
// 256-bit `mulDiv`, flooring on the amountOut leg and ceiling on the amountIn leg. For
// example XYCSwap and LimitSwap differ only in the denominator:
//
//   XYCSwap    amountOut = amountIn * balanceOut / (balanceIn + amountIn)
//              amountIn  = ceilDiv(amountOut * balanceIn, balanceOut - amountOut)
//   LimitSwap  amountOut = amountIn * balanceOut / balanceIn
//              amountIn  = ceilDiv(amountOut * balanceIn, balanceOut)
//
// The lemmas needed to discharge one are therefore largely the lemmas needed to
// discharge all of them, which is why this library is shared rather than per-instruction.
//
// Conventions for contributors:
//   * Every rule carries a `[simplification]` attribute and a unique label, so that
//     `grep <label> out/kompiled/definition.kore` can confirm it was actually compiled in.
//   * Add `preserves-definedness` only when the rule cannot introduce a partial term
//     (e.g. it does not create a division whose divisor might be zero).
//   * State the soundness argument in a comment. A silently unsound lemma makes every
//     proof in the repo meaningless, and nothing in the tooling will flag it.
//   * Append new rules to the relevant section rather than editing existing ones, so
//     concurrent work merges cleanly.
//
// Before trusting any proof after editing this file, see test/kontrol/README.md — a
// stale copy of this file can survive `kontrol build --rekompile` silently.

module SWAPVM-LEMMAS
    imports KONTROL-BASE

// ---------------------------------------------------------------------------
// Section 1: multiplication overflow guards
// ---------------------------------------------------------------------------
//
// Solidity 0.8 guards `a * b` with the check `(a * b) / a == b`, which KEVM's
// `chop-no-overflow-mul-eq` rules rewrite into the obligation `X *Int Y <Int pow256`.
// Harnesses establish that bound by assuming `X <= type(uint256).max / Y`, but
// discharging the implication needs a product and a division of two symbolic operands.
// Z3 handles such non-linear goals poorly, and KEVM's own transfer rules for `*Int`
// under `<Int`/`<=Int` are gated on `concrete(A, C)`, so none of them fire when both
// operands are symbolic — which is exactly the SwapVM case.
//
// Soundness: for Y > 0, X <= floor(C / Y) implies X *Int Y <= floor(C / Y) *Int Y <= C.

    rule [mul-bound-transfer]:
      X *Int Y <=Int C => true
      requires 0 <=Int X
       andBool 0 <Int Y
       andBool X <=Int C /Int Y
      [simplification, preserves-definedness]

    rule [mul-bound-transfer-comm]:
      Y *Int X <=Int C => true
      requires 0 <=Int X
       andBool 0 <Int Y
       andBool X <=Int C /Int Y
      [simplification, preserves-definedness]

// `pow256` variants: `X <= maxUInt256 / Y` bounds the product by maxUInt256, which is
// strictly below pow256.

    rule [mul-no-overflow]:
      X *Int Y <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <Int Y
       andBool X <=Int maxUInt256 /Int Y
      [simplification, preserves-definedness]

    rule [mul-no-overflow-comm]:
      Y *Int X <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <Int Y
       andBool X <=Int maxUInt256 /Int Y
      [simplification, preserves-definedness]

// ---------------------------------------------------------------------------
// Section 2: addition overflow guards
// ---------------------------------------------------------------------------
//
// For `balanceIn + amountIn` style denominators and `totalX += delta` accumulators
// guarded by an assumption of the form `X <= type(uint256).max - Y`.

    rule [add-no-overflow]:
      X +Int Y <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <=Int Y
       andBool X <=Int maxUInt256 -Int Y
      [simplification]

    rule [add-no-overflow-le]:
      X +Int Y <=Int maxUInt256 => true
      requires 0 <=Int X
       andBool 0 <=Int Y
       andBool X <=Int maxUInt256 -Int Y
      [simplification]

// ---------------------------------------------------------------------------
// Section 3: floor division bounds
// ---------------------------------------------------------------------------
//
// Used to prove the "cannot drain the maker" and rounding-direction properties.
// KEVM's int-simplification covers `(A *Int B) /Int A => B` and friends, but not these
// bounds with a symbolic divisor.

// Soundness: floor(A / B) * B <= A for B > 0, by definition of floor division.
    rule [div-mul-le]:
      (A /Int B) *Int B <=Int A => true
      requires 0 <=Int A
       andBool 0 <Int B
      [simplification, preserves-definedness]

// Soundness: for B >= 1 and A >= 0, floor(A / B) <= A.
    rule [div-le-self]:
      A /Int B <=Int A => true
      requires 0 <=Int A
       andBool 0 <Int B
      [simplification, preserves-definedness]

// Soundness: floor division is monotone in its numerator for a fixed positive divisor.
    rule [div-monotonic]:
      A /Int B <=Int C /Int B => true
      requires 0 <=Int A
       andBool A <=Int C
       andBool 0 <Int B
      [simplification, preserves-definedness]

// Soundness: if A < B then floor(A / B) = 0, for B > 0 and A >= 0.
    rule [div-lt-is-zero]:
      A /Int B => 0
      requires 0 <=Int A
       andBool A <Int B
      [simplification, preserves-definedness]

endmodule
