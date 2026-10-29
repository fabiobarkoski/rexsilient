# Contributing to Rexsilient

Contributions of any size are welcome: bug reports, documentation fixes, new
patterns.

## What can I do?

- Look at the [issue tracker](https://github.com/fabiobarkoski/rexsilient/issues).
- Implement one of the planned patterns from the [README](README.md).
- Improve the documentation.
- Report a bug, with the smallest snippet that reproduces it.

For larger changes, especially to the public API or the DSL,
[open an issue](https://github.com/fabiobarkoski/rexsilient/issues/new) first
so the approach can be discussed before the code is written.

## Workflow

1. Fork the repository and clone your fork.
2. Create a branch for your change: `git checkout -b my-feature`.
3. Install the dependencies: `mix deps.get`.
4. Make your change, with tests.
5. Run the checks below.
6. Push the branch and open a pull request. A draft pull request is fine for
   early feedback.

## Before opening a pull request

```bash
mix format --check-formatted
mix credo
mix dialyzer
mix test
```

- New behaviour comes with tests.
- Public functions have `@doc` and `@spec`.
- User-facing changes are reflected in the [README](README.md).
- Keep the history clean: rebase on the latest `main` and squash "fix typo"
  style commits before review.

## Commit messages

The first line is a short summary of what the commit changes, readable without
the diff. Either plain or
[Conventional Commits](https://www.conventionalcommits.org) style:

```
add jitter to exponential retry
feat(retry): add jitter to exponential strategy
```

When the change is not obvious from the summary, add a body after a blank line
explaining what changed and why:

```
fix(circuit_breaker): reset before closing

The strategy was reset after the state changed to closed, so a failure
recorded in between was lost. Resetting first keeps every failure counted.
```
