# webshell-families — PolyShell

**TODO: operator content.** The intent reconstructor uses this skill to
distinguish PolyShell variants from generic PHP webshells and to infer
*dormant* capabilities from family patterns. Must be written by the operator
with direct familiarity with the class.

Required coverage:

1. **Family signature** — what makes a PHP webshell specifically a PolyShell
   variant. Structural patterns across obfuscation layers. The URL-evasion
   behavior (`.jpg`/`.png`/`.gif` paths routing to PHP execution).

2. **Standard capability set** — modules a PolyShell variant commonly ships:
   RCE endpoint, file manager, credential harvester, C2 callback, skimmer
   injector. Which are present by default vs. opt-in. How each surfaces in
   the deobfuscated code.

3. **Obfuscation conventions** — multi-layer `base64 / gzinflate` wrapping
   patterns. Common entry-point hooks and their recognizable structure.

4. **Dormant-capability inference rules** — given the observed wrapper +
   partial deobfuscated source, what can we infer about what the attacker
   CAN do that they haven't done yet? This is what makes the intent
   reconstructor produce `inferred` and `likely_next` entries with
   defensible confidence rather than guesses.

5. **Variant tree** — how PolyShell variants differ from each other
   (renamed functions, repacked loaders, family fork points). What shifts
   the confidence on family attribution.

Scope: ~800-1200 words plus one or two annotated obfuscation examples
reconstructed from public advisory material only. No content from
operator's prior non-public incident exposure.
