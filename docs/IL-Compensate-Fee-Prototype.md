# IL-Compensating Fee Design

## The problem

The goal is to design a **dynamic fee** that compensates the LP for **pure impermanent loss (IL)** as price moves away from the initial anchor price. This result is planned to be used to construct a more practical fee design for IL-protecting SwapVM strategies.


**NOTE:** *Here we simply analyze a theoretical fee that fully compensates IL. In real-world scenarios this fee is impractical, reaching 200%. The goal of this work is to study the mathematical form of full IL protection.*



## 1. Setup

Let the initial pool reserves be:

$$
x_0,\quad y_0
$$

and the initial anchor price be

$$
P_0 = \frac{y_0}{x_0}.
$$

At a later time, the pool price is

$$
P = \frac{y}{x}.
$$

Define the log-distance from the anchor:

$$
z = \ln\frac{P}{P_0},
\qquad
s = |z|.
$$

Here:

- $z$ is the signed log-deviation from the anchor,
- $s$ is the absolute distance from the anchor.

For a V2 constant-product pool:

$$
xy = k = x_0 y_0.
$$

Since $P = y/x = P_0 e^z$, the reserves can be written as:

$$
x = x_0 e^{-z/2},
\qquad
y = y_0 e^{z/2}.
$$

---

## 2. LP Value and HODL Value

We measure value in quote units.

The LP position value is

$$
V_{LP} = xP + y = 2\sqrt{kP}
$$

Let's express price movement in terms of $z$:

$$P = P_0 e^z$$

and (since $k = x_0 y_0$):

$$
V_{LP} = 2 y_0 e^{z/2}.
$$

The HODL benchmark is the initial inventory $(x_0, y_0)$ marked to the current price:

$$
V_{HODL} = x_0 P + y_0.
$$

Using $P = P_0 e^z$ and $x_0 P_0 = y_0$:

$$
V_{HODL} = y_0(1 + e^z).
$$

---

## 3. Pure Impermanent Loss

The LP-to-HODL ratio is

$$
\frac{V_{LP}}{V_{HODL}}
= \frac{2 e^{z/2}}{1 + e^z}
= \frac{1}{\cosh(z/2)}
= \operatorname{sech}(z/2).
$$

Therefore pure IL is

$$
IL(z) = \operatorname{sech}(z/2) - 1.
$$

It is convenient to define the positive loss magnitude

$$
L(s) = -IL = 1 - \operatorname{sech}(s/2).
$$

This is the quantity we want the fee system to compensate.

---

## 4. Infinitesimal Trade Notional for a Harmful Move

We now consider an infinitesimal move **away from the anchor**, i.e. an increase in $s$.

From

$$
y = y_0 e^{z/2},
$$

we get

$$
dy = \frac{y}{2}dz.
$$

For an upward move, the trader inputs quote asset, so the infinitesimal input notional in quote units is

$$
dQ = dy = \frac{y}{2}dz.
$$

For a downward move, the trader inputs base asset, but expressed in quote units the input notional is

$$
dQ = P|dx|.
$$

Since

$$
x = x_0 e^{-z/2}
\quad\Rightarrow\quad
dx = -\frac{x}{2}dz,
$$

we get

$$
P|dx| = \frac{Px}{2}|dz| = \frac{y}{2}|dz|.
$$

Thus in both directions, for a harmful move away from the anchor:

$$
\boxed{
dQ = \frac{y}{2}ds
}
$$

where $ds = |dz|$.

---

## 5. Fee Revenue on a Harmful Infinitesimal Step

Let $f(s)$ be the ad valorem fee rate applied to trades that increase distance from the anchor.

Then infinitesimal fee revenue in quote units is

$$
dF = f(s)\, dQ = f(s)\frac{y}{2}ds.
$$

To compare fee revenue with IL, we normalize by the HODL value:

$$
dR = \frac{dF}{V_{HODL}}.
$$

Substituting:

$$
dR = f(s)\frac{y}{2V_{HODL}}ds.
$$

Now compute

$$
\frac{y}{V_{HODL}}
= \frac{y_0 e^{z/2}}{y_0(1+e^z)}
= \frac{e^{z/2}}{1+e^z}
= \frac{1}{2\cosh(z/2)}
= \frac12 \operatorname{sech}(s/2).
$$

Therefore

$$
\boxed{
dR = \frac{f(s)}{4}\operatorname{sech}(s/2)\,ds
}
$$

---

## 6. Condition for Full IL Compensation

To fully compensate pure IL, the incremental fee compensation must equal the incremental increase in loss magnitude:

$$
dR = dL.
$$

Since

$$
L(s) = 1 - \operatorname{sech}(s/2),
$$

we differentiate:

$$
\frac{dL}{ds}
= \frac12 \operatorname{sech}(s/2)\tanh(s/2).
$$

So

$$
dL
= \frac12 \operatorname{sech}(s/2)\tanh(s/2)\,ds.
$$

Set $dR = dL$:

$$
\frac{f(s)}{4}\operatorname{sech}(s/2)\,ds
= \frac12 \operatorname{sech}(s/2)\tanh(s/2)\,ds.
$$

Cancelling the common factors ($\operatorname{sech}(s/2)$ and $ds$) we recieve the required harmful-direction fee:

$$
\boxed{
f_{\mathrm{req}}(s) = 2\tanh\left(\frac{s}{2}\right)
}
$$

---

## 7. Final Formula

Using

$$
s = \left|\ln\frac{P}{P_0}\right| = \left|\ln\frac{yx_0}{xy_0}\right|
$$

and the exact IL-compensating fee:

$$
\boxed{
f_{\mathrm{req}}(s) = 2\tanh\left(\frac{s}{2}\right)
}
$$


The final formula through initial and final pool balances:

$$
\boxed{
f_{\mathrm{req}}(x,y)=
2\tanh\left(
\frac12\left|\ln\frac{yx_0}{xy_0}\right|
\right)
}
$$

---

## 8. Interpretation

- $f_{\mathrm{req}}(s)$ is the **exact marginal fee surcharge** required on trades that move the pool further away from the anchor.
- It compensates **pure IL** in differential form, and therefore also cumulatively along the path.
- For small deviations,

$$
\tanh(s/2)\approx s/2
\quad\Rightarrow\quad
f_{\mathrm{req}}(s)\approx s.
$$

So near the anchor, the required compensating fee is approximately **linear in log-distance**.

- For large deviations,

$$
\tanh(s/2)\to 1
\quad\Rightarrow\quad
f_{\mathrm{req}}(s)\to 2.
$$

So far from the anchor, the fee saturates at **200%** — reflecting the fact that IL itself is bounded.


---
