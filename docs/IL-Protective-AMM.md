# IL-Aware AMM with Dynamic Fees, Liquidity Density Control, and Moving Anchor

## Abstract

We propose an **IL-aware automated market maker (AMM)** that combines three mechanisms into a single adaptive liquidity design:

1. a **theoretical IL-compensating fee curve** derived from local divergence loss,
2. a **capped practical fee schedule** based on that theoretical benchmark, and
3. a **liquidity density control layer** that reduces effective liquidity when fee-based protection becomes insufficient.

The design is centered around a **moving anchor price**, defined as a geometric exponentially weighted moving average (EMA) in log-price space. Liquidity is concentrated around this anchor and gradually recenters if the market stabilizes at a new regime.

The goal of the construction is **not** to eliminate impermanent loss (IL), which is fundamentally unavoidable in constant-function market making. Instead, the goal is to convert the impossible objective of complete IL neutralization into a practical control problem over the fee extraction, liquidity exposure and adaptive re-centering.

The resulting mechanism behaves as an **inventory-aware, risk-adaptive AMM**: it charges more for trades that push price further away from the current equilibrium estimate, provides less effective depth when compensation is insufficient, and slowly restores normal liquidity when the market settles into a new price regime.

---

## 1. Introduction

Impermanent loss is one of the defining trade-offs of AMM-based liquidity provision. In a standard constant-product pool, the LP continuously rebalances inventory against price movements: when the price of the base asset rises, the pool sells base into quote; when the price falls, the pool buys base back. Relative to passive holding, this induces a convexity cost. The LP systematically gives up upside in trending markets and accumulates additional downside exposure when markets move sharply in the opposite direction.

This effect is not an implementation artifact. It is a structural property of AMM liquidity provision. In that sense, IL is not a bug that can simply be removed by choosing better parameters; it is the cost of supplying continuous on-chain liquidity through an automatic pricing rule.

A natural first idea is to compensate IL with fees. If divergence from the reference price increases LP losses, then harmful order flow should be charged more. This logic is correct, but incomplete. A fully compensating fee schedule exists only as a **theoretical object**. In practice, the required fee becomes prohibitively large: far from equilibrium it can exceed any commercially viable level, making pure fee-based protection unrealistic.

This motivates the central idea of this paper:

> If IL cannot be fully neutralized by charging more for flow, then the protocol must also control how much liquidity is exposed to that flow.

The construction developed below combines **price-of-risk control** and **quantity-of-risk control**. The first is implemented through a dynamic fee benchmark derived from local IL growth. The second is implemented through a liquidity density function that scales effective liquidity down when the capped fee covers only a small fraction of the theoretically required compensation.

A further difficulty arises if the market permanently reprices. If the system always measures risk relative to a fixed initial price, then it can remain stuck in a permanently defensive mode. To address this, we introduce a **moving anchor**: a slow geometric EMA of pool price defined in log-space. This allows the AMM to distinguish between short-term dislocations and durable shifts in market regime.

### 1.1 What this construction achieves

The mechanism is designed to produce the following behavior:

* near equilibrium, liquidity remains deep and fees remain low;
* as price moves away from equilibrium, harmful flow is charged more and effective liquidity is reduced;
* if the new price persists, the anchor gradually recenters and normal liquidity is restored around the new regime.

This is conceptually similar to how a professional market maker behaves under stress: spreads widen, depth is reduced, and inventory risk is actively managed.

### 1.2 What this construction does not achieve

It is equally important to state what the design does **not** do.

First, it does not eliminate historical IL relative to the original deposit state. Once inventory has changed due to past price movement, a moving anchor cannot undo that path-dependent divergence. The system only affects **future local risk** around the current center.

Second, it does not guarantee full protection through fees alone. The capped fee is explicitly acknowledged to be insufficient in adverse regions; the density mechanism exists precisely because complete fee-based compensation is generally not feasible.

Third, it introduces a new class of trade-offs. Lower effective liquidity in stressed states reduces LP exposure, but it also increases price impact, can reduce volume, and may weaken price tracking relative to external markets. The design is therefore not "free protection," but a specific and explicit balance between risk reduction and market quality.

---

## 2. Model Setup and Notation

We consider a two-asset pool with reserves

$$
x,\quad y
$$

where $x$ is the reserve of the base asset and $y$ is the reserve of the quote asset.

The instantaneous pool price is defined as

$$
P=\frac{y}{x}.
$$

All value comparisons are expressed in quote units.

We introduce a positive **anchor price**

$$
A>0
$$

which serves as the local equilibrium estimate around which liquidity is concentrated.

Because price dynamics are multiplicative, we work in log-space. Define

$$
p=\ln P,\qquad a=\ln A.
$$

The signed log-deviation from the anchor is

$$
z=p-a=\ln\frac{P}{A},
$$

and the absolute distance from the anchor is

$$
s=|z|=\left|\ln\frac{P}{A}\right|.
$$

This choice is deliberate. Log-distance is symmetric under reciprocal price moves: if the price doubles relative to the anchor, and if it halves relative to the anchor, the absolute deviation $s$ is the same. This aligns naturally with the symmetry of divergence loss.

We will also use the hyperbolic functions

$$
\cosh(u)=\frac{e^u+e^{-u}}{2},\qquad
\text{sech}(u)=\frac{1}{\cosh(u)},\qquad
\tanh(u)=\frac{\sinh(u)}{\cosh(u)}.
$$

---

## 3. Impermanent Loss as Local Divergence Loss

To derive the theoretical fee benchmark, we first restate impermanent loss in a form centered around the anchor.

Assume the pool is locally normalized so that at the anchor price $A$, the LP holds equal quote value in base and quote. Let the local reference inventory be such that the base and quote reserves satisfy the constant-product relation and the initial price equals the anchor.

For a constant-product pool with invariant $xy=k$, the reserve pair at price $P$ can be written as

$$
x=\sqrt{\frac{k}{P}},\qquad y=\sqrt{kP}.
$$

At the anchor price $A$, the corresponding reserve pair is

$$
x_A=\sqrt{\frac{k}{A}},\qquad y_A=\sqrt{kA}.
$$

### 3.1 LP value at price $P$

The marked-to-market value of the LP portfolio in quote units is

$$
V_{LP}=xP+y.
$$

Substituting the reserve expressions gives

$$
V_{LP}
= \sqrt{\frac{k}{P}}\cdot P+\sqrt{kP}
= 2\sqrt{kP}.
$$

### 3.2 HODL value at price $P$

The value of passively holding the anchor-state inventory $(x_A,y_A)$ at the new price $P$ is

$$
V_{HODL}=x_A P+y_A.
$$

Substituting $x_A=\sqrt{k/A}$ and $y_A=\sqrt{kA}$ yields

$$
V_{HODL}
= \sqrt{\frac{k}{A}}\cdot P+\sqrt{kA}.
$$

It is convenient to factor out $\sqrt{kA}$. Since

$$
\sqrt{\frac{k}{A}}\cdot P
= \sqrt{kA}\cdot\frac{P}{A},
$$

we obtain

$$
V_{HODL}
= \sqrt{kA}\left(1+\frac{P}{A}\right).
$$

### 3.3 LP/HODL ratio

The LP-to-HODL performance ratio is therefore

$$
\frac{V_{LP}}{V_{HODL}}
= \frac{2\sqrt{kP}}{\sqrt{kA}(1+P/A)}
= \frac{2\sqrt{P/A}}{1+P/A}.
$$

Now define the price ratio relative to anchor:

$$
r=\frac{P}{A}.
$$

Then

$$
\frac{V_{LP}}{V_{HODL}}
= \frac{2\sqrt{r}}{1+r}.
$$

Since

$$
r=e^z,
$$

we can rewrite the ratio as

$$
\frac{V_{LP}}{V_{HODL}}
= \frac{2e^{z/2}}{1+e^z}.
$$

Dividing numerator and denominator by $e^{z/2}$ gives

$$
\frac{V_{LP}}{V_{HODL}}
= \frac{2}{e^{-z/2}+e^{z/2}}.
$$

Using the definition of $\cosh$,

$$
e^{-z/2}+e^{z/2}=2\cosh(z/2),
$$

so

$$
\frac{V_{LP}}{V_{HODL}}
= \frac{1}{\cosh(z/2)}
= \text{sech}(z/2).
$$

Because $\text{sech}$ is even, this depends only on $s=|z|$:

$$
\frac{V_{LP}}{V_{HODL}}
= \text{sech}(s/2).
$$

Thus the impermanent loss relative to the anchor state is

$$
IL(s)=\text{sech}(s/2)-1.
$$

It is convenient to work with the positive loss magnitude

$$
L(s)=1-\text{sech}(s/2).
$$

This quantity measures how far the LP is below the passive benchmark, locally centered at the anchor.

---

## 4. Derivation of the Theoretical IL-Protective Fee

We now derive the fee that would, in differential form, exactly offset the growth of local divergence loss.

### 4.1 Incremental loss growth

Start from

$$
L(s)=1-\text{sech}(s/2).
$$

Differentiating with respect to $s$ gives

$$
\frac{dL}{ds}
= -\frac{d}{ds}\text{sech}(s/2).
$$

Using

$$
\frac{d}{du}\text{sech}(u)=-\text{sech}(u)\tanh(u),
$$

and the chain rule for $u=s/2$, we obtain

$$
\frac{dL}{ds}
= \frac{1}{2}\text{sech}(s/2)\tanh(s/2).
$$

Therefore

$$
dL
= \frac{1}{2}\text{sech}(s/2)\tanh(s/2)\,ds.
$$

This is the marginal increase in divergence loss for a small harmful move further away from the anchor.

### 4.2 Incremental traded notional under a harmful move

To convert loss growth into a fee requirement, we need the amount of traded value associated with an infinitesimal harmful move $ds$.

Using the constant-product reserve representation around the anchor,

$$
y=y_A e^{z/2},
$$

so under a harmful move away from the anchor,

$$
dy=\frac{y}{2}\,dz.
$$

Expressed in absolute distance, the infinitesimal traded notional in quote units is

$$
dQ=\frac{y}{2}\,ds.
$$

This holds symmetrically for both upward and downward harmful moves once all flows are expressed in quote value.

### 4.3 Fee revenue normalized by HODL value

Let $f(s)$ denote the fee rate charged on a harmful infinitesimal trade. Then absolute fee revenue is

$$
dF=f(s)\,dQ=f(s)\frac{y}{2}\,ds.
$$

To compare fee revenue with divergence loss, we normalize by the HODL benchmark value:

$$
dR=\frac{dF}{V_{HODL}}.
$$

Substituting gives

$$
dR=f(s)\frac{y}{2V_{HODL}}\,ds.
$$

Now compute the ratio $y/V_{HODL}$. From the previous section,

$$
y=y_A e^{z/2},
\qquad
V_{HODL}=y_A(1+e^z),
$$

so

$$
\frac{y}{V_{HODL}}
= \frac{e^{z/2}}{1+e^z}.
$$

Dividing numerator and denominator by $e^{z/2}$,

$$
\frac{y}{V_{HODL}}
= \frac{1}{e^{-z/2}+e^{z/2}}
= \frac{1}{2\cosh(z/2)}
= \frac{1}{2}\text{sech}(s/2).
$$

Hence

$$
dR
= f(s)\cdot \frac{1}{4}\text{sech}(s/2)\,ds.
$$

### 4.4 Matching fee to loss growth

The condition for exact local compensation is

$$
dR=dL.
$$

Substituting the expressions above yields

$$
f(s)\cdot \frac{1}{4}\text{sech}(s/2)\,ds
= \frac{1}{2}\text{sech}(s/2)\tanh(s/2)\,ds.
$$

Cancelling the common factor $\text{sech}(s/2)\,ds$, we obtain

$$
\frac{f(s)}{4}
= \frac{1}{2}\tanh(s/2).
$$

Therefore the required harmful-direction fee is

$$
f_{\mathrm{req}}(s)=2\tanh(s/2).
$$

This is the unique marginal fee curve that exactly offsets local divergence loss under the model assumptions.

### 4.5 Interpretation

Near the anchor, $\tanh(s/2)\approx s/2$, so

$$
f_{\mathrm{req}}(s)\approx s.
$$

Thus the required fee grows approximately linearly for small deviations.

Far from the anchor, $\tanh(s/2)\to 1$, so

$$
f_{\mathrm{req}}(s)\to 2.
$$

This means the fee required for full local compensation approaches 200%, which is economically infeasible. This infeasibility is not a flaw in the derivation; it is the main reason the design must include additional protection through liquidity exposure control.

---

## 5. From Theoretical Fee to Practical Risk Control

The theoretical fee provides a benchmark, not an implementable schedule. In practice, the protocol imposes a fee cap

$$
f_{\mathrm{cap}}(s)=\min\bigl(f_{\mathrm{req}}(s),\;f_{\max}\bigr).
$$

This cap represents a practical market constraint. It may arise from competitive pressure, acceptable user experience, or simply the desire to preserve volume.

The gap between required and realizable fee is summarized by the **coverage ratio**

$$
c(s)=\frac{f_{\mathrm{cap}}(s)}{f_{\mathrm{req}}(s)}.
$$

When $s=0$, both numerator and denominator vanish; by continuity we define

$$
c(0)=1.
$$

### 5.1 Interpretation of coverage

Coverage is not a fee by itself; it is a normalized measure of how much of the theoretically required protection the AMM can actually deliver.

* If $c=1$, the capped fee is still sufficient to match local divergence loss.
* If $c<1$, part of the loss remains uncompensated.
* The smaller $c$, the larger the residual risk.

This quantity becomes the natural input to the liquidity control layer. Once the protocol knows how under-protected a given state is, it can decide how much effective liquidity should remain active.

---

## 6. Liquidity Density as Exposure Control

### 6.1 Motivation

If capped fees cannot fully compensate divergence loss, then the protocol should reduce how much liquidity is exposed in that state. This does not change the mathematical form of IL itself. Instead, it changes the **size of the inventory exposed to the risk**.

This distinction matters. The density function is not a repair of the IL formula; it is a mechanism for limiting how much capital participates under under-compensated conditions.

### 6.2 Density function

The density function must satisfy three requirements:

1. **Bounded** — effective liquidity must not become negative or unreasonably large.
2. **Monotone** — worse risk coverage must never lead to deeper liquidity.
3. **Smooth** — no abrupt cliffs in market depth.

One of the simplest families satisfying all three is the power form $c^\alpha$. We define liquidity density as a monotone function of coverage:

$$
\rho(c)=\rho_{\min}+(\rho_{\max}-\rho_{\min})c^\alpha,
$$

with parameters satisfying

$$
0<\rho_{\min}\le \rho_{\max},
\qquad
\alpha>0.
$$

Where:

* $\rho_{\max}$ is the maximum effective liquidity available when risk is fully covered.
* $\rho_{\min}$ is the floor liquidity that remains even under severe under-compensation.
* $\alpha$ controls how aggressively liquidity is reduced as coverage declines.

### 6.3 Interpretation of $\alpha$

The parameter $\alpha$ controls the shape of the defensive response.

* If $\alpha=1$, liquidity declines linearly with coverage.
* If $\alpha>1$, the reduction is more aggressive in poorly covered regions.
* If $0<\alpha<1$, the reduction is softer and more tolerant.

In economic terms, $\alpha$ is a **risk-aversion shape parameter**.

### 6.5 Advantages and drawbacks

This density mechanism has two main advantages. It allows the protocol to continue operating even when theoretical protection is impossible, and it makes the AMM behave more like a professional market maker that widens and thins liquidity under stress.

Its main drawback is equally important: reduced density means larger price impact. In stressed regimes, the pool becomes safer for the LP but less efficient for traders. This is the core trade-off of the design.

---

## 7. Moving Anchor in Log-Space

### 7.1 Motivation

A fixed reference price causes the AMM to remain in defensive mode indefinitely after a durable repricing. If the market permanently moves from one stable level to another, the protocol should eventually recognize the new regime and restore normal liquidity around it.

This motivates a moving anchor.

### 7.2 EMA in log-space

Because price ratios are the natural geometry of AMM divergence, the anchor should be updated in log-space rather than price-space.

Define

$$
a_t=\ln A_t,\qquad p_t=\ln P_t.
$$

We then update the log-anchor via a standard exponential moving average(EMA):

$$
a_{t+1}=(1-\kappa)a_t+\kappa p_t,
\qquad
0<\kappa<1.
$$

Exponentiating both sides yields

$$
A_{t+1}
= \exp\bigl((1-\kappa)a_t+\kappa p_t\bigr)
= A_t^{1-\kappa}P_t^\kappa.
$$

This is the geometric EMA form used by the protocol.

### 7.3 Why log-space matters

A multiplicative increase and a multiplicative decrease of the same size should have symmetric effects on the anchor. Arithmetic averaging does not preserve this symmetry; geometric averaging does.

The log-space anchor is therefore consistent with the definition of distance

$$
s_t=\left|\ln\frac{P_t}{A_t}\right|.
$$

### 7.4 What the moving anchor changes

The moving anchor does **not** erase already accumulated divergence loss. Once past swaps have changed inventory composition, that history remains embedded in the LP portfolio.

What the moving anchor changes is the **reference point for future protection**. It allows the protocol to distinguish between temporary dislocations and persistent market repricing.

The main benefit of moving anchor is regime adaptation. The pool can defend aggressively during dislocation, then slowly return to normal operation if the market stabilizes elsewhere.

The main risk is premature recentering. If the anchor moves too quickly, the system may drop its defenses before the market has actually stabilized. This is why $\kappa$ must be chosen conservatively.

---

## 8. Liquidity Support Model via Virtual Reserves


### 8.1 Virtual reserves

To turn density into a pricing mechanism, we use **virtual reserves**. The pool keeps its real reserves, but trades are priced as if the liquidity available were scaled by the density factor. This approach is chosen for its simplicity and natural compatibility with the log-based anchor and pricing framework. Define virtual reserves using the density function $\rho$:

$$
x^{\mathrm{eff}}=\rho x,\qquad y^{\mathrm{eff}}=\rho y.
$$

The virtual reserve ratio is

$$
\frac{y^{\mathrm{eff}}}{x^{\mathrm{eff}}}
= \frac{\rho y}{\rho x}
= \frac{y}{x}
= P.
$$

So the spot price itself is unchanged. Density affects **depth**, not the instantaneous mid-price. This is exactly the intended behavior. The protocol is not trying to redefine the current price; it is trying to decide how strongly it should trade against incoming flow at that price.

The pricing layer behaves like a constant-product pool over the virtual reserves:

$$
x^{\mathrm{eff}}y^{\mathrm{eff}}=k^{\mathrm{eff}}.
$$


### 8.2 Quote-in swap derivation

Consider a quote-in, base-out trade with gross input $q_{\mathrm{in}}$ and fee rate $f$. Net input into the pricing layer is

$$
q_{\mathrm{net}}=q_{\mathrm{in}}(1-f).
$$

The effective quote reserve after the trade is

$$
y_{\mathrm{new}}^{\mathrm{eff}}=y^{\mathrm{eff}}+q_{\mathrm{net}}.
$$

By constant-product pricing,

$$
x_{\mathrm{new}}^{\mathrm{eff}}
= \frac{k^{\mathrm{eff}}}{y^{\mathrm{eff}}+q_{\mathrm{net}}}
= \frac{x^{\mathrm{eff}}y^{\mathrm{eff}}}{y^{\mathrm{eff}}+q_{\mathrm{net}}}.
$$

The base output is the reduction in effective base reserve:

$$
\Delta x
= x^{\mathrm{eff}}-x_{\mathrm{new}}^{\mathrm{eff}}
= x^{\mathrm{eff}}-\frac{x^{\mathrm{eff}}y^{\mathrm{eff}}}{y^{\mathrm{eff}}+q_{\mathrm{net}}}.
$$

Substituting $x^{\mathrm{eff}}=\rho x$, $y^{\mathrm{eff}}=\rho y$, we obtain

$$
\Delta x
= \frac{\rho x\,q_{\mathrm{net}}}{\rho y+q_{\mathrm{net}}}.
$$

### 8.3 Base-in swap derivation

For a base-in, quote-out trade with gross input $b_{\mathrm{in}}$ and fee rate $f$, define

$$
b_{\mathrm{net}}=b_{\mathrm{in}}(1-f).
$$

The effective base reserve after the trade is

$$
x_{\mathrm{new}}^{\mathrm{eff}}=x^{\mathrm{eff}}+b_{\mathrm{net}}.
$$

Then

$$
y_{\mathrm{new}}^{\mathrm{eff}}
= \frac{x^{\mathrm{eff}}y^{\mathrm{eff}}}{x^{\mathrm{eff}}+b_{\mathrm{net}}}.
$$

The quote output is

$$
\Delta y
= y^{\mathrm{eff}}-y_{\mathrm{new}}^{\mathrm{eff}}
= y^{\mathrm{eff}}-\frac{x^{\mathrm{eff}}y^{\mathrm{eff}}}{x^{\mathrm{eff}}+b_{\mathrm{net}}}.
$$

Substituting virtual reserves yields

$$
\Delta y
= \frac{\rho y\,b_{\mathrm{net}}}{\rho x+b_{\mathrm{net}}}.
$$

---

## 9. Price Band and Liquidity Support Range

The protocol restricts active liquidity support to a price band

$$
P\in[P_{\min},P_{\max}].
$$

This band limits how far the pool is willing to provide liquidity under the current configuration.

The band serves as a coarse outer risk boundary. Even if the moving anchor and density system are functioning properly, the LP may still want a hard limit on how far liquidity can remain active.

In practice, the band protects against extreme inventory conversion and provides a final line of defense against pathological market moves.

When a candidate post-trade price remains inside the band, the trade executes in full.

When a candidate post-trade price would leave the band, the trade is only partially executed up to the boundary. This means the pool continues to provide liquidity within the intended support region but refuses to extend protection beyond it.

The band is not a substitute for the density function. The density function provides **continuous local control**, while the band provides a **hard outer constraint**.

These two layers complement each other:

* the density function says how much liquidity should remain active at a given state,
* the band says where liquidity support must stop entirely.

---

## 10. Core AMM Design

We can now combine the components into a single operational mechanism.

### 10.1 AMM state

The pool stores:

* real reserves $(x,y)$,
* current anchor $A$,
* price band $[P_{\min},P_{\max}]$.

### 10.2 Immutable parameters

The pool is configured by:

* anchor speed $\kappa$,
* fee cap $f_{\max}$,
* helpful-direction base fee $f_{\mathrm{base}}$,
* density bounds $\rho_{\min},\rho_{\max}$,
* density shape parameter $\alpha$.

### 10.3 Harmful vs helpful flow

Not all flow should be charged equally. A trade is **harmful** if it pushes the price further away from the anchor; it is **helpful** if it moves the price back toward the anchor.

This distinction is central to the design. The protocol is not trying to maximize fee revenue indiscriminately. It is trying to tax specifically the order flow that increases divergence risk.

### 10.4 Swap lifecycle

Given the pre-swap state:

1. Compute current price

$$
P=\frac{y}{x}.
$$

2. Compute distance from anchor

$$
s=\left|\ln\frac{P}{A}\right|.
$$

3. Compute the theoretical harmful fee

$$
f_{\mathrm{req}}(s)=2\tanh(s/2).
$$

4. Apply the fee cap

$$
f_{\mathrm{cap}}(s)=\min\bigl(f_{\mathrm{req}}(s),\;f_{\max}\bigr).
$$

5. Compute coverage

$$
c(s)=\frac{f_{\mathrm{cap}}(s)}{f_{\mathrm{req}}(s)}
$$

with $c(0)=1$.

6. Compute density

$$
\rho=\rho_{\min}+(\rho_{\max}-\rho_{\min})c^\alpha.
$$

7. Classify the incoming trade as harmful or helpful and select the fee branch:

   * harmful trade uses $f_{\mathrm{cap}}$,
   * helpful trade uses $f_{\mathrm{base}}$.

8. Price the trade through virtual reserves using the formulas from Section 8.

9. Compute the candidate post-trade price and enforce the band:

   * full fill if inside the band,
   * partial fill to boundary otherwise.

10. Update the anchor using the post-trade price:

$$
A_{\mathrm{new}}=A^{1-\kappa}P_{\mathrm{post}}^\kappa.
$$

This order matters. In particular, the anchor must be updated **after** swap execution, not before. Otherwise the trader could influence the fee branch through the same movement that the anchor is meant to absorb only gradually.

### 10.5 Advantages of the combined design

The combined mechanism is coherent in a way that isolated features are not.

The theoretical fee provides a principled measure of how expensive harmful flow should be. The cap recognizes real-market constraints. The coverage ratio quantifies the remaining under-protected risk. The density function converts that residual risk into reduced exposure. The moving anchor prevents the system from mistaking every durable repricing for permanent stress.

Taken together, these pieces form a unified risk-control architecture.

### 10.6 Drawbacks and trade-offs

The design is more sophisticated than a passive AMM, and that complexity comes with cost.

If density falls too sharply, price impact may increase so much that price can move away from the anchor even faster. This creates a reflexive risk: low liquidity can amplify the very deviations the mechanism is trying to defend against.

If the anchor adapts too quickly, the system may abandon protection prematurely. If it adapts too slowly, the pool may remain overly defensive in a market that has already stabilized.

If fee caps are set too low relative to expected volatility, density may spend too much time near the floor. In that case the pool is safe but commercially unattractive.

These are not contradictions. They are the design surface of the mechanism, and they must be handled by calibration rather than ignored.

---

## 11. Regime Behavior and Intuition

The best way to understand the AMM is to examine how it behaves across regimes.

### 11.1 Near-anchor regime

When $P\approx A$, the distance $s$ is small. The theoretical compensating fee is small, the cap is not binding, coverage is near one, and density remains near $\rho_{\max}$.

In this regime, the pool behaves much like a standard AMM with good depth and low fees. Trading is efficient, price impact is limited, and the system provides liquidity competitively.

### 11.2 Stress regime

When price moves far away from the anchor, $s$ grows. The theoretical fee rises, eventually hitting the cap. Coverage falls below one, and density declines toward $\rho_{\min}$.

This is the defensive mode of the mechanism. The pool acknowledges that it cannot charge enough to fully offset local divergence loss, so it compensates by scaling down active liquidity.

In practical terms, the AMM says: "If I cannot be paid enough to bear this risk, I will bear less of it."

### 11.3 Repriced equilibrium regime

If the market stabilizes at a new level, the geometric EMA anchor begins to follow it. As the anchor approaches the new price, distance $s$ shrinks again. The required fee falls, coverage improves, and density recovers.

This is the re-centering mode. Liquidity is restored not because risk disappeared historically, but because future local divergence has become small again relative to the new equilibrium estimate.

---

## 12. Limitations and Risks

This construction has several important limitations.

First, it does not eliminate historical IL relative to the original deposit state. The moving anchor only governs future local protection.

Second, the mechanism depends heavily on parameter selection. The cap $f_{\max}$, floor density $\rho_{\min}$, and anchor speed $\kappa$ jointly determine whether the AMM is attractive, defensive, or unusable.

Third, the design can reduce market quality in stressed states. Lower density increases price impact, may reduce volume, and can weaken arbitrage-based price tracking.

Fourth, the mechanism introduces additional path dependence. The pool is no longer a memoryless constant-product market. It becomes a stateful adaptive system whose behavior depends on past price evolution through the anchor.

These are real costs, but they are also the price of moving from passive liquidity provision to active risk management.

---

## 13. Conclusion

We have developed an AMM construction that treats impermanent loss not as a phenomenon to be "solved away," but as a risk to be actively managed.

The derivation of the theoretical fee curve

$$
f_{\mathrm{req}}(s)=2\tanh(s/2)
$$

shows that a fully compensating fee exists only as a benchmark. In realistic markets, this benchmark rapidly becomes economically infeasible. That infeasibility motivates the core innovation of the design: once fee-based protection becomes incomplete, the protocol reduces effective liquidity exposure through a density function linked to fee coverage.

The moving anchor then allows the system to distinguish between transient dislocations and durable repricing, so that the AMM can defend itself aggressively during stress while still re-centering around new market regimes.

The resulting mechanism is best understood as an **adaptive, inventory-aware market maker**. It does not remove impermanent loss. Instead, it redistributes and controls it through an explicit combination of:

* harmful-flow taxation,
* effective liquidity scaling,
* and gradual equilibrium adaptation.

In that sense, the construction occupies a middle ground between a passive AMM and an actively managed market-making system. It remains on-chain and rule-based, but it incorporates the core intuition of professional inventory management: when risk cannot be fully priced, it must also be size-controlled.
