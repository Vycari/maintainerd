---
name: code-review
description: >-
  Review code for quality, correctness, and maintainability. Use this skill when
  reviewing pull requests, auditing existing code, refactoring for clarity, or
  enforcing coding standards. Covers DRY principles, SOLID design, error
  handling, performance, security, testing, and language-specific best practices.
  Reads the repo's coding and testing guidelines (config.guidelines.coding,
  config.guidelines.testing) so review feedback matches the standards this repo
  actually enforces, and follows any additional domain guidance the config points to.
---

# Code Review

## Load the repo config

Before reviewing anything, load the repo config (see
[`../../references/config-schema.md`](../../references/config-schema.md)):

1. Read `.claude/maintainerd.json` from the repo root.
2. If it does not exist, **stop** and tell the user:
   > This repo has no `.claude/maintainerd.json`. Run `/bootstrap` to generate it, then re-run me.
   Do not guess values or hardcode another repo's standards.
3. From it, you need `config.language` (selects which language-specific guidance below applies) and
   the guideline pointers `config.guidelines.coding` and `config.guidelines.testing`.
4. Read the file named by `config.guidelines.coding` — these are the coding standards a senior
   reviewer enforces *in this repo* (error-handling conventions, logging, typing expectations,
   naming, banned patterns). Read `config.guidelines.testing` for the repo's test conventions. Treat
   both as authoritative: when this skill's generic advice and the repo guidelines disagree, the
   repo guidelines win.
5. If `config.guidelines` references additional domain guidance, read it too. For example, an
   Obsidian-plugin repo may point to its plugin-API skill for vault/workspace/view specifics; a web
   service might point to an API-conventions doc. Apply that guidance alongside the generic review
   substance below.
6. If a guidelines file is missing or still full of `TODO` markers, note that in your review summary
   (your standards coverage is only as good as those files) and proceed with the language-generic
   checks you can still perform.

## When to use this skill

Use this skill when:

- Reviewing a pull request or code diff
- Auditing existing code for quality issues
- Refactoring code for clarity or maintainability
- Enforcing coding standards and conventions
- Identifying bugs, security vulnerabilities, or performance problems
- Evaluating whether code follows DRY, SOLID, or other design principles
- Suggesting improvements to error handling, naming, or structure

This skill covers general code-quality review. For repo-specific standards, defer to the guidelines
files named in `config.guidelines` (loaded above). For structural or tech-debt findings that span
the codebase, point the user at the **audit-architecture** skill; for test-suite quality concerns
beyond a single diff, point them at the **audit-tests** skill.

## Review priorities

Evaluate code in this order of importance:

1. **Correctness** - Does it work? Are there logic errors, off-by-one bugs, race conditions, or unhandled edge cases?
2. **Security** - Are there injection vulnerabilities, unsafe data handling, or exposed secrets?
3. **Maintainability** - Can another developer understand and modify this code confidently?
4. **Performance** - Are there unnecessary allocations, redundant computations, or O(n^2) algorithms hiding in loops?
5. **Style** - Does it follow project conventions for naming, formatting, and structure (per `config.guidelines.coding`)?

## DRY - Don't Repeat Yourself

The DRY principle states that every piece of knowledge should have a single, unambiguous representation in the system.

### Recognizing violations

```typescript
// BAD: Logic duplicated across handlers
async function handleCreate(file: TFile) {
	const content = await vault.read(file);
	const metadata = app.metadataCache.getFileCache(file);
	const tags = metadata?.frontmatter?.tags ?? [];
	await processFile(content, tags);
	logger.log('Processed:', file.path);
}

async function handleModify(file: TFile) {
	const content = await vault.read(file);
	const metadata = app.metadataCache.getFileCache(file);
	const tags = metadata?.frontmatter?.tags ?? [];
	await processFile(content, tags);
	logger.log('Processed:', file.path);
}
```

```typescript
// GOOD: Extract shared logic
async function readFileWithTags(file: TFile): Promise<{ content: string; tags: string[] }> {
	const content = await vault.read(file);
	const metadata = app.metadataCache.getFileCache(file);
	const tags = metadata?.frontmatter?.tags ?? [];
	return { content, tags };
}

async function handleFileEvent(file: TFile) {
	const { content, tags } = await readFileWithTags(file);
	await processFile(content, tags);
	logger.log('Processed:', file.path);
}
```

### When NOT to apply DRY

DRY is about knowledge duplication, not code duplication. Two blocks of code that look the same but represent different concepts should stay separate:

- **Different domains**: A validation rule for user input and a similar check in a database layer serve different purposes and may diverge.
- **Premature abstraction**: Three similar lines are better than a premature abstraction. Wait until the pattern appears 3+ times and is genuinely the same concept before extracting.
- **Test code**: Tests should be explicit and readable. Some repetition in tests is preferable to fragile shared test helpers.

## SOLID principles

### Single Responsibility

Each class or module should have one reason to change.

```typescript
// BAD: Class does API calls, caching, and UI rendering
class DataManager {
	async fetchData() {
		/* ... */
	}
	cacheResult(data: any) {
		/* ... */
	}
	renderToView(data: any) {
		/* ... */
	}
}

// GOOD: Separate concerns
class DataFetcher {
	async fetch(): Promise<Data> {
		/* ... */
	}
}
class DataCache {
	store(data: Data) {
		/* ... */
	}
	retrieve(): Data | null {
		/* ... */
	}
}
class DataView extends ItemView {
	render(data: Data) {
		/* ... */
	}
}
```

### Open/Closed

Extend behavior through composition or interfaces, not by modifying existing code.

```typescript
// GOOD: New tool types don't require modifying the registry
interface Tool {
	name: string;
	execute(params: unknown): Promise<ToolResult>;
}

class ToolRegistry {
	private tools = new Map<string, Tool>();
	register(tool: Tool) {
		this.tools.set(tool.name, tool);
	}
}
```

### Dependency Inversion

Depend on abstractions, not concretions.

```typescript
// BAD: Direct dependency on implementation
class ChatService {
	private api = new GeminiDirectApi();
}

// GOOD: Depend on interface
class ChatService {
	constructor(private api: ModelApi) {}
}
```

## Error handling

### Principles

1. **Catch at the right level** - Handle errors where you have enough context to do something meaningful.
2. **Never swallow errors silently** - At minimum, log them.
3. **Use typed errors** - Prefer specific error types over generic `Error`.
4. **Fail fast** - Validate inputs early rather than letting invalid data propagate.

### Patterns

```typescript
// BAD: Swallowed error
try {
	await riskyOperation();
} catch (e) {
	// silently ignored
}

// BAD: Catching too broadly
try {
	const data = await fetchData();
	processData(data);
	renderUI(data);
} catch (e) {
	console.log('Something went wrong');
}

// GOOD: Specific handling with context
try {
	const data = await fetchData();
} catch (error) {
	if (error instanceof NetworkError) {
		new Notice('Network unavailable. Please check your connection.');
		logger.warn('Network error during fetch:', error.message);
		return null;
	}
	// Re-throw unexpected errors
	throw error;
}
```

### Async error handling

```typescript
// BAD: Unhandled promise rejection
someAsyncFunction(); // floating promise

// GOOD: Always await or catch
await someAsyncFunction();

// GOOD: Fire-and-forget with error handling
someAsyncFunction().catch((e) => logger.error('Background task failed:', e));
```

## Naming and readability

### Function and variable names

- **Functions**: Use verb phrases that describe what they do (`fetchUserData`, `validateInput`, `buildContextTree`).
- **Booleans**: Use `is`, `has`, `should`, `can` prefixes (`isValid`, `hasPermission`, `shouldRetry`).
- **Collections**: Use plural nouns (`files`, `tags`, `pendingRequests`).
- **Constants**: Use UPPER_SNAKE_CASE for true constants (`MAX_RETRIES`, `DEFAULT_TIMEOUT`).
- **Avoid abbreviations**: `error` not `err`, `result` not `res`, `response` not `resp` (except in very tight scopes like callbacks).

(Defer to `config.guidelines.coding` where the repo's naming conventions are more specific — e.g.
`snake_case` functions in a Python repo.)

### Code structure

- **Early returns**: Reduce nesting by returning early for error cases.
- **Guard clauses**: Check preconditions at the top of functions.
- **Consistent abstraction levels**: A function should operate at one level of abstraction.

```typescript
// BAD: Deep nesting
async function processFile(path: string) {
	const file = vault.getAbstractFileByPath(path);
	if (file) {
		if (file instanceof TFile) {
			const content = await vault.read(file);
			if (content.length > 0) {
				// actual logic buried here
			}
		}
	}
}

// GOOD: Early returns
async function processFile(path: string) {
	const file = vault.getAbstractFileByPath(path);
	if (!(file instanceof TFile)) {
		return;
	}

	const content = await vault.read(file);
	if (content.length === 0) {
		return;
	}

	// actual logic at top level
}
```

## Language-specific guidance

Branch this section on `config.language`.

### When `config.language` is `typescript`

#### Type safety

- **Avoid `any`**: Use `unknown` when the type is genuinely unknown, then narrow with type guards.
- **Use discriminated unions** over type assertions.
- **Prefer `interface` for object shapes** that may be extended; use `type` for unions, intersections, and aliases.

```typescript
// BAD: any everywhere
function process(data: any): any {
	return data.value;
}

// GOOD: Proper typing
interface ProcessInput {
	value: string;
	metadata?: Record<string, unknown>;
}

function process(data: ProcessInput): string {
	return data.value;
}
```

#### Null handling

```typescript
// BAD: Non-null assertion hiding potential bugs
const file = vault.getAbstractFileByPath(path)!;

// GOOD: Explicit null check
const file = vault.getAbstractFileByPath(path);
if (!file) {
	throw new Error(`File not found: ${path}`);
}
```

#### Async patterns

- Never mix callbacks and promises in the same flow.
- Use `Promise.all()` for independent concurrent operations.
- Use `Promise.allSettled()` when partial failures are acceptable.
- Always handle rejections.

See [reference/typescript-patterns.md](references/typescript-patterns.md) for a fuller catalog of
TypeScript/JavaScript patterns and anti-patterns.

### When `config.language` is `python`

Apply the repo's Python conventions from `config.guidelines.coding` rather than the TypeScript
examples above. The same underlying principles carry over — favor precise types over escape hatches,
make `None`/optional handling explicit, and keep async and sync code from blocking each other:

- **Typing**: prefer precise type hints; treat `Any`, `cast(Any, ...)`, and `# type: ignore` as
  smells that need justification (mirror of "avoid `any`" above).
- **Optional handling**: handle `None` explicitly with guard clauses instead of letting it propagate;
  avoid silently truthy/falsy checks where `None` and empty are different.
- **Errors**: no bare `except:`; catch specific exceptions and log with context (see Error handling
  above).
- **Concurrency**: don't block the event loop with sync I/O inside `async def`; run independent
  awaitables concurrently (`asyncio.gather`) the way `Promise.all` is used above.
- **Logging**: use the repo's logger, never `print()` in library code.

Whatever the repo's `coding.md` says about runner prefix, naming, banned patterns, and logging is
authoritative — defer to it.

## Performance checklist

When reviewing for performance:

1. **Unnecessary re-computation**: Is the same value computed multiple times in a loop? Cache it.
2. **N+1 queries**: Are API calls, DB queries, or file reads happening inside loops? Batch them.
3. **Large data in memory**: Are entire files/records loaded when only metadata is needed? Load only what you use.
4. **Missing debounce**: Are event handlers (editor changes, resize, input) triggering expensive operations on every event?
5. **Synchronous blocking**: Are heavy computations blocking the main thread or event loop? Offload or chunk them.
6. **Unnecessary repeated allocations**: Are objects/elements being created and discarded when they could be reused or batched?

## Security checklist

1. **No dynamic code execution**: Avoid `eval()` / `new Function()` (TS/JS) or `eval`/`exec` (Python) on untrusted input.
2. **No unsafe HTML injection**: Don't build DOM from untrusted strings (`innerHTML`); use safe DOM/templating helpers.
3. **Sanitize user input**: Especially file paths, search queries, SQL/command arguments, and template variables.
4. **No hardcoded secrets**: API keys, tokens, and credentials belong in settings/secret stores, never in source.
5. **Validate external data**: API responses, file contents, and deserialized data should be validated before use.
6. **Use the repo's sanctioned APIs**: e.g. the platform's network/path helpers rather than raw primitives where the repo requires it (check `config.guidelines.coding` and any domain guidance).

## Testing review

When reviewing tests, apply the repo's conventions from `config.guidelines.testing` first, then these
generics:

1. **Test behavior, not implementation**: Tests should assert observable outcomes, not internal details.
2. **One assertion concept per test**: Each test should verify one logical condition (may use multiple assertions if they test the same concept).
3. **Descriptive test names**: `returns empty array when the source has no matching files` not `test1`.
4. **Edge cases covered**: Empty inputs, null values, boundary conditions, error paths.
5. **No test interdependence**: Tests must not depend on execution order or shared mutable state.
6. **Mocks are minimal**: Only mock what's necessary. Over-mocking makes tests brittle and less valuable.

For a deeper, suite-wide test-quality pass (coverage gaps, mocking strategy, fixture smells, flaky
patterns), point the user at the **audit-tests** skill.

## Review comment guidelines

When writing review feedback:

1. **Be specific**: Point to the exact line and explain what's wrong and why.
2. **Suggest alternatives**: Don't just say "this is wrong" - show a better approach.
3. **Distinguish severity**: Mark issues as blocking (must fix), suggestion (should fix), or nit (optional).
4. **Explain the "why"**: Link to the principle being violated so the author learns, not just fixes.
5. **Acknowledge good work**: Call out well-designed code, clean refactors, or thorough tests.

## Scope boundaries

Keep this skill focused on the quality of the code under review. For concerns that fall outside a
single diff:

- **Structural / tech-debt findings** (oversized files, codebase-wide DRY violations, dead code,
  weak abstractions) → the **audit-architecture** skill.
- **Test-suite quality** (coverage strategy, mocking patterns, fixtures, flakiness) → the
  **audit-tests** skill.

## Further reading

- [Review Checklist](references/review-checklist.md) - Quick-reference checklist for code reviews
- [TypeScript Patterns](references/typescript-patterns.md) - Patterns and anti-patterns for TypeScript/JavaScript codebases (applies when `config.language` is `typescript`)
