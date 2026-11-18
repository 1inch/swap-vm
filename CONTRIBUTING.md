# Contributing to swap-vm

First off, thanks for taking the time to contribute. This guide covers how to report a problem, how to propose a change, and what a pull request needs before it can be merged. Reading the relevant section first saves a round trip for both of us.

If you like the project but have no time to contribute, starring the repository helps others find it, and telling us about a documented command that does not work is worth more than it sounds — a wrong instruction costs every later reader the same hour.

## Table of Contents

- [Reporting a vulnerability](#reporting-a-vulnerability)
- [I Have a Question](#i-have-a-question)
- [I Want To Contribute](#i-want-to-contribute)
  - [Legal Notice](#legal-notice)
  - [AI assistance](#ai-assistance)
  - [Reporting Bugs](#reporting-bugs)
  - [Suggesting Enhancements](#suggesting-enhancements)
  - [Your First Code Contribution](#your-first-code-contribution)
  - [Improving The Documentation](#improving-the-documentation)
- [Styleguides](#styleguides)
  - [Solidity](#solidity)
  - [Tests](#tests)
  - [Commit Messages](#commit-messages)
- [Attribution](#attribution)

## Reporting a vulnerability

> Never report a security issue through a public issue, pull request or discussion, and never put sensitive detail in one. A public report hands an attacker what you found, on contracts holding funds, before there is a fix.

Use the private channel described in [SECURITY.md](SECURITY.md).

This applies to fixes as much as reports. A pull request that quietly patches a vulnerability discloses it to everyone reading the diff, so the fix goes through the same private channel first.

## I Have a Question

Read [the docs](docs/) and the NatSpec on the functions you are calling, then search the [existing issues](https://github.com/1inch/swap-vm/issues) — questions about behaviour have usually been asked before.

If that leaves it open, [open an issue](https://github.com/1inch/swap-vm/issues/new/choose) and say what you called, on which network, what you expected, and what happened instead.

## I Want To Contribute

### Legal Notice

By contributing you confirm that you stand behind the content you are contributing, that you hold the rights to it, and that it may be released under this project's licence (LicenseRef-Degensoft-SwapVM-1.1).

### AI assistance

Using AI tools to draft, refactor or review a change is allowed. Disclose it in the pull request: the purpose of the usage, the model, and the model settings that mattered — effort and context size. A reviewer who cannot tell what was generated cannot judge what to trust. You remain responsible for every line that lands.

### Reporting Bugs

A good report does not leave anyone chasing you for details. Before opening one:

- Check whether the behaviour still happens on the latest tagged release.
- Search the [issue tracker](https://github.com/1inch/swap-vm/issues) for the same problem.
- Decide whether it is a bug or a question. If it is a question, see [I Have a Question](#i-have-a-question).
- Collect the network, the contract address, the transaction hash, the tag or commit the deployment was built from, and the steps that reproduce it.

Then open an issue with those details. A failing test is the fastest report you can file — it removes the guesswork entirely.

Once filed, a maintainer tries to reproduce it. A report nobody can reproduce cannot be fixed, so it waits for reproduction steps rather than for a fix.

If what you found is a vulnerability, stop and read [Reporting a vulnerability](#reporting-a-vulnerability).

### Suggesting Enhancements

Before suggesting one:

- Check the latest release and [the docs](docs/) — the behaviour you want may already exist.
- Search the [issues](https://github.com/1inch/swap-vm/issues) and comment on an existing suggestion rather than opening a duplicate.
- Consider whether it belongs in the protocol at all. On-chain code carries every feature forever, in gas and in audit surface, so the case for adding one has to be made rather than assumed. Something useful to a few integrators may belong in an extension or in your own periphery contract.

In the suggestion, describe the current behaviour, the behaviour you want instead, and who benefits. Name the alternatives you rejected and why.

### Your First Code Contribution

1. Fork the repository and branch from `main`. Name the branch after what it does — `fix/rounding-in-partial-fill` rather than `patch-1`.
2. Install the dependencies and build, using the commands in [the README](README.md#development).
3. Make the change, with tests that fail before it and pass after.
4. Before pushing, run the checks listed in [the README](README.md#development). CI runs the same ones.
5. Push and open a pull request against `main`.

The pull request must either link the issue that describes the bug or feature, or carry a detailed description of what changes and why — enough that a reviewer who has not followed the work can still judge it. Keep it to one concern: two unrelated fixes are two pull requests, and reviewing them together takes longer than reviewing them apart.

A pull request merges once CI is green and a maintainer has approved it.

### Improving The Documentation

Documentation changes take the same route as code, and are just as welcome.

- Behaviour of a function is documented in its NatSpec, next to the code. Fix it there, so it cannot drift from what the function does.
- [The docs](docs/) cover the protocol level — how the pieces fit, and why.
- A command in the README that no longer works is a bug. Report it even if you do not fix it.

## Styleguides

### Solidity

- Follow the [Solidity style guide](https://docs.soliditylang.org/en/latest/style-guide.html) for layout, ordering and naming.
- Every `public` and `external` function carries NatSpec: `@notice` for what it does to the caller, `@param` for each argument, `@return` for each return value. Add `@dev` wherever the body holds a surprise.
- Name things for what they mean to a caller rather than how they are implemented, and name a custom error after the condition it rejects.
- Do not reformat code you are not changing — it buries the real change in noise.

### Tests

- Every change in behaviour needs a unit test, reverts included. A test covering only the happy path documents half the change.
- Fuzz and invariant tests are mandatory for new contracts, and where the boundary sits.
- Name a test for the property it defends, so a failure says what broke rather than which function was called.

### Commit Messages

- One logical change per commit.
- Imperative subject, kept short: `fix rounding in partial fill`.
- The body explains why; the diff already shows what. Reference the issue it closes.

## Attribution

This guide is based on [contributing.md](https://contributing.md/).
