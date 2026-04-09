#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ask_smoke_common.sh"

if [[ $# -ge 1 ]]; then
  APP_PATH="$1"
  EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
fi

STATE_FILE="$(mktemp /tmp/nexhub_ask_coding_state.XXXXXX).json"
APPROVAL_SCREENSHOT="/tmp/nexhub_ask_coding_approval.png"
RESULT_SCREENSHOT="/tmp/nexhub_ask_coding_result.png"
PROMPT_TEXT="${NEXHUB_SMOKE_ASK_CODING_PROMPT:-Create a very small calculator app in the Playground using exactly three compact local files: index.html, style.css, and script.js. Write every file directly with workspace file tools, keep all assets fully local, do not use external CDNs, remote fonts, icon packs, package managers, or any network access, and automatically open index.html when finished.}"

[[ -d "$APP_PATH" ]] || fail "Installed app missing: $APP_PATH"

quit_app_if_running
reset_persisted_ask_sessions
launch_app
wait_for_app_process 80 || fail "App process is not running after launch."
sleep 2
pass "Installed app launched for coding ASK smoke."

draw_real_ask_box
wait_for_state_condition "$STATE_FILE" 'data.get("isVisible") is True and data.get("isUsingPersistentAskSessionShell") is True' 80 || fail "ASK shell did not appear after real draw-box entry."
pass "Real draw-box ASK entry is available for coding flow."

dump_ask_state "$STATE_FILE"
wait_for_state_file "$STATE_FILE" 20 || fail "Failed to dump initial ASK coding state."
if [[ "$(json_read "$STATE_FILE" "hasPendingApproval")" == "true" ]]; then
  post_smoke_run_ask "cancel" "true" "true" "true"
  wait_for_state_condition "$STATE_FILE" 'data.get("hasPendingApproval") is False and data.get("isStreaming") is False' 120 || fail "Failed to clear a previously restored ASK approval before starting the coding smoke."
fi

post_smoke_run_ask "$PROMPT_TEXT" "true" "true" "true"

dump_ask_state "$STATE_FILE"
wait_for_state_file "$STATE_FILE" 20 || fail "Failed to dump ASK coding approval state."
wait_for_state_condition "$STATE_FILE" 'data.get("hasPendingApproval") is True and data.get("pendingApprovalConfirmEnabled") is True and data.get("isStreaming") is False' 240 || fail "Task-level execution approval did not reach an actionable waiting state."

[[ "$(json_read "$STATE_FILE" "hasPendingApproval")" == "true" ]] || fail "Expected a pending approval card for Playground execution."
[[ "$(json_read "$STATE_FILE" "hasSupplementaryChrome")" == "false" ]] || fail "Supplementary ASK chrome is still visible during coding flow."
[[ "$(json_read "$STATE_FILE" "transcriptContainsKernelPreparedTask")" == "false" ]] || fail "\"Kernel prepared task\" leaked into the transcript."

capture_screenshot "$APPROVAL_SCREENSHOT"

post_smoke_run_ask "confirm" "true" "true" "true"
wait_for_state_condition "$STATE_FILE" '(data.get("hasPendingApproval") is False) or (data.get("isStreaming") is True and data.get("pendingApprovalConfirmEnabled") is False)' 60 || fail "Task-scoped approval did not advance cleanly after confirming."
wait_for_state_condition "$STATE_FILE" 'data.get("didObserveRuntimeCodePreview") is True and float(data.get("maxObservedRuntimeCodePreviewHeight") or 0) > 0' 180 || fail "Coding flow never surfaced a visible code preview after approval."
CODE_PREVIEW_HEIGHT="$(json_read "$STATE_FILE" "maxObservedRuntimeCodePreviewHeight")"
wait_for_state_condition "$STATE_FILE" 'data.get("isStreaming") is False and bool(data.get("activeTaskWorkspaceRoot"))' 240 || fail "Coding task did not finish with a Playground workspace."

dump_ask_state "$STATE_FILE"
wait_for_state_file "$STATE_FILE" 20 || fail "Failed to dump final ASK coding state."

/usr/bin/python3 - "$CODE_PREVIEW_HEIGHT" <<'PY'
import sys
value = float(sys.argv[1] or "0")
sys.exit(0 if 0 < value <= 72 else 1)
PY
pass "Runtime code preview is capped and scrollable."

WORKSPACE_ROOT="$(json_read "$STATE_FILE" "activeTaskWorkspaceRoot")"
[[ -n "$WORKSPACE_ROOT" ]] || fail "No Playground workspace root was recorded."
[[ -d "$WORKSPACE_ROOT" ]] || fail "Recorded Playground workspace does not exist: $WORKSPACE_ROOT"
[[ "$(json_read "$STATE_FILE" "hasPendingApproval")" == "false" ]] || fail "Coding task finished with another pending approval still visible."
[[ "$(json_read "$STATE_FILE" "hasSupplementaryChrome")" == "false" ]] || fail "Supplementary ASK chrome reappeared after coding finished."

HTML_PATH="$(/usr/bin/python3 - "$WORKSPACE_ROOT" <<'PY'
import os
import sys
root = sys.argv[1]
matches = []
for current_root, _, files in os.walk(root):
    for name in files:
        if name.lower().endswith(".html"):
            matches.append(os.path.join(current_root, name))
matches.sort()
print(matches[0] if matches else "")
PY
)"
[[ -n "$HTML_PATH" ]] || fail "No HTML artifact was created in the Playground workspace."
[[ -f "$HTML_PATH" ]] || fail "Expected HTML artifact is missing: $HTML_PATH"

ARTIFACT_DIR="$(dirname "$HTML_PATH")"
CSS_PATH="$ARTIFACT_DIR/style.css"
SCRIPT_PATH="$ARTIFACT_DIR/script.js"
[[ -f "$CSS_PATH" ]] || fail "Expected CSS artifact is missing: $CSS_PATH"
[[ -f "$SCRIPT_PATH" ]] || fail "Expected script artifact is missing: $SCRIPT_PATH"
[[ -s "$CSS_PATH" ]] || fail "Generated CSS artifact is empty: $CSS_PATH"
[[ -s "$SCRIPT_PATH" ]] || fail "Generated script artifact is empty: $SCRIPT_PATH"
pass "Playground coding artifacts were created."

/usr/bin/python3 - "$HTML_PATH" "$CSS_PATH" "$SCRIPT_PATH" <<'PY'
import pathlib
import re
import sys

html_path = pathlib.Path(sys.argv[1])
css_path = pathlib.Path(sys.argv[2])
script_path = pathlib.Path(sys.argv[3])
html = html_path.read_text(encoding="utf-8")
css = css_path.read_text(encoding="utf-8")
script = script_path.read_text(encoding="utf-8")

def fail(message: str) -> None:
    print(message)
    sys.exit(1)

def html_has_class(name: str) -> bool:
    return re.search(r'class=["\'][^"\']*\b' + re.escape(name) + r'\b[^"\']*["\']', html) is not None

def html_has_id(name: str) -> bool:
    return re.search(r'id=["\']' + re.escape(name) + r'["\']', html) is not None

def html_classes() -> set[str]:
    classes: set[str] = set()
    for class_value in re.findall(r'class=["\']([^"\']+)["\']', html):
        for token in class_value.split():
            if token:
                classes.add(token)
    return classes

def css_classes() -> set[str]:
    return set(re.findall(r'\.([A-Za-z_][A-Za-z0-9_-]*)', css))

sanitized_html = re.sub(r'data:[^"\']+', '', html)
combined_without_data_uris = "\n".join([sanitized_html, css, script])
if re.search(r"https?://", combined_without_data_uris, re.IGNORECASE):
    fail("generated artifact still references a remote URL")

for selector in sorted(set(re.findall(r'querySelector(?:All)?\(\s*[\'"]([.#][A-Za-z0-9_-]+)[\'"]\s*\)', script))):
    if selector.startswith("."):
        token = selector[1:]
        if not html_has_class(token):
            fail(f"script references missing HTML class selector: {selector}")
    else:
        token = selector[1:]
        if not html_has_id(token):
            fail(f"script references missing HTML id selector: {selector}")

for element_id in sorted(set(re.findall(r'getElementById\(\s*[\'"]([A-Za-z0-9_-]+)[\'"]\s*\)', script))):
    if not html_has_id(element_id):
        fail(f"script references missing HTML id: #{element_id}")

for data_selector in sorted(set(re.findall(r'querySelector(?:All)?\(\s*[\'"]\[([A-Za-z0-9_-]+)\][\'"]\s*\)', script))):
    if re.search(r'\b' + re.escape(data_selector) + r'\s*=', html) is None:
        fail(f"script references missing HTML data hook: [{data_selector}]")

unmatched_html_classes = sorted(
    token for token in html_classes() - css_classes()
    if not token.startswith(("js-", "is-", "has-"))
)
if len(unmatched_html_classes) >= 3:
    fail(
        "html uses layout classes that have no matching CSS rule: "
        + ", ".join(unmatched_html_classes[:4])
    )

checks = [
    ('href="style.css"' in html or "href='style.css'" in html, "index.html does not reference local style.css"),
    ('src="script.js"' in html or "src='script.js'" in html, "index.html does not reference local script.js"),
    (css.strip() != "", "style.css is empty after generation"),
    (script.strip() != "", "script.js is empty after generation"),
]

for ok, message in checks:
    if not ok:
        fail(message)
PY
pass "Playground artifact stayed self-contained with local style and script references."

CATALOG_PATH="$ASK_PLAYGROUND_CATALOG_FILE"
[[ -f "$CATALOG_PATH" ]] || fail "Playground catalog was not written."
/usr/bin/python3 - "$CATALOG_PATH" "$WORKSPACE_ROOT" <<'PY'
import json
import sys
catalog_path, workspace_root = sys.argv[1], sys.argv[2]
with open(catalog_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
artifacts = data.get("artifacts", [])
matched = any(item.get("rootPath") == workspace_root for item in artifacts)
sys.exit(0 if matched else 1)
PY
pass "Playground catalog recorded the coding artifact."

sleep 2
FRONTMOST_APP="$(frontmost_app_name)"
LATEST_STEP_TITLE="$(json_read "$STATE_FILE" "latestRuntimeStepTitle")"
LATEST_STEP_DETAIL="$(json_read "$STATE_FILE" "latestRuntimeStepDetail")"
if [[ "$FRONTMOST_APP" =~ ^(Safari|Google\ Chrome|Arc|Microsoft\ Edge|Firefox|Finder)$ ]]; then
  pass "Generated result was opened automatically in a user-visible app: $FRONTMOST_APP."
elif [[ "$LATEST_STEP_TITLE" == *"打开"* || "$LATEST_STEP_TITLE" == *"open"* || "$LATEST_STEP_DETAIL" == *"打开"* || "$LATEST_STEP_DETAIL" == *"open"* ]]; then
  pass "Coding flow recorded an automatic open step."
else
  fail "Coding flow finished, but no automatic open could be verified."
fi

capture_screenshot "$RESULT_SCREENSHOT"

echo "State file: $STATE_FILE"
echo "Approval screenshot: $APPROVAL_SCREENSHOT"
echo "Result screenshot: $RESULT_SCREENSHOT"
echo "Workspace root: $WORKSPACE_ROOT"
echo "HTML artifact: $HTML_PATH"
echo "Catalog: $CATALOG_PATH"
