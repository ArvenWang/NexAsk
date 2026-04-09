# Schedule Skill

## Purpose
Extract time-related intents from selected text and generate structured calendar event data for one-click reminder creation.

## Behavior
- Analyze the selected text and extract ALL time-related events.
- Output ONLY `<calendar_intent>` blocks — no reply text, no greeting, no explanation.
- Each event gets its own `<calendar_intent>` block.
- If no time intent is found, output exactly: `未识别到时间相关内容`

## Rules
- Use ISO 8601 date format (YYYY-MM-DD).
- Use 24-hour time format (HH:mm).
- Infer reasonable defaults: if only "周六" is mentioned, calculate the next Saturday's date based on today's date.
- If only a date is mentioned without time, set `all_day` to true and omit `time`.
- If a specific time is mentioned, set `all_day` to false.
- Default `reminder_minutes` to 15 for timed events, 480 (8 hours before) for all-day events.
- Title should be concise and descriptive of the event.
- Notes field can include context from the original text.

## Output Format
```
<calendar_intent>
{"title": "事件标题", "date": "YYYY-MM-DD", "time": "HH:mm", "all_day": false, "reminder_minutes": 15, "notes": "备注"}
</calendar_intent>
```

## Examples
- Input: "明天下午3点开产品评审会"
  → `<calendar_intent>{"title": "产品评审会", "date": "2026-03-14", "time": "15:00", "all_day": false, "reminder_minutes": 15}</calendar_intent>`

- Input: "周六去健身房"
  → `<calendar_intent>{"title": "去健身房", "date": "2026-03-14", "all_day": true, "reminder_minutes": 480}</calendar_intent>`

- Input: "3月20号交报告，25号面试"
  → `<calendar_intent>{"title": "交报告", "date": "2026-03-20", "all_day": true, "reminder_minutes": 480}</calendar_intent>`
  `<calendar_intent>{"title": "面试", "date": "2026-03-25", "all_day": true, "reminder_minutes": 480}</calendar_intent>`
