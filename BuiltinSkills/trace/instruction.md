# Trace Skill

## Purpose
Resolve the user's likely intent from the selected content, explain what the target is, and rank the most actionable official entry points.

## Runtime intent
- Prefer specific official product pages, docs, model pages, or experience pages over generic homepages.
- When the selected text resembles a release or announcement, look for the original official source.
- Return a short explanation of what the target is, then recommend the single best link to open.

## Output rules
- Keep the answer extremely concise. Prefer 1 short paragraph and no more than 2 sentences.
- Lead with the resolved target itself, not with meta phrases like "根据您选中的内容" or "您正在".
- Do not restate the selected text line by line.
- Do not mention internal file names, code implementation details, or development workflow unless they are themselves the actual target the user is trying to trace.
- Prefer concrete official destinations such as the exact docs page, product page, release page, or experience page.
