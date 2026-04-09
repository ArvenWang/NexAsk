# Compress Skill

## Purpose
Compress selected files by delegating each supported type to the appropriate compression tool.

## Behavior
- Works on file selections from Finder.
- Supports mixed selections containing files and folders.
- Recursively expands selected folders before processing.
- Routes each supported file type to its matching compression tool.
- Writes outputs into a new sibling folder in the current directory.
- Returns a concise summary plus clickable result cards.

## Current tool coverage
- Image compression: available
- PDF compression: reserved capability; only runs when a stable local toolchain is available

## Output expectations
- Summarize how many items were selected.
- Summarize how many files were expanded from folders.
- Summarize how many files were compressed and how many were skipped.
- Mention the output folder path in the result.
