#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ask_smoke_common.sh"

STATE_FILE="$(mktemp /tmp/nexhub_ask_persistence_state.XXXXXX).json"
SCREENSHOT_FILE="/tmp/nexhub_ask_persistence.png"
INITIAL_PROMPT="ASK persistence baseline"
RESTORED_DRAFT="draft survives reopen"
PROACTIVE_CONTINUE_PROMPT="continue after proactive popup"
INBOX_CONTINUE_PROMPT="continue after inbox"
FOLLOW_UP_WORKSPACE="/tmp/nexhub-ask-followup"
FOLLOW_UP_RESUME_TOKEN="resume-ask-inbox-1"
FOLLOW_UP_TASK_ID="task-ask-inbox-1"
FOLLOW_UP_JOB_ID="job-ask-followup-1"
FOLLOW_UP_RUN_ID="run-ask-followup-1"
PROACTIVE_JOB_ID="job-ask-proactive-1"
PROACTIVE_RUN_ID="run-ask-proactive-1"
NOTIFICATION_TASK_ID="task-ask-notification-1"

post_smoke_run_ask() {
  local prompt="$1"
  local submit="$2"
  local reuse_visible="$3"
  local persistent_session="$4"
  local response="${5:-}"
  local trace_file="${6:-}"

  NEXHUB_SMOKE_PROMPT="$prompt" \
  NEXHUB_SMOKE_SUBMIT="$submit" \
  NEXHUB_SMOKE_REUSE_VISIBLE="$reuse_visible" \
  NEXHUB_SMOKE_PERSISTENT_SESSION="$persistent_session" \
  NEXHUB_SMOKE_RESPONSE="$response" \
  NEXHUB_SMOKE_TRACE_FILE="$trace_file" \
  NEXHUB_SMOKE_NAMESPACE="$SMOKE_NAMESPACE" \
  /usr/bin/swift - <<'SWIFT'
import Foundation

let env = ProcessInfo.processInfo.environment
var userInfo: [AnyHashable: Any] = [
    "prompt": env["NEXHUB_SMOKE_PROMPT"] ?? "",
    "submit": env["NEXHUB_SMOKE_SUBMIT"] ?? "true",
    "reuse_visible": env["NEXHUB_SMOKE_REUSE_VISIBLE"] ?? "false",
    "persistent_session": env["NEXHUB_SMOKE_PERSISTENT_SESSION"] ?? "false"
]
if let response = env["NEXHUB_SMOKE_RESPONSE"], !response.isEmpty {
    userInfo["response"] = response
}
if let traceFile = env["NEXHUB_SMOKE_TRACE_FILE"], !traceFile.isEmpty {
    userInfo["trace_file"] = traceFile
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("\(env["NEXHUB_SMOKE_NAMESPACE"] ?? "nexhub").smoke.runAsk"),
    object: nil,
    userInfo: userInfo,
    deliverImmediately: true
)
SWIFT
}

post_smoke_follow_up() {
  local title="$1"
  local summary="$2"
  local delivery_channel="$3"
  local active_task_id="$4"
  local resume_token="$5"
  local workspace_root="$6"
  local source_job_id="$7"
  local source_run_id="$8"

  NEXHUB_FOLLOWUP_TITLE="$title" \
  NEXHUB_FOLLOWUP_SUMMARY="$summary" \
  NEXHUB_FOLLOWUP_CHANNEL="$delivery_channel" \
  NEXHUB_FOLLOWUP_TASK_ID="$active_task_id" \
  NEXHUB_FOLLOWUP_RESUME_TOKEN="$resume_token" \
  NEXHUB_FOLLOWUP_WORKSPACE_ROOT="$workspace_root" \
  NEXHUB_FOLLOWUP_SOURCE_JOB_ID="$source_job_id" \
  NEXHUB_FOLLOWUP_SOURCE_RUN_ID="$source_run_id" \
  NEXHUB_SMOKE_NAMESPACE="$SMOKE_NAMESPACE" \
  /usr/bin/swift - <<'SWIFT'
import Foundation

let env = ProcessInfo.processInfo.environment
var activation: [String: Any] = [
    "title": env["NEXHUB_FOLLOWUP_TITLE"] ?? "Assistant follow-up",
    "summary": env["NEXHUB_FOLLOWUP_SUMMARY"] ?? "Continue the previous assistant task.",
    "kind": "assistant_update"
]

func assign(_ key: String, from envKey: String) {
    if let value = env[envKey], !value.isEmpty {
        activation[key] = value
    }
}

assign("activeTaskID", from: "NEXHUB_FOLLOWUP_TASK_ID")
assign("sourceTaskID", from: "NEXHUB_FOLLOWUP_TASK_ID")
assign("resumeToken", from: "NEXHUB_FOLLOWUP_RESUME_TOKEN")
assign("workspaceRoot", from: "NEXHUB_FOLLOWUP_WORKSPACE_ROOT")
assign("sourceJobID", from: "NEXHUB_FOLLOWUP_SOURCE_JOB_ID")
assign("sourceRunID", from: "NEXHUB_FOLLOWUP_SOURCE_RUN_ID")
assign("deliveryChannel", from: "NEXHUB_FOLLOWUP_CHANNEL")

let payloadObject: [String: Any] = [
    "kind": "assistant_followup_activation",
    "version": 1,
    "activation": activation
]

guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject, options: []),
      let payload = String(data: payloadData, encoding: .utf8) else {
    exit(1)
}

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("\(env["NEXHUB_SMOKE_NAMESPACE"] ?? "nexhub").smoke.openAssistantFollowUp"),
    object: nil,
    userInfo: ["assistant_followup_activation_payload": payload],
    deliverImmediately: true
)
SWIFT
}

[[ -d "$APP_PATH" ]] || fail "Installed app missing: $APP_PATH"
mkdir -p "$FOLLOW_UP_WORKSPACE"

quit_app_if_running
launch_app
wait_for_app_process 80 || fail "App process is not running after launch."
sleep 2
pass "Installed app launched for ASK persistence smoke."

post_smoke_run_ask "$INITIAL_PROMPT" "true" "false" "true" "ASK session baseline reply."
wait_for_state_condition "$STATE_FILE" 'data.get("isUsingPersistentAskSessionShell") is True and data.get("assistantMessageCount", 0) >= 1 and data.get("hasSupplementaryChrome") is False' 160 || fail "ASK baseline session did not start cleanly."
INITIAL_SESSION_ID="$(json_read "$STATE_FILE" "sessionID")"
[[ -n "$INITIAL_SESSION_ID" ]] || fail "ASK baseline session did not record a session ID."
INITIAL_INVOCATION_COUNT="$(json_read "$STATE_FILE" "persistentAskInvocationCount")"
[[ "$INITIAL_INVOCATION_COUNT" =~ ^[0-9]+$ ]] || fail "ASK baseline invocation count is missing."
pass "ASK baseline session started with a persistent shell."

post_smoke_run_ask "$RESTORED_DRAFT" "false" "true" "true"
wait_for_state_condition "$STATE_FILE" "data.get('sessionID') == '$INITIAL_SESSION_ID' and data.get('composerText') == '$RESTORED_DRAFT'" 80 || fail "Composer draft did not populate inside the ASK session."
pass "ASK draft was staged before relaunch."

quit_app_if_running
launch_app
wait_for_app_process 80 || fail "App process did not relaunch for ASK restore smoke."
sleep 2
post_smoke_run_ask "" "false" "false" "true"
wait_for_state_condition "$STATE_FILE" "data.get('sessionID') == '$INITIAL_SESSION_ID' and data.get('composerText') == '$RESTORED_DRAFT' and data.get('assistantMessageCount', 0) >= 1 and data.get('isUsingPersistentAskSessionShell') is True and data.get('hasSupplementaryChrome') is False" 120 || fail "ASK session did not restore its history and draft after relaunch."
pass "ASK restored the existing session after relaunch."

post_smoke_automation_run \
  "$PROACTIVE_RUN_ID" \
  "$PROACTIVE_JOB_ID" \
  "Automation result needs a decision." \
  "completed" \
  "$FOLLOW_UP_TASK_ID" \
  "$FOLLOW_UP_WORKSPACE"
wait_for_state_condition "$STATE_FILE" "data.get('sessionID') == '$INITIAL_SESSION_ID' and data.get('isShowingProactivePopup') is True and bool(data.get('proactiveHintText')) and int(data.get('persistentAskInvocationCount') or 0) >= $(($INITIAL_INVOCATION_COUNT + 1))" 120 || fail "ASK did not show a proactive popup from the latest automation result."
PROACTIVE_INVOCATION_COUNT="$(json_read "$STATE_FILE" "persistentAskInvocationCount")"
[[ "$PROACTIVE_INVOCATION_COUNT" =~ ^[0-9]+$ ]] || fail "ASK proactive popup did not record a new invocation."
pass "ASK showed a proactive popup from the automation result while reusing the same session."

post_smoke_run_ask "$PROACTIVE_CONTINUE_PROMPT" "true" "true" "true" "Still in the same ASK session after proactive popup."
wait_for_state_condition "$STATE_FILE" "data.get('sessionID') == '$INITIAL_SESSION_ID' and data.get('assistantMessageCount', 0) >= 2 and data.get('composerText') == ''" 120 || fail "ASK could not continue from the same session after the proactive popup."
pass "ASK continued from the same session after the proactive popup."

post_smoke_follow_up \
  "Inbox follow-up" \
  "Continue the calculator task from inbox." \
  "ask_inbox" \
  "$FOLLOW_UP_TASK_ID" \
  "$FOLLOW_UP_RESUME_TOKEN" \
  "$FOLLOW_UP_WORKSPACE" \
  "$FOLLOW_UP_JOB_ID" \
  "$FOLLOW_UP_RUN_ID"
wait_for_state_condition "$STATE_FILE" "data.get('sessionID') == '$INITIAL_SESSION_ID' and data.get('activeTaskWorkspaceRoot') == '$FOLLOW_UP_WORKSPACE' and data.get('activeTaskResumeToken') == '$FOLLOW_UP_RESUME_TOKEN' and int(data.get('persistentAskInvocationCount') or 0) >= $(($PROACTIVE_INVOCATION_COUNT + 1))" 120 || fail "Inbox follow-up did not attach back onto the existing ASK session."
pass "Inbox follow-up attached onto the existing ASK session."

post_smoke_run_ask "$INBOX_CONTINUE_PROMPT" "true" "true" "true" "Still in the same ASK session after inbox follow-up."
wait_for_state_condition "$STATE_FILE" "data.get('sessionID') == '$INITIAL_SESSION_ID' and data.get('assistantMessageCount', 0) >= 3 and data.get('composerText') == ''" 120 || fail "ASK could not continue the conversation after inbox follow-up."
pass "ASK continued from the same session after inbox follow-up."

post_smoke_follow_up \
  "Notification follow-up" \
  "Continue the same task from notification." \
  "system_notification" \
  "$NOTIFICATION_TASK_ID" \
  "" \
  "$FOLLOW_UP_WORKSPACE" \
  "$FOLLOW_UP_JOB_ID" \
  "$FOLLOW_UP_RUN_ID"
wait_for_state_condition "$STATE_FILE" "data.get('sessionID') == '$INITIAL_SESSION_ID' and data.get('activeTaskID') == '$NOTIFICATION_TASK_ID' and int(data.get('persistentAskInvocationCount') or 0) >= $(($PROACTIVE_INVOCATION_COUNT + 2))" 120 || fail "Notification follow-up did not reuse the same ASK session."
pass "Notification follow-up also reused the same ASK session."

capture_screenshot "$SCREENSHOT_FILE"

echo "State file: $STATE_FILE"
echo "Screenshot: $SCREENSHOT_FILE"
echo "Session ID: $INITIAL_SESSION_ID"
