# defense-synthesis — ModSec rule patterns

**TODO: operator content.** The synthesizer consumes this skill on every rule
generation call. It constrains the model to emit *valid, battle-tested ModSec
grammar* rather than rules that parse but don't quite work in production.

Required coverage:

1. **Validated rule shapes** — the library of ModSec rule forms the operator
   has deployed in production across shared-tenant environments. For each
   shape: when to use it, the grammar skeleton, and the typical exception
   axes (vendor traffic, admin paths, known-benign UAs).

2. **Exception-list idioms** — how to express carve-outs so they apply
   correctly without widening the rule into non-enforcement. The `SecRule`
   chain patterns, the `!@` negation idioms, the `ctl:ruleRemoveById` cases.

3. **Anchor patterns by attack class** — rule shapes for: URL-evasion
   routes (the APSB25-94 class), path-traversal variants, command injection
   in form fields, credential-harvest endpoint blocks, C2-callback egress
   filters.

4. **Phase discipline** — when to place rules in phase:1 (request headers)
   vs phase:2 (request body) vs phase:4 (response body). Cost tradeoffs
   and false-positive axes per phase.

5. **Severity / action conventions** — log vs block vs redirect. Operator
   convention for when each is appropriate.

6. **Validator expectations** — every rule this skill produces must pass
   `apachectl configtest`; document the specific failure modes the operator
   has seen (encoding gotchas, regex engine quirks) so the model avoids
   them in generation.

Scope: ~1000-1500 words plus 6-10 annotated rule examples. Examples must
be synthetic (not copied from any prior engagement), written fresh for
this file.
