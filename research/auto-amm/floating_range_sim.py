#!/usr/bin/env python3
"""
Numeric evaluation of the "floating price range" AMM idea for Aqua / SwapVM.

The idea under test
-------------------
A concentrated-liquidity strategy whose price bounds always stay equidistant
from the current price (price 1000 -> range [900, 1100]; price 1050 ->
[950, 1150]), with a real rebalancing swap only after the price has moved more
than 50% since the last rebalance.

Pool model
----------
`ConcentratePool` is a float port of src/instructions/XYCConcentrate.sol:
liquidity L is *derived* from the current real balances and the (sqrt) price
bounds by solving the v3 invariant

    (x + L/b) * (y + L*a) = L^2 ,   a = sqrt(Pmin), b = sqrt(Pmax)

then the swap is a constant-product trade over the virtual reserves
(x + L/b, y + L*a). Fees stay in the pool (FlatFeeAmountIn semantics) so they
raise L on the next swap. x = tokenLt, y = tokenGt, P = y_virtual/x_virtual.

Recentering policies
--------------------
STATIC        bounds fixed forever (what SwapVM has today).
ALM           bounds fixed until the price leaves them, then recentre on the
              market and swap back to 50/50 (the Uniswap-v3 vault baseline).
FLOAT_SPOT    after every swap, bounds := [spot/k, spot*k] (the literal idea,
              applied once per swap).
FLOAT_FIX     the same rule iterated to its fixed point (the fully
              self-consistent "always centred" curve).
FLOAT_BUDGET  FLOAT_SPOT with the per-swap recentering step capped at
              (fee/2) * (trade size / reserve) — the largest step the fee
              income can pay for.
LAZY          bounds recentred on the *external* price only when the price has
              drifted out of a band, with the two half-widths chosen so the
              pool's implied price still equals the market price (no swap
              needed); a real rebalancing swap only when inventory skew crosses
              a threshold.

Run: python3 research/auto-amm/floating_range_sim.py
"""

from __future__ import annotations

import argparse
import json
import math
import os
import time
from dataclasses import dataclass

import numpy as np

# --------------------------------------------------------------------------- #
# Concentrated-liquidity math (float port of XYCConcentrate.sol)
# --------------------------------------------------------------------------- #


def liquidity_from_balances(x: float, y: float, a: float, b: float) -> float:
    """Solve (x + L/b)(y + L*a) = L^2 for L. Mirrors _computeL()."""
    if b <= a:
        raise ValueError("bad bounds")
    beta = x * a + y / b
    disc = beta * beta + 4.0 * (b - a) * x * y / b
    return (beta + math.sqrt(disc)) * b / (2.0 * (b - a))


def virtual_reserves(x: float, y: float, a: float, b: float) -> tuple[float, float]:
    L = liquidity_from_balances(x, y, a, b)
    return x + L / b, y + L * a


def spot_price(x: float, y: float, a: float, b: float) -> float:
    """Marginal price of tokenLt in tokenGt implied by balances + bounds."""
    vx, vy = virtual_reserves(x, y, a, b)
    if vx <= 0:
        return b * b
    return vy / vx


def amplification(k: float) -> float:
    """Depth multiplier vs a constant-product pool of equal capital.

    For bounds [p/k, p*k] and a 50/50 position, virtual reserves = A * real
    reserves with A = m/(m-1), m = sqrt(k).
    """
    m = math.sqrt(k)
    return m / (m - 1.0)


def balances_for(L: float, p: float, a: float, b: float) -> tuple[float, float]:
    s = math.sqrt(p)
    return L * (1.0 / s - 1.0 / b), L * (s - a)


# --------------------------------------------------------------------------- #
# Optimiser: robust to non-unimodal payoffs (inventory caps create kinks)
# --------------------------------------------------------------------------- #


def maximize(f, lo: float, hi: float, coarse: int = 40, refine: int = 40) -> tuple[float, float]:
    if hi <= lo or hi <= 0:
        return 0.0, 0.0
    grid = np.concatenate([[lo], np.logspace(math.log10(max(hi, 1e-30)) - 6, math.log10(hi), coarse)])
    vals = np.array([f(float(g)) for g in grid])
    i = int(np.argmax(vals))
    left = float(grid[max(0, i - 1)])
    right = float(grid[min(len(grid) - 1, i + 1)])
    invphi = (math.sqrt(5.0) - 1.0) / 2.0
    c, d = right - invphi * (right - left), left + invphi * (right - left)
    fc, fd = f(c), f(d)
    for _ in range(refine):
        if fc > fd:
            right, d, fd = d, c, fc
            c = right - invphi * (right - left)
            fc = f(c)
        else:
            left, c, fc = c, d, fd
            d = left + invphi * (right - left)
            fd = f(d)
    best_s, best_v = (c, fc) if fc > fd else (d, fd)
    if vals[i] > best_v:
        return float(grid[i]), float(vals[i])
    return best_s, best_v


# --------------------------------------------------------------------------- #
# Pools
# --------------------------------------------------------------------------- #


@dataclass
class Fills:
    fee_x: float = 0.0
    fee_y: float = 0.0
    volume_y: float = 0.0
    noise_volume_y: float = 0.0
    noise_desired_y: float = 0.0
    noise_saving_y: float = 0.0  # taker surplus vs the CEX, in y
    arb_volume_y: float = 0.0
    pump_volume_y: float = 0.0
    arb_profit_y: float = 0.0
    pump_profit_y: float = 0.0
    n_arbs: int = 0
    n_pumps: int = 0
    n_pump_checks: int = 0
    n_recenters: int = 0
    n_rebalance_swaps: int = 0
    rebalance_cost_y: float = 0.0
    illiquid_steps: int = 0
    markout_y: float = 0.0  # hedged PnL: value change from trading, marked at the market price


class ConcentratePool:
    """SwapVM XYCConcentrate plus a configurable recentering policy."""

    pumpable = True

    def __init__(
        self,
        x: float,
        y: float,
        k: float,
        fee: float,
        policy: str = "STATIC",
        band: float = 0.05,
        skew_trigger: float = 0.5,
        rebalance_cost: float = 0.0005,
        name: str = "",
    ):
        self.x, self.y = x, y
        self.k = k
        self.fee = fee
        self.policy = policy
        self.band = band
        self.skew_trigger = skew_trigger
        self.rebalance_cost = rebalance_cost
        self.name = name or policy
        p0 = y / x
        self.a = math.sqrt(p0 / k)
        self.b = math.sqrt(p0 * k)
        self.f = Fills()
        self.pumpable = policy in ("FLOAT_SPOT", "FLOAT_FIX", "FLOAT_BUDGET")

    # ---- state ------------------------------------------------------------ #

    def spot(self) -> float:
        return spot_price(self.x, self.y, self.a, self.b)

    def value(self, p: float) -> float:
        return self.x * p + self.y

    def weight_x(self, p: float) -> float:
        return self.x * p / self.value(p)

    def center(self) -> float:
        return self.a * self.b

    def snapshot(self):
        return (self.x, self.y, self.a, self.b)

    def restore(self, snap) -> None:
        self.x, self.y, self.a, self.b = snap

    # ---- quoting ---------------------------------------------------------- #

    def quote(self, side: str, amount_in: float) -> float:
        # only the OUTPUT side has to be funded: a pool that has run out of x
        # can still buy x, it just quotes one-sided
        if amount_in <= 0 or (self.x <= 0 and self.y <= 0):
            return 0.0
        if (side == "buy_x" and self.x <= 0) or (side == "sell_x" and self.y <= 0):
            return 0.0
        net = amount_in * (1.0 - self.fee)
        vx, vy = virtual_reserves(self.x, self.y, self.a, self.b)
        if side == "buy_x":
            return min(net * vx / (vy + net), self.x)
        return min(net * vy / (vx + net), self.y)

    def capacity(self, side: str, p: float, tol: float) -> float:
        """Largest input whose *average* price still beats p*(1 +/- tol).

        Closed form, so routing costs no search: at the limit size the average
        price equals the limit exactly.
        """
        if self.x <= 0 and self.y <= 0:
            return 0.0
        if (side == "buy_x" and self.x <= 0) or (side == "sell_x" and self.y <= 0):
            return 0.0
        g = 1.0 - self.fee
        vx, vy = virtual_reserves(self.x, self.y, self.a, self.b)
        if side == "buy_x":
            lim = (g * vx * p * (1.0 + tol) - vy) / g
            inv = self.x * vy / (g * (vx - self.x)) if vx > self.x else float("inf")
        else:
            lim = (g * vy / (p * (1.0 - tol)) - vx) / g
            inv = self.y * vx / (g * (vy - self.y)) if vy > self.y else float("inf")
        return max(min(lim, inv), 0.0)

    def swap(self, side: str, amount_in: float) -> float:
        out = self.quote(side, amount_in)
        if out <= 0:
            return 0.0
        if side == "buy_x":
            u = 1.0 if self.y <= amount_in else amount_in / self.y
            self.y += amount_in
            self.x -= out
            self.f.fee_y += amount_in * self.fee
        else:
            u = 1.0 if self.x <= amount_in else amount_in / self.x
            self.x += amount_in
            self.y -= out
            self.f.fee_x += amount_in * self.fee
        self._recenter_after_swap(u)
        return out

    # ---- recentering ------------------------------------------------------ #

    def _set_symmetric(self, p: float) -> None:
        self.a = math.sqrt(p / self.k)
        self.b = math.sqrt(p * self.k)

    def _recenter_after_swap(self, u: float) -> None:
        if self.x <= 0 or self.y <= 0:
            return
        if self.policy == "FLOAT_SPOT":
            self._set_symmetric(self.spot())
            self.f.n_recenters += 1
        elif self.policy == "FLOAT_FIX":
            for _ in range(400):
                p_old = self.center()
                self._set_symmetric(self.spot())
                if not math.isfinite(self.center()) or self.center() <= 0:
                    return
                if abs(math.log(self.center() / p_old)) < 1e-14:
                    break
            self.f.n_recenters += 1
        elif self.policy == "FLOAT_BUDGET":
            # only move the centre as far as this trade's fee can pay for
            cap = 0.5 * self.fee * min(u, 1.0)
            target = self.spot()
            cur = self.center()
            step = math.log(target / cur)
            step = max(-cap, min(cap, step))
            self._set_symmetric(cur * math.exp(step))
            self.f.n_recenters += 1

    def recenter_on_market(self, p_mkt: float) -> None:
        """Recentre on an external price with no swap and no price jump.

        The total width b/a = k is preserved, but the split between the two
        half-widths is taken from the inventory so the implied price still
        equals p_mkt exactly. With s = sqrt(p_mkt), rho = (y/x)/p_mkt and
        b = s*z, a = b/k, the requirement y/x = s*b*(s-a)/(b-s) becomes
            z*(k - z) = rho*k*(z - 1)
        whose positive root is
            z = [ k*(1-rho) + sqrt(k^2*(1-rho)^2 + 4*rho*k) ] / 2 ,
        and z lies in (1, k) for every rho > 0 - so an exact solution exists for
        ANY inventory. rho = 1 gives z = sqrt(k), the symmetric range.
        """
        s, k = math.sqrt(p_mkt), self.k
        self.f.n_recenters += 1
        if self.x <= 0 and self.y <= 0:
            self._set_symmetric(p_mkt)
            return
        if self.x <= 0:  # all y: price sits at the upper bound, bid-only ladder
            self.b, self.a = s, s / k
            return
        if self.y <= 0:  # all x: price sits at the lower bound, ask-only ladder
            self.a, self.b = s, s * k
            return
        rho = (self.y / self.x) / p_mkt
        z = 0.5 * (k * (1.0 - rho) + math.sqrt(k * k * (1.0 - rho) ** 2 + 4.0 * rho * k))
        z = min(max(z, 1.0 + 1e-15), k - 1e-15)
        self.b = s * z
        self.a = self.b / k

    def range_skew(self) -> float:
        """Where the price sits inside the range: 0.5 = centred, 0/1 = at a bound."""
        s = self.spot() ** 0.5
        return math.log(self.b / s) / math.log(self.b / self.a)

    def rebalance_swap(self, p_mkt: float) -> None:
        v = self.value(p_mkt)
        target_x = 0.5 * v / p_mkt
        cost = abs(target_x - self.x) * p_mkt * self.rebalance_cost
        self.x = target_x
        self.y = 0.5 * v - cost
        self.f.n_rebalance_swaps += 1
        self.f.rebalance_cost_y += cost

    def maintain(self, p_mkt: float) -> None:
        if self.policy == "LAZY":
            skew = abs(self.weight_x(p_mkt) - 0.5) * 2.0
            if skew > self.skew_trigger:
                self.rebalance_swap(p_mkt)
                self._set_symmetric(p_mkt)
                self.f.n_recenters += 1
            elif abs(math.log(p_mkt / self.center())) > self.band:
                self.recenter_on_market(p_mkt)
        elif self.policy == "ALM":
            if not (self.a**2 < p_mkt < self.b**2):
                self.rebalance_swap(p_mkt)
                self._set_symmetric(p_mkt)
                self.f.n_recenters += 1


class CPMMPool:
    """Uniswap-v2 benchmark with the same interface."""

    pumpable = False

    def __init__(self, x: float, y: float, fee: float, name: str = "v2"):
        self.x, self.y, self.fee, self.name = x, y, fee, name
        self.f = Fills()
        self.policy = "V2"
        self.k = 1.0

    def spot(self) -> float:
        return self.y / self.x

    def value(self, p: float) -> float:
        return self.x * p + self.y

    def weight_x(self, p: float) -> float:
        return self.x * p / self.value(p)

    def center(self) -> float:
        return self.spot()

    def snapshot(self):
        return (self.x, self.y)

    def restore(self, snap) -> None:
        self.x, self.y = snap

    def quote(self, side: str, amount_in: float) -> float:
        if amount_in <= 0:
            return 0.0
        net = amount_in * (1.0 - self.fee)
        if side == "buy_x":
            return net * self.x / (self.y + net)
        return net * self.y / (self.x + net)

    def capacity(self, side: str, p: float, tol: float) -> float:
        g = 1.0 - self.fee
        if side == "buy_x":
            return max((g * self.x * p * (1.0 + tol) - self.y) / g, 0.0)
        return max((g * self.y / (p * (1.0 - tol)) - self.x) / g, 0.0)

    def swap(self, side: str, amount_in: float) -> float:
        out = self.quote(side, amount_in)
        if out <= 0:
            return 0.0
        if side == "buy_x":
            self.y += amount_in
            self.x -= out
            self.f.fee_y += amount_in * self.fee
        else:
            self.x += amount_in
            self.y -= out
            self.f.fee_x += amount_in * self.fee
        return out

    def maintain(self, p_mkt: float) -> None:
        return


# --------------------------------------------------------------------------- #
# Agents
# --------------------------------------------------------------------------- #


def arbitrage(pool, p_mkt: float, min_profit: float = 0.0) -> float:
    """Execute the profit-maximising arbitrage. Returns the profit in y."""
    if pool.x <= 0 or pool.y <= 0:
        return 0.0
    # the arbitrageur's own capital is not the binding constraint: the input can
    # exceed the pool's balance of that token, only the output is capped
    if pool.spot() < p_mkt:
        side = "buy_x"
        cap = 5.0 * max(pool.y, pool.x * p_mkt)

        def profit(inp: float) -> float:
            return pool.quote(side, inp) * p_mkt - inp

    else:
        side = "sell_x"
        cap = 5.0 * max(pool.x, pool.y / p_mkt)

        def profit(inp: float) -> float:
            return pool.quote(side, inp) - inp * p_mkt

    size, best = maximize(profit, 0.0, cap)
    if best <= min_profit or size <= 0:
        return 0.0
    out = pool.swap(side, size)
    notional = size if side == "buy_x" else out * 1.0
    pool.f.arb_volume_y += notional
    pool.f.volume_y += notional
    pool.f.arb_profit_y += best
    pool.f.n_arbs += 1
    return best


def atomic_cycle(pool, p_mkt: float, min_profit: float = 0.0) -> float:
    """Best two-leg round trip against one pool inside one transaction.

    Leg 1 trades in, leg 2 immediately returns the exact amount received. On a
    conservative AMM this is always a loss (two fees). It can only pay if the
    pool moves its own quote in the direction of the incoming flow, i.e. if
    recentering acts as a momentum term.
    """
    # a round trip needs an executable output on both sides, so a pool already
    # drained to one side cannot be cycled any further
    scale = max(pool.x, pool.y / p_mkt)
    if pool.x <= 1e-9 * scale or pool.y <= 1e-9 * scale * p_mkt:
        return 0.0
    pool.f.n_pump_checks += 1

    def cycle(first: str, size: float) -> float:
        snap, f0 = pool.snapshot(), pool.f
        pool.f = Fills()
        try:
            got = pool.swap(first, size)
            if got <= 0:
                return -1e18
            back = pool.swap("sell_x" if first == "buy_x" else "buy_x", got)
            unit = p_mkt if first == "sell_x" else 1.0
            return (back - size) * unit
        finally:
            pool.restore(snap)
            pool.f = f0

    best = (None, 0.0, min_profit)
    for side in ("buy_x", "sell_x"):
        cap = (
            2.0 * max(pool.y, pool.x * p_mkt)
            if side == "buy_x"
            else 2.0 * max(pool.x, pool.y / p_mkt)
        )
        size, profit = maximize(lambda s: cycle(side, s), 0.0, cap)
        if profit > best[2]:
            best = (side, size, profit)
    side, size, profit = best
    if side is None or size <= 0:
        return 0.0
    got = pool.swap(side, size)
    back = pool.swap("sell_x" if side == "buy_x" else "buy_x", got)
    notional = size if side == "buy_x" else got
    pool.f.pump_volume_y += 2.0 * notional
    pool.f.volume_y += 2.0 * notional
    pool.f.pump_profit_y += profit
    pool.f.n_pumps += 1
    return profit


def noise_trade(pool, p_mkt: float, notional_y: float, buy_x: bool, tol: float) -> None:
    """Flow that routes between this pool and a next-best venue costing `tol`.

    It takes the largest slice whose average price still beats the alternative
    and sends the rest elsewhere, so deeper quotes win strictly more volume -
    the taker-side benefit the floating-range idea is aiming for.
    """
    pool.f.noise_desired_y += notional_y
    side = "buy_x" if buy_x else "sell_x"
    want = notional_y if buy_x else notional_y / p_mkt
    size = min(want, pool.capacity(side, p_mkt, tol))
    if size <= 0:
        return
    out = pool.swap(side, size)
    if out <= 0:
        return
    if buy_x:
        alt = size / (p_mkt * (1.0 + tol))  # x the taker would have got elsewhere
        saving = (out - alt) * p_mkt
        notional = size
    else:
        alt = size * p_mkt * (1.0 - tol)
        saving = out - alt
        notional = size * p_mkt
    pool.f.noise_volume_y += notional
    pool.f.volume_y += notional
    pool.f.noise_saving_y += max(saving, 0.0)


# --------------------------------------------------------------------------- #
# Experiment 1: sanity checks
# --------------------------------------------------------------------------- #


def experiment_sanity() -> list[str]:
    out = [
        "=" * 96,
        "1. SANITY CHECKS - the float model reproduces the XYCConcentrate / v3 algebra",
        "=" * 96,
    ]
    L, p, k = 1_000.0, 2_000.0, 1.1
    a, b = math.sqrt(p / k), math.sqrt(p * k)
    x, y = balances_for(L, p, a, b)
    L2 = liquidity_from_balances(x, y, a, b)
    s2 = spot_price(x, y, a, b)
    out.append(f"  L round trip:     {L:.6f} -> {L2:.6f}   (rel err {abs(L2 / L - 1):.2e})")
    out.append(f"  price round trip: {p:.6f} -> {s2:.6f}   (rel err {abs(s2 / p - 1):.2e})")
    out.append("")
    out.append("  A range symmetric around the current price forces y = P*x, i.e. exactly")
    out.append("  50/50 by value. The only curve with a constant 50/50 split is x*y=const,")
    out.append("  so the self-consistent 'always centred' AMM *is* Uniswap v2 - with the")
    out.append("  whole amplification A showing up inside a single trade only:")
    out.append("")
    out.append("    range       y/(P*x)   value in x    A (=virtual/real reserves)")
    for kk in (1.01, 1.1, 1.5, 2.0, 4.0):
        aa, bb = math.sqrt(p / kk), math.sqrt(p * kk)
        xx, yy = balances_for(1.0, p, aa, bb)
        vx, _ = virtual_reserves(xx, yy, aa, bb)
        out.append(
            f"    +/-{(kk - 1) * 100:5.1f}%   {yy / (p * xx):7.4f}   {xx * p / (xx * p + yy):9.4f}   "
            f"{amplification(kk):8.2f}x  (measured {vx / xx:8.2f}x)"
        )
    out.append("")
    out.append("  Recentering is a MOMENTUM term. After a buy, the balance ratio y/x moves")
    out.append("  ~A times further than the curve price does, so 'recentre on the current")
    out.append("  price' always pushes the quote further in the direction of the last trade:")
    out.append("")
    out.append("    range        A     trade      quote move on curve   extra move from recentring")
    for kk in (1.1, 1.5, 3.0):
        pool = ConcentratePool(1.0, p, kk, 0.0, policy="STATIC")
        p_before = pool.spot()
        pool.swap("buy_x", 0.01 * pool.y)
        p_curve = pool.spot()
        pool._set_symmetric(pool.spot())
        p_after = pool.spot()
        out.append(
            f"    +/-{(kk - 1) * 100:5.1f}%  {amplification(kk):6.2f}   buy 1% of y   "
            f"{math.log(p_curve / p_before) * 1e4:+9.2f} bps        "
            f"{math.log(p_after / p_curve) * 1e4:+9.2f} bps"
        )
    out.append("")
    out.append("  One application of 'bounds := [spot/k, spot*k]' closes ~1/A of the gap to")
    out.append("  the 50/50 price (theory: dP/P = (1/A) * gap):")
    out.append("")
    for kk in (1.1, 1.5, 2.0):
        pool = ConcentratePool(1.0, p, kk, 0.0, policy="STATIC")
        pool.x *= 0.8
        gap = math.log((pool.y / pool.x) / pool.spot())
        p_before = pool.spot()
        pool._set_symmetric(pool.spot())
        moved = math.log(pool.spot() / p_before)
        out.append(
            f"    +/-{(kk - 1) * 100:5.1f}%  A={amplification(kk):6.2f}   gap={gap:9.5f}  "
            f"moved={moved:9.5f}   moved/gap={moved / gap:7.4f}   1/A={1 / amplification(kk):7.4f}"
        )
    out.append("")
    out.append("  The self-consistent rule has NO bounded solution once one side is empty:")
    out.append("  P = y/x -> infinity as x -> 0, so an 'always centred' pool must quote an")
    out.append("  unbounded price when its inventory runs out.")
    out.append("")
    out.append("  Inventory-matched recentring: for ANY inventory there is an exact pair of")
    out.append("  bounds of the chosen width whose implied price equals the market price, so")
    out.append("  recentring never requires a swap and never has to jump the quote:")
    out.append("")
    out.append("    market drift   value in x   bounds after recentring        implied price error")
    base = ConcentratePool(1.0, p, 1.1, 0.0, policy="STATIC")
    for drift in (0.0, 0.03, -0.03, 0.08, -0.08, 0.25, -0.25):
        pool = ConcentratePool(base.x, base.y, 1.1, 0.0, policy="STATIC")
        p1 = p * (1 + drift)
        arbitrage(pool, p1)
        wx = pool.weight_x(p1)
        pool.recenter_on_market(p1)
        err = abs(pool.spot() / p1 - 1)
        out.append(
            f"    {drift * 100:+8.0f}%     {wx * 100:8.1f}%   [{pool.a ** 2:8.1f}, {pool.b ** 2:8.1f}]"
            f"  centre {pool.center():8.1f}      {err:.2e}"
        )
    return out


# --------------------------------------------------------------------------- #
# Experiment 2: the atomic money pump
# --------------------------------------------------------------------------- #


def experiment_pump() -> tuple[list[str], dict]:
    out = [
        "",
        "=" * 96,
        "2. ATOMIC ROUND TRIP (money pump), market price == pool price, no price move at all",
        "=" * 96,
        "  Best single-transaction 'trade in, trade straight back' profit, % of pool TVL.",
        "  Negative = the design is conservative, i.e. safe.",
        "",
    ]
    p0, tvl = 2_000.0, 2_000_000.0
    x0, y0 = tvl / (2 * p0), tvl / 2
    fees = [0.0, 0.0005, 0.003, 0.01, 0.05]
    ranges = [1.01, 1.1, 1.5, 3.0]
    data: dict = {}
    out.append("  policy          range      A  " + "".join(f"   fee={f * 100:5.2f}%" for f in fees))
    for policy in ("STATIC", "FLOAT_SPOT", "FLOAT_FIX", "FLOAT_BUDGET"):
        for k in ranges:
            row = []
            for fee in fees:
                pool = ConcentratePool(x0, y0, k, fee, policy=policy)
                profit = atomic_cycle(pool, p0, min_profit=-1e18)
                row.append(profit / tvl * 100)
                data[f"{policy}|{k}|{fee}"] = profit / tvl
            out.append(
                f"  {policy:<13s} +/-{(k - 1) * 100:5.1f}% {amplification(k):6.2f} "
                + "".join(f"  {v:+10.4f}%" for v in row)
            )
    out.append("")
    out.append("  FLOAT_FIX loses exactly half its TVL in ONE transaction: the attacker buys")
    out.append("  the whole x inventory at ~the marginal price, the quote runs away to")
    out.append("  infinity (x=0 => P=y/x=inf), and selling it back drains the entire y side.")
    out.append("")
    out.append("  Drain test - repeat the optimal cycle up to 400 times, fee 30bps, range +/-10%:")
    for policy in ("STATIC", "FLOAT_SPOT", "FLOAT_FIX", "FLOAT_BUDGET"):
        pool = ConcentratePool(x0, y0, 1.1, 0.003, policy=policy)
        v0 = pool.value(p0)
        for _ in range(400):
            if atomic_cycle(pool, p0) <= 0:
                break
        out.append(
            f"    {policy:<13s} {pool.f.n_pumps:4d} profitable cycles, LP value left "
            f"{pool.value(p0) / v0 * 100:8.3f}% of start, extracted {pool.f.pump_profit_y / v0 * 100:7.3f}% of TVL"
        )
        data[f"drain|{policy}"] = {
            "cycles": pool.f.n_pumps,
            "value_left": pool.value(p0) / v0,
            "extracted": pool.f.pump_profit_y / v0,
        }
    out.append("")
    out.append("  Break-even round-trip size for the pump. Theory: profit ~ TVL*u^2*theta and")
    out.append("  fee cost ~ TVL*u*fee, so the pump pays whenever u > fee/theta, theta ~ 1/A:")
    out.append("")
    for k in (1.1, 1.5, 3.0):
        A = amplification(k)
        for fee in (0.0005, 0.003):
            lo, hi = 1e-6, 0.85
            for _ in range(60):
                mid = math.sqrt(lo * hi)
                pl = ConcentratePool(x0, y0, k, fee, policy="FLOAT_SPOT")
                got = pl.swap("buy_x", mid * y0)
                if got > 0 and pl.swap("sell_x", got) - mid * y0 > 0:
                    hi = mid
                else:
                    lo = mid
            out.append(
                f"    +/-{(k - 1) * 100:5.1f}%  A={A:6.2f}  fee={fee * 100:5.3f}%   "
                f"break-even size = {hi * 100:7.3f}% of the y reserve   (fee*A = {fee * A * 100:6.3f}%)"
            )
    out.append("")
    out.append("  FLOAT_BUDGET caps the recentring step at (fee/2)*(size/reserve), which makes")
    out.append("  the pump unprofitable at every size. The price of safety is the tracking")
    out.append("  speed: the centre can only move (fee/2) per 100% of reserves traded, so")
    out.append("  following a 1% price move needs a turnover of:")
    for fee in (0.0005, 0.003):
        out.append(f"    fee={fee * 100:5.3f}%  ->  {2 * 0.01 / fee:8.1f}x the whole reserve per 1% of price move")
    return out, data


# --------------------------------------------------------------------------- #
# Experiment 3: analytic LVR / required turnover
# --------------------------------------------------------------------------- #


def experiment_lvr() -> list[str]:
    out = [
        "",
        "=" * 96,
        "3. THE PRICE OF NEVER LEAVING THE RANGE (analytic)",
        "=" * 96,
        "  LVR rate per unit of capital while in range = A * sigma^2 / 8",
        "  (Milionis-Moallemi-Roughgarden-Zhang 2022; A = depth amplification).",
        "  A static range stops bleeding when the price leaves it. A floating range never does.",
        "",
        "  annualised LVR, % of TVL per year",
    ]
    sigmas = [0.2, 0.4, 0.6, 1.0]
    out.append("    range          A   " + "".join(f"   sigma={s * 100:4.0f}%" for s in sigmas))
    for k in (1.01, 1.05, 1.1, 1.5, 2.0, 1e6):
        A = amplification(k)
        label = "v2 (full)" if k > 1e5 else f"+/-{(k - 1) * 100:5.1f}%"
        out.append(
            f"    {label:>9s} {A:10.2f}   " + "".join(f"    {A * s * s / 8 * 100:9.1f}%" for s in sigmas)
        )
    out.append("")
    out.append("  Noise turnover needed to pay for it, A*sigma^2/(8*fee), as multiples of TVL/day:")
    for fee in (0.0005, 0.003):
        out.append(f"    fee = {fee * 100:.2f}%")
        out.append("    range          A   " + "".join(f"   sigma={s * 100:4.0f}%" for s in sigmas))
        for k in (1.01, 1.1, 1.5, 1e6):
            A = amplification(k)
            label = "v2 (full)" if k > 1e5 else f"+/-{(k - 1) * 100:5.1f}%"
            out.append(
                f"    {label:>9s} {A:10.2f}   "
                + "".join(f"    {A * s * s / (8 * fee) / 365:9.2f}x" for s in sigmas)
            )
    return out


# --------------------------------------------------------------------------- #
# Experiment 4: market simulation
# --------------------------------------------------------------------------- #


@dataclass
class SimConfig:
    steps: int = 8_760
    sigma: float = 0.6
    mu: float = 0.0
    tvl: float = 2_000_000.0
    p0: float = 2_000.0
    fee: float = 0.0005
    # Effective cost of the taker's next-best venue. Also the slippage the flow
    # tolerates, so it sets how much volume depth can win. Calibrated (see
    # experiment_calibrate) so the industry ALM baseline is ~break-even on a
    # hedged basis, matching the empirical fees ~ 0.8-1.2x arbitrage losses for
    # major ETH pools (Fritsch & Canidio 2024).
    tolerance: float = 0.001
    # retail flow is specified per YEAR so results do not depend on the time
    # discretisation: each round is a buy and a sell, each filled up to the
    # pool's capacity at the taker's tolerance
    noise_rounds_per_year: float = 40_000.0
    noise_notional: float = 0.05  # desired notional per side per round, fraction of TVL
    noise_sigma: float = 0.8
    seeds: int = 8
    pump_check_every: int = 250

    @property
    def dt(self) -> float:
        return 1.0 / self.steps

    @property
    def rounds_per_step(self) -> float:
        return self.noise_rounds_per_year / self.steps


def make_pools(cfg: SimConfig) -> list:
    x0, y0 = cfg.tvl / (2 * cfg.p0), cfg.tvl / 2
    mk = lambda k, **kw: ConcentratePool(x0, y0, k, cfg.fee, **kw)
    return [
        CPMMPool(x0, y0, cfg.fee, name="v2 full range"),
        mk(1.1, policy="STATIC", name="static +/-10%"),
        mk(1.5, policy="STATIC", name="static +/-50%"),
        mk(1.1, policy="ALM", name="ALM +/-10% (recentre+swap on exit)"),
        mk(1.1, policy="FLOAT_SPOT", name="FLOAT +/-10% per swap"),
        mk(1.1, policy="FLOAT_FIX", name="FLOAT +/-10% self-consistent"),
        mk(1.5, policy="FLOAT_SPOT", name="FLOAT +/-50% per swap"),
        mk(1.1, policy="FLOAT_BUDGET", name="FLOAT +/-10% fee-budgeted"),
        mk(1.1, policy="LAZY", band=0.05, skew_trigger=0.5, name="LAZY +/-10% band 5%, swap at 50% skew"),
        mk(1.1, policy="LAZY", band=0.05, skew_trigger=0.2, name="LAZY +/-10% band 5%, swap at 20% skew"),
        mk(1.5, policy="LAZY", band=0.10, skew_trigger=0.2, name="LAZY +/-50% band 10%, swap at 20% skew"),
    ]


def run_path(cfg: SimConfig, prices: np.ndarray, rng: np.random.Generator, pump: bool, factory=None) -> dict:
    pools = (factory or make_pools)(cfg)
    series: dict[str, list] = {p.name: [] for p in pools}
    rate = cfg.rounds_per_step
    for t in range(1, len(prices)):
        p = prices[t]
        # retail flow arrives in rounds; each round has a buy and a sell, so
        # opposite-direction flow keeps restoring the price and the pool can
        # capture much more than a single round's depth
        nr = int(rng.poisson(rate))
        sizes = cfg.noise_notional * cfg.tvl * np.exp(rng.normal(0, cfg.noise_sigma, (nr, 2)))
        buy_first = rng.random(max(nr, 1)) < 0.5
        for pool in pools:
            if pool.x <= 1e-9 or pool.y <= 1e-9:
                pool.f.illiquid_steps += 1  # one-sided: still quotes, but only one way
            # everything below happens at the same external price p, so the
            # value change across the step is exactly the hedged (delta-neutral)
            # PnL: fees minus everything the counterparties took.
            v_pre = pool.value(p)
            pool.maintain(p)
            if pool.x > 0 or pool.y > 0:
                arbitrage(pool, p)
                if pump and (pool.pumpable or t % cfg.pump_check_every == 0):
                    for _ in range(4):
                        if atomic_cycle(pool, p) <= 0:
                            break
                for r in range(nr):
                    first = bool(buy_first[r])
                    noise_trade(pool, p, float(sizes[r, 0]), first, cfg.tolerance)
                    noise_trade(pool, p, float(sizes[r, 1]), not first, cfg.tolerance)
            pool.f.markout_y += pool.value(p) - v_pre
            # cumulative hedged PnL: path-independent, so the curves are
            # comparable across strategies and across price paths
            series[pool.name].append(pool.f.markout_y / cfg.tvl * 100.0)
    pf = prices[-1]
    hodl = cfg.tvl / 2 / cfg.p0 * pf + cfg.tvl / 2
    res = {}
    for pool in pools:
        v = pool.value(pf)
        res[pool.name] = {
            "value": v,
            "vs_hodl": v / hodl - 1,
            "fees_y": pool.f.fee_y + pool.f.fee_x * pf,
            "volume_y": pool.f.volume_y,
            "noise_volume_y": pool.f.noise_volume_y,
            "noise_desired_y": pool.f.noise_desired_y,
            "noise_saving_y": pool.f.noise_saving_y,
            "arb_profit_y": pool.f.arb_profit_y,
            "pump_profit_y": pool.f.pump_profit_y,
            "n_pumps": pool.f.n_pumps,
            "n_recenters": pool.f.n_recenters,
            "n_rebalance_swaps": pool.f.n_rebalance_swaps,
            "rebalance_cost_y": pool.f.rebalance_cost_y,
            "illiquid_steps": pool.f.illiquid_steps,
            "markout_y": pool.f.markout_y,
            "series": series[pool.name],
        }
    res["_hodl"] = {"value": hodl}
    return res


def summarise(cfg: SimConfig, agg: dict) -> list[dict]:
    rows = []
    for name, runs in agg.items():
        if name.startswith("_"):
            continue
        m = lambda key: float(np.mean([r[key] for r in runs]))
        rows.append(
            {
                "name": name,
                "hedged": m("markout_y") / cfg.tvl * 100,
                "hedged_worst": float(np.min([r["markout_y"] for r in runs])) / cfg.tvl * 100,
                "vs_hodl_med": float(np.median([r["vs_hodl"] for r in runs])) * 100,
                "vs_hodl_worst": float(np.min([r["vs_hodl"] for r in runs])) * 100,
                "fees": m("fees_y") / cfg.tvl * 100,
                "arb": m("arb_profit_y") / cfg.tvl * 100,
                "pump": m("pump_profit_y") / cfg.tvl * 100,
                "noise_vol": m("noise_volume_y") / cfg.tvl,
                "captured": m("noise_volume_y") / max(m("noise_desired_y"), 1e-9) * 100,
                "saving": m("noise_saving_y") / cfg.tvl * 100,
                "swaps": m("n_rebalance_swaps"),
                "reb_cost": m("rebalance_cost_y") / cfg.tvl * 100,
                "recentres": m("n_recenters"),
                "illiq": m("illiquid_steps") / cfg.steps * 100,
            }
        )
    return rows


def print_rows(rows: list[dict]) -> list[str]:
    out = [
        "  strategy                                   hedged    worst  vsHODL     fees      arb"
        "     pump  noise$  capt%  takerW  swaps  illiq%",
    ]
    for r in rows:
        out.append(
            f"  {r['name']:<40s} {r['hedged']:+7.1f}% {r['hedged_worst']:+7.1f}% {r['vs_hodl_med']:+7.1f}%"
            f" {r['fees']:7.1f}% {r['arb']:8.1f}% {r['pump']:8.1f}% {r['noise_vol']:6.0f}x"
            f" {r['captured']:5.1f}% {r['saving']:6.2f}% {r['swaps']:6.0f} {r['illiq']:6.1f}%"
        )
    return out


def experiment_recenter_cost() -> list[str]:
    """What one maker-triggered recentring costs, symmetric vs inventory-matched."""
    out = [
        "",
        "=" * 96,
        "3c. COST OF ONE MAKER-TRIGGERED RECENTRING (no swap), range +/-10%, fee 5bps",
        "=" * 96,
        "  The market drifts, arbitrageurs drag the pool price to the market, the inventory",
        "  ends up skewed, and only then does the maker move the bounds. The 'gift' is what",
        "  arbitrageurs take immediately after the bounds move, % of TVL.",
        "",
        "    drift   value in x   symmetric bounds   inventory-matched   real swap to 50/50",
    ]
    p0, tvl = 2_000.0, 2_000_000.0
    x0, y0 = tvl / (2 * p0), tvl / 2
    for drift in (0.02, 0.05, 0.10, 0.20, 0.50, -0.20, -0.50):
        p1 = p0 * (1 + drift)
        base = ConcentratePool(x0, y0, 1.1, 0.0005, policy="STATIC")
        arbitrage(base, p1)
        wx = base.weight_x(p1)
        costs = []
        for mode in ("sym", "asym", "swap"):
            pool = ConcentratePool(x0, y0, 1.1, 0.0005, policy="STATIC")
            pool.x, pool.y = base.x, base.y
            pool.a, pool.b = base.a, base.b
            v0 = pool.value(p1)
            if mode == "sym":
                pool._set_symmetric(p1)
            elif mode == "asym":
                pool.recenter_on_market(p1)
            else:
                pool.rebalance_swap(p1)
                pool._set_symmetric(p1)
            arbitrage(pool, p1)
            costs.append((v0 - pool.value(p1)) / tvl * 100)
        out.append(
            f"    {drift * 100:+5.0f}%   {wx * 100:8.1f}%      {costs[0]:8.3f}%          {costs[1]:8.3f}%"
            f"            {costs[2]:8.3f}%"
        )
    out.append("")
    out.append("  'real swap to 50/50' includes a 5bps execution cost on the swapped amount.")
    out.append("  Symmetric recentring leaves the implied price ~1/A of the inventory skew away")
    out.append("  from the market, so its gift is ~TVL*skew^2/(8A) - small, but pure loss.")
    out.append("  Inventory-matched recentring costs nothing at all and still needs no swap.")
    return out


def gbm(cfg: SimConfig, seed: int) -> np.ndarray:
    rng = np.random.default_rng(1_000 + seed)
    incr = (cfg.mu - 0.5 * cfg.sigma**2) * cfg.dt + cfg.sigma * math.sqrt(cfg.dt) * rng.normal(
        size=cfg.steps
    )
    return cfg.p0 * np.exp(np.concatenate([[0.0], np.cumsum(incr)])), rng


def experiment_calibrate(cfg: SimConfig) -> list[str]:
    """Pick the taker tolerance that makes the industry baseline ~break even.

    Fritsch & Canidio (2024) measure fees ~= 0.8-1.2x simulated arbitrage losses
    for the major Uniswap ETH pools, i.e. a real ALM position is roughly break
    even on a hedged basis. We calibrate the price-insensitivity of the noise
    flow to reproduce that, so every other row is measured against a realistic
    baseline instead of an arbitrary one.
    """
    out = [
        "",
        "=" * 96,
        "3b. FLOW CALIBRATION - taker price-insensitivity vs the empirical fees/LVR ratio",
        "=" * 96,
        f"  short run: {cfg.steps} steps, {cfg.seeds} paths, sigma={cfg.sigma * 100:.0f}%/yr, fee={cfg.fee * 1e4:.0f}bps",
        "",
        "  tol  rounds/yr  pool                        fees      arb   fees/arb   hedged   volume",
    ]

    def factory(c: SimConfig) -> list:
        x0, y0 = c.tvl / (2 * c.p0), c.tvl / 2
        return [
            CPMMPool(x0, y0, c.fee, name="v2 full range"),
            ConcentratePool(x0, y0, 1.1, c.fee, policy="ALM", name="ALM +/-10%"),
        ]

    for tol, rpy in ((0.001, 10_000), (0.001, 20_000), (0.001, 40_000), (0.001, 80_000), (0.002, 40_000)):
        c = SimConfig(**{**cfg.__dict__, "tolerance": tol, "noise_rounds_per_year": rpy})
        agg: dict[str, list] = {}
        for seed in range(cfg.seeds):
            prices, rng = gbm(c, seed)
            res = run_path(c, prices, rng, pump=False, factory=factory)
            for name, r in res.items():
                agg.setdefault(name, []).append(r)
        for name, runs in agg.items():
            if name.startswith("_"):
                continue
            fees = float(np.mean([r["fees_y"] for r in runs])) / c.tvl * 100
            arb = float(np.mean([r["arb_profit_y"] for r in runs])) / c.tvl * 100
            hedged = float(np.mean([r["markout_y"] for r in runs])) / c.tvl * 100
            vol = float(np.mean([r["noise_volume_y"] for r in runs])) / c.tvl
            out.append(
                f"  {tol * 1e4:2.0f}bps {rpy:>9,d}  {name:<26s} {fees:7.1f}% {arb:8.1f}%   "
                f"{fees / max(arb, 1e-9):7.2f}x {hedged:+8.1f}% {vol:7.0f}x"
            )
    out.append("")
    out.append(
        f"  -> the market simulation below uses tolerance = {cfg.tolerance * 1e4:.0f}bps, "
        f"{cfg.noise_rounds_per_year:,.0f} rounds/year."
    )
    return out


def experiment_market(cfg: SimConfig) -> tuple[list[str], dict]:
    out = [
        "",
        "=" * 96,
        "4. MARKET SIMULATION - GBM + arbitrageurs + optimally routed noise flow",
        "=" * 96,
        f"  {cfg.steps} hourly steps (1 year), sigma={cfg.sigma * 100:.0f}%/yr, fee={cfg.fee * 1e4:.0f}bps, "
        f"taker tolerance={cfg.tolerance * 1e4:.0f}bps, TVL=${cfg.tvl / 1e6:.1f}M",
        f"  flow: {cfg.noise_rounds_per_year:,.0f} buy/sell rounds per year "
        f"({cfg.rounds_per_step:.1f}/step), up to {cfg.noise_notional * 100:.1f}% of TVL per side per round, "
        f"{cfg.seeds} price paths",
        "",
    ]
    data: dict = {}
    for pump in (True, False):
        agg: dict[str, list] = {}
        series_store: dict[str, list] = {}
        first_price = None
        for seed in range(cfg.seeds):
            prices, rng = gbm(cfg, seed)
            if seed == 0:
                first_price = prices
            res = run_path(cfg, prices, rng, pump)
            for name, r in res.items():
                agg.setdefault(name, []).append(r)
                if seed == 0 and "series" in r:
                    series_store[name] = r["series"]
        rows = summarise(cfg, agg)
        title = (
            "  (a) WITH the atomic-cycle bot running (what actually happens on-chain)"
            if pump
            else "  (b) WITHOUT the atomic-cycle bot (hypothetical: exploit magically fixed)"
        )
        out.append(title)
        out += print_rows(rows)
        out.append("")
        data["with_pump" if pump else "no_pump"] = rows
        if pump:
            data["series_pump"] = series_store
            data["price"] = first_price.tolist()
        else:
            data["series_nopump"] = series_store
    out += [
        "  hedged / worst : delta-hedged LP PnL = fees minus everything the counterparties took,",
        "                   % of initial TVL per year (mean / worst path). This is the",
        "                   path-independent market-making result; 0% = break even.",
        "  vsHODL         : median LP value vs holding the initial 50/50 basket (path-dependent)",
        "  fees           : fees earned, % of initial TVL",
        "  arb            : value taken by price arbitrageurs, % of initial TVL",
        "  pump           : value taken by the atomic round-trip bot, % of initial TVL",
        "  noise$         : noise notional captured, in multiples of TVL per year",
        "  capt%          : share of the desired noise flow the pool won from the next-best venue",
        "  takerW         : taker surplus vs the next-best venue, % of TVL (the takers' gain)",
        "  swaps          : real rebalancing swaps executed",
        "  illiq%         : share of steps with one side of the inventory empty",
    ]
    return out, data


# --------------------------------------------------------------------------- #
# Charts
# --------------------------------------------------------------------------- #


def make_charts(market: dict, cfg: SimConfig, outdir: str) -> list[str]:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    files = []
    p0, tvl = 2_000.0, 2_000_000.0
    x0, y0 = tvl / (2 * p0), tvl / 2

    # ---- chart 1: atomic cycle profit vs size
    fig, ax = plt.subplots(figsize=(9.5, 5.4))
    sizes = np.logspace(-4, math.log10(0.85), 110)
    styles = [
        ("STATIC", "#1f77b4", "-", 2.0, "static range (SwapVM today) - always a loss"),
        ("FLOAT_SPOT", "#d62728", "-", 2.0, "floating range, recentred once per swap"),
        ("FLOAT_FIX", "#8c564b", "--", 2.0, "floating range, self-consistent"),
        ("FLOAT_BUDGET", "#2ca02c", ":", 2.6, "floating range, recentring capped by the fee"),
    ]
    for policy, c, ls, lw, label in styles:
        prof = []
        for u in sizes:
            pool = ConcentratePool(x0, y0, 1.1, 0.003, policy=policy)
            got = pool.swap("buy_x", u * y0)
            back = pool.swap("sell_x", got) if got > 0 else 0.0
            prof.append((back - u * y0) / tvl * 1e4)
        ax.plot(sizes * 100, prof, color=c, ls=ls, lw=lw, label=label)
    ax.axhline(0, color="k", lw=0.9)
    ax.set_xscale("log")
    ax.set_yscale("symlog", linthresh=1.0)
    ax.set_xlabel("round-trip size, % of the y reserve")
    ax.set_ylabel("attacker profit, bps of TVL (symlog)")
    ax.set_title(
        "One transaction: trade in, trade straight back. Range +/-10%, fee 30bps.\n"
        "Market price equals the pool price - no external price move whatsoever."
    )
    ax.axvline(6.78, color="#d62728", lw=0.8, ls="--", alpha=0.6)
    ax.annotate(
        "pump breaks even at fee*A = 6.8%",
        xy=(6.78, 0.0),
        xytext=(0.05, 60),
        fontsize=8.5,
        color="#d62728",
        arrowprops=dict(arrowstyle="->", color="#d62728", lw=0.8),
    )
    ax.legend(loc="lower left", fontsize=9, framealpha=0.95)
    ax.grid(alpha=0.3, which="both")
    ax.set_ylim(-60, 4000)
    f1 = os.path.join(outdir, "chart1_atomic_cycle.png")
    fig.tight_layout()
    fig.savefig(f1, dpi=140)
    plt.close(fig)
    files.append(f1)

    # ---- chart 2: cumulative hedged PnL, with and without the bot
    fig, axes = plt.subplots(1, 2, figsize=(14, 5.8), sharey=True)
    order = [
        ("v2 full range", "#1f77b4", "-"),
        ("static +/-10%", "#2ca02c", "-"),
        ("ALM +/-10% (recentre+swap on exit)", "#ff7f0e", "-"),
        ("LAZY +/-50% band 10%, swap at 20% skew", "#9467bd", "-"),
        ("FLOAT +/-10% fee-budgeted", "#17becf", "-"),
        ("FLOAT +/-10% per swap", "#d62728", "-"),
        ("FLOAT +/-10% self-consistent", "#8c564b", "--"),
    ]
    for ax, key, title in (
        (axes[0], "series_pump", "(a) with the atomic-cycle bot - what happens on-chain"),
        (axes[1], "series_nopump", "(b) bot disabled - the leak just moves to ordinary takers"),
    ):
        s = market[key]
        ax.axhline(0, color="k", lw=1.0, ls=":")
        for name, c, ls in order:
            if name in s:
                ax.plot(np.array(s[name]), color=c, ls=ls, lw=1.6, label=name)
        ax.set_xlabel("hours")
        ax.set_title(title, fontsize=10)
        ax.grid(alpha=0.3)
        ax.set_ylim(-110, 30)
    axes[0].set_ylabel("cumulative delta-hedged LP PnL, % of TVL")
    axes[0].legend(fontsize=8, loc="center left", framealpha=0.95)
    fig.suptitle(
        f"One GBM year, sigma={cfg.sigma * 100:.0f}%/yr, fee={cfg.fee * 1e4:.0f}bps, arbitrageurs + "
        "routed retail flow. Hedged PnL = fees minus everything counterparties took.",
        y=0.99,
        fontsize=10.5,
    )
    f2 = os.path.join(outdir, "chart2_lp_value_paths.png")
    fig.tight_layout()
    fig.savefig(f2, dpi=140)
    plt.close(fig)
    files.append(f2)

    # ---- chart 3: LVR vs range width + break-even turnover
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12.5, 4.8))
    ks = np.linspace(1.004, 3.0, 400)
    As = np.array([amplification(k) for k in ks])
    for s, c in ((0.4, "#1f77b4"), (0.6, "#ff7f0e"), (1.0, "#d62728")):
        ax1.plot((ks - 1) * 100, As * s * s / 8 * 100, color=c, lw=2, label=f"sigma={s * 100:.0f}%/yr")
    ax1.axhline(100, color="k", lw=0.9, ls=":")
    ax1.text(120, 115, "100% of TVL per year", fontsize=8)
    ax1.set_xlabel("range half-width, %")
    ax1.set_ylabel("LVR, % of TVL per year")
    ax1.set_title("Cost of a permanently in-range position\nLVR = A(k) * sigma^2 / 8")
    ax1.set_yscale("log")
    ax1.legend(fontsize=9)
    ax1.grid(alpha=0.3)
    for fee, c in ((0.0005, "#1f77b4"), (0.003, "#2ca02c"), (0.01, "#d62728")):
        ax2.plot((ks - 1) * 100, As * 0.6**2 / (8 * fee) / 365, color=c, lw=2, label=f"fee={fee * 1e4:.0f}bps")
    ax2.set_xlabel("range half-width, %")
    ax2.set_ylabel("required noise turnover, x TVL per day")
    ax2.set_title("Noise volume needed to break even\nsigma=60%/yr")
    ax2.set_yscale("log")
    ax2.legend(fontsize=9)
    ax2.grid(alpha=0.3)
    f3 = os.path.join(outdir, "chart3_lvr_and_breakeven.png")
    fig.tight_layout()
    fig.savefig(f3, dpi=140)
    plt.close(fig)
    files.append(f3)
    return files


# --------------------------------------------------------------------------- #


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--steps", type=int, default=8_760)
    ap.add_argument("--seeds", type=int, default=8)
    ap.add_argument("--sigma", type=float, default=0.6)
    ap.add_argument("--fee", type=float, default=0.0005)
    ap.add_argument("--tolerance", type=float, default=0.001)
    ap.add_argument("--no-charts", action="store_true")
    ap.add_argument("--no-market", action="store_true")
    ap.add_argument("--no-calibrate", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    t0 = time.time()
    cfg = SimConfig(
        steps=args.steps, seeds=args.seeds, sigma=args.sigma, fee=args.fee, tolerance=args.tolerance
    )
    lines = experiment_sanity()
    pump_lines, pump_data = experiment_pump()
    lines += pump_lines
    lines += experiment_lvr()
    if not args.no_calibrate:
        lines += experiment_calibrate(SimConfig(**{**cfg.__dict__, "seeds": min(cfg.seeds, 3)}))
    lines += experiment_recenter_cost()
    market_data: dict = {}
    if not args.no_market:
        market_lines, market_data = experiment_market(cfg)
        lines += market_lines
    lines.append("")
    lines.append(f"(generated by research/auto-amm/floating_range_sim.py in {time.time() - t0:.0f}s)")
    report = "\n".join(lines)
    print(report)
    with open(os.path.join(args.outdir, "sim_results.txt"), "w") as fh:
        fh.write(report + "\n")
    with open(os.path.join(args.outdir, "sim_results.json"), "w") as fh:
        json.dump(
            {
                "pump": pump_data,
                "market_with_pump": market_data.get("with_pump"),
                "market_no_pump": market_data.get("no_pump"),
            },
            fh,
            indent=2,
        )
    if not args.no_charts and market_data:
        files = make_charts(market_data, cfg, args.outdir)
        print("\ncharts: " + ", ".join(files))


if __name__ == "__main__":
    main()
