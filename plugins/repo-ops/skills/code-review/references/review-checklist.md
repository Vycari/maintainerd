# Code Review Checklist

Quick-reference checklist for reviewing code changes. Use this as a systematic guide during reviews.
Apply the repo's own standards from `config.guidelines.coding` and `config.guidelines.testing`
first; the items below are the language-generic backbone.

## Correctness

- [ ] Logic is correct for all input cases (empty, null, boundary values)
- [ ] Edge cases are handled (empty collections, missing properties, zero-length strings)
- [ ] Async operations are properly awaited
- [ ] No floating promises / unhandled awaitables (unhandled rejections)
- [ ] Error paths return or throw appropriately
- [ ] Loop conditions terminate correctly (no infinite loops)
- [ ] Off-by-one errors checked in indexing and slicing
- [ ] Race conditions considered for concurrent operations
- [ ] State mutations don't cause unexpected side effects

## Architecture and design

- [ ] Single Responsibility: each function/class has one clear purpose
- [ ] DRY: no knowledge duplication (but code duplication for different concepts is fine)
- [ ] Dependencies flow in one direction (no circular imports)
- [ ] Public API surface is minimal (only expose what's needed)
- [ ] New abstractions are justified (not premature)
- [ ] Changes are backwards-compatible (or breaking changes are documented)
- [ ] Feature flags or configuration used when appropriate

## Type quality

When `config.language` is `typescript`:

- [ ] No `any` types (use `unknown` with type guards instead)
- [ ] No non-null assertions (`!`) without clear justification
- [ ] Interfaces used for extensible object shapes
- [ ] Union types properly narrowed before use
- [ ] Generic types have meaningful constraints
- [ ] Return types are explicit for public functions
- [ ] `readonly` used for data that shouldn't be mutated

When `config.language` is `python`:

- [ ] Precise type hints; `Any`, `cast(Any, ...)`, and `# type: ignore` are justified, not reflexive
- [ ] `Optional`/`None` handled explicitly, not via incidental truthiness
- [ ] No bare `except:`; specific exceptions caught
- [ ] Public functions have annotated parameters and return types
- [ ] (Defer to `config.guidelines.coding` for the repo's exact typing bar)

## Naming and readability

- [ ] Functions use verb phrases (`fetchData`, `validateInput`)
- [ ] Booleans use `is`/`has`/`should`/`can` prefixes
- [ ] No abbreviations (except universally understood ones like `id`, `url`)
- [ ] No magic numbers or strings (use named constants)
- [ ] Comments explain "why", not "what" (code should be self-documenting)
- [ ] Functions are short enough to understand at a glance (<30 lines preferred)
- [ ] Nesting depth is shallow (use guard clauses and early returns)
- [ ] Naming follows the repo convention in `config.guidelines.coding` (e.g. `camelCase` vs `snake_case`)

## Error handling

- [ ] Errors are caught at the appropriate level
- [ ] No silently swallowed errors (empty catch blocks / bare excepts)
- [ ] Error messages are descriptive and include context
- [ ] User-facing errors surface a helpful message
- [ ] Network errors are handled gracefully with retry logic where appropriate
- [ ] File/IO operation errors check for existence/availability first
- [ ] Validation errors are reported before attempting the operation

## Performance

- [ ] No redundant computation inside loops
- [ ] Expensive operations are debounced (input changes, API calls)
- [ ] Large collections use hash-based lookups (`Map`/`Set`, `dict`/`set`) instead of linear scans
- [ ] Independent async operations run in parallel (`Promise.all` / `asyncio.gather`)
- [ ] Only the needed data is loaded (metadata vs full payload)
- [ ] No synchronous I/O or heavy computation blocking the main thread / event loop

## Security

- [ ] No dynamic code execution on untrusted input (`eval()`, `new Function()`, `eval`/`exec`)
- [ ] No unsafe HTML injection (`innerHTML` with untrusted content)
- [ ] User input is sanitized before use in file paths, queries, or templates
- [ ] No hardcoded API keys, tokens, or credentials in source
- [ ] External data (API responses, file contents, deserialized data) is validated
- [ ] File paths are normalized/validated before use
- [ ] Privileged or system locations are excluded from bulk operations

## Testing

Apply `config.guidelines.testing` first, then:

- [ ] New functionality has corresponding tests
- [ ] Tests verify behavior, not implementation details
- [ ] Edge cases are tested (empty input, null, errors)
- [ ] Test names describe the scenario and expected outcome
- [ ] Mocks are minimal and focused
- [ ] Tests are independent (no shared mutable state between tests)
- [ ] Error paths are tested, not just happy paths

## Domain-specific guidance

If `config.guidelines` references additional domain guidance (loaded by the skill), run its
checklist here. For example, an Obsidian-plugin repo's plugin-API skill adds checks like "register
events with `this.registerEvent()`", "use `requestUrl()` not `fetch()`", and "use theme variables,
not hardcoded colors." A web service might add API-contract or migration checks. Pull these from the
referenced guidance rather than assuming any one platform.

## Project conventions

- [ ] Follows the repo's naming, formatting, and structure conventions from `config.guidelines.coding`
- [ ] Passes the repo's formatter/linter (the commands in `config.commands.format` / `config.commands.lint`)
- [ ] Uses the project's logger, not `print()` / `console.log` directly (per `config.guidelines.coding`)
- [ ] Documentation updated alongside code changes
- [ ] Imports organized per the repo's convention
