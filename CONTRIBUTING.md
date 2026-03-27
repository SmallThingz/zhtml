# Contributing

## Prerequisites

- Zig `0.16.0-dev.2984+cb7d2b056`
- Git

## Local Development Workflow

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```

Use these additional commands when touching performance/conformance code:

```bash
zig build bench-compare
zig build conformance
```

## Style

- Format Zig code before pushing:

```bash
zig fmt src/**/*.zig examples/*.zig build.zig
```

- Keep public behavior changes covered by tests in `src/root.zig` test graph.
- Keep examples in `examples/` executable and behavior-asserted.

## Documentation and Snippet Policy

- User-facing snippets in `README.md` and `DOCUMENTATION.md` must match canonical code in `examples/`.
- Every example file must contain executable tests.
- Run `zig build examples-check` before merging doc/example changes.

## Commit Expectations

- Use clear commit messages describing intent and scope.
- Keep unrelated refactors out of feature/fix commits.
- Include test/validation summary in PR description.
