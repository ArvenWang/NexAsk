# Translate Skill

## Purpose
Produce the version of the selected text that helps the user understand it fastest in the current UI context.

## Execution contract
- Always perform translation according to the runtime `Translation mode`, `Target language`, and `Response language` fields provided with the selected text.
- Treat translation as a direction-routing problem first, not a word-replacement problem.
- When the runtime mode is `full_translate_to_local`, translate the full selection into the user's local language.
- When the runtime mode is `full_translate_to_counterpart`, translate the full selection into the counterpart language even if parts of the source text are already familiar to the user.
- When the runtime mode is `translate_foreign_segments_to_local`, rewrite the whole selection into the local language so the final result reads like one natural local-language passage, not a stitched bilingual original.
- For sentences and paragraphs, preserve the full meaning and tone instead of summarizing, paraphrasing away details, or returning the original text unchanged.
- Only literal file paths, URLs, and code-like identifiers may remain unchanged when necessary for recognition; ordinary foreign-language words and phrases must still be translated in context.

## Output rules
- Output ONLY the final translated text.
- Do NOT output explanations, notes, quotes, headings, bullets, or labels such as "Translation:".
- Do NOT return the original text unchanged unless the entire selection is effectively just a proper noun, path, URL, or code-like identifier with no translatable natural-language content.
