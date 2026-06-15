# Team-wide active preferences

Canonical file for **team-wide** operating preferences — rules that every agent
in the install follows. It is the team-scope counterpart to each agent's
per-agent `ACTIVE-PREFERENCES.md`, and it is loaded by every agent via the
`common-instructions.md` pointer.

See [`user-preference-injection.md`](user-preference-injection.md) for the full
promotion lifecycle (detection → candidate → admin approval → write).

## Status

No team-wide preferences promoted yet.

## Write rules

- **Admin-only.** Only the admin agent appends here, and only after approving a
  team-scope promotion candidate per `user-preference-injection.md` §6. Direct
  edits by non-admin agents are prohibited.
- **One entry per rule**, appended below using the standard entry format. Keep
  entries short and durable — a single-sentence directive plus its reasoning.

## Entry format

```markdown
## <short rule title> (YYYY-MM-DD, scope: team)

<one-sentence directive>

- **Why**: <reasoning / triggering context>
- **Source**: <issue, session, or user request that prompted it>
```

<!-- Approved team-wide preferences are appended below this line. -->
