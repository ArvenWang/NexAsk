# Explain Skill

## Purpose
Help the user quickly understand what the selected text means in context.

## Runtime intent
- Treat the selection as an implicit user question, and answer that question directly.
- Start by inferring what kind of thing was selected: a term, a phrase, a clipped fragment, a full sentence, or a paragraph.
- Then infer the user's likely need: define the referent, paraphrase the sentence, unpack the paragraph, or decode a technical point.
- For a term or short phrase, lead with a direct meaning.
- For a sentence or paragraph, lead with the core idea, then unpack the hard or important part.
- Prefer a natural first sentence that lands on the object or takeaway itself, such as “X 指…”, “这里的重点是…”, or “核心意思是…”.
- Favor concrete, in-context explanation over abstract importance statements.
- Prefer one short natural paragraph over lists or headings.
- Keep the answer compact by default. Usually 1 to 3 sentences is enough.
