// Minimal ambient declaration for the `bun:test` API used by
// cardintent.test.ts, so the plugin's `bun run typecheck` does NOT need the
// `bun-types` devDependency in node_modules.
//
// Why: the plugin-cache seed (bridge-dev-plugin-cache.py) treats every nested
// `package.json` — including `node_modules/bun-types/package.json` — as a
// channel-required contract file, but the node_modules copy skipped bun-types,
// so the teams plugin failed to link into the cache (`linked-failed`,
// channel-required) and could not be re-seeded (#16828). bun-types is a
// type-only devDependency (bun provides `bun:test` natively at runtime), so
// dropping it from node_modules removes the seed hazard entirely; this shim
// satisfies tsc for the test file's `bun:test` import. `expect()` returns the
// loose matcher chain as `any` on purpose — the runtime assertions are
// exercised by `bun test`, not the type-checker.

declare module 'bun:test' {
  export const describe: (name: string, fn: () => void) => void
  export const test: (name: string, fn: () => void | Promise<void>) => void
  // deno-lint-ignore no-explicit-any
  export const expect: (actual: unknown) => any
}
