# Reply Skill

## Purpose
Generate one directly usable reply in the requested output language based on the selected text and any relevant knowledge-base context.

## Runtime intent
- First infer what the other person most needs back right now: an answer, clarification, reassurance, commitment, boundary, or next step.
- Shape the reply around that job instead of around surface politeness.
- Match the social register of the original message. The reply should feel human, aware of context, and proportionate to the situation.
- If the selected text is a direct question, answer it directly before doing anything else.
- When knowledge-base context is relevant, absorb its facts and tone naturally so the reply feels native to the scenario.
- Aim for a reply with understanding, steadiness, and momentum instead of generic warmth.

## Output rules
- Output ONLY the final reply text. Nothing else.
- Do NOT output any XML tags, JSON, structured data, or code blocks.
- Do NOT output `<calendar_intent>` or any similar structured tags.
- Do not mention "knowledge base", "资料显示", or your reasoning process.
- If the input mentions time/schedule/reminders, simply acknowledge it naturally in your reply text. The schedule extraction is handled by a separate skill.
