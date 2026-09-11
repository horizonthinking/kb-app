use std::{collections::HashMap, sync::Arc};

use parking_lot::{Mutex, RwLock};
use serde_json::Value;
use tauri::{AppHandle, Emitter, Wry};
use tokio::sync::oneshot;
use tokio::time::{Duration, timeout};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    AiError,
    mutation::{MutationApplyResult, MutationOp, MutationPlan},
    prompts::build_system_prompt,
    provider::{CompletionEvent, CompletionTurnRequest, ToolChoice},
    state::AiState,
    tools::{ToolAccess, ToolCallContext, ToolDescriptor, ToolSource, allowed_tools},
    types::{
        ChatMessage, ChatMode, DonePayload, EditorContext, EmbeddedFileContext, ErrorPayload,
        FinishReason, ModelToolCall, PendingApprovalPayload, ProxyToolCallPayload,
        StreamChunkPayload, ToolCallEndPayload, ToolCallStartPayload,
    },
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionStatus {
    Idle,
    Streaming,
    AwaitingApproval,
    Applying,
}

#[derive(Debug, Clone, Copy)]
pub enum ApprovalDecision {
    Approve,
    Reject,
}

const REMOTE_AUTH_REQUESTER_PLUGIN_ID: &str = "ai-chat";
const HISTORY_HARD_CAP_BYTES: usize = 64 * 1024;
const HISTORY_SUMMARY_MAX_BYTES: usize = 8 * 1024;
const HISTORY_MIN_RAW_USER_TURNS: usize = 3;
const HISTORY_SUMMARY_ITEM_MAX_BYTES: usize = 320;
const HISTORY_SUMMARY_MAX_REQUESTS: usize = 3;
const HISTORY_SUMMARY_MAX_TOOL_RESULTS: usize = 3;
const HISTORY_SUMMARY_MAX_ASSISTANT_REPLIES: usize = 2;
const HISTORY_SUMMARY_MAX_OPEN_TABS: usize = 4;
const HISTORY_SUMMARY_MAX_ATTACHMENTS: usize = 3;
const HISTORY_SUMMARY_CONTEXT_MESSAGE: &str = "[Internal context: Earlier conversation turns were compacted to stay within the context budget. The next assistant message is a background summary of omitted history. Treat it as prior conversation context, not as a new user request.]";
const HISTORY_SUMMARY_ASSISTANT_PREFIX: &str = "Background summary of earlier conversation:\n";
const USER_MESSAGE_MARKER: &str = "--- USER MESSAGE ---\n";

pub(crate) trait TurnEventSink: Send + Sync {
    fn stream_chunk(&self, session_id: &str, delta: String);
    fn done(
        &self,
        session_id: &str,
        finish_reason: FinishReason,
        usage: Option<crate::types::TokenUsage>,
    );
    fn error(&self, session_id: &str, error: &AiError);
    fn tool_start(&self, session_id: &str, tool_call: &ModelToolCall, tool_id: &str);
    fn tool_end(
        &self,
        session_id: &str,
        tool_call: &ModelToolCall,
        tool_id: &str,
        output: &str,
        is_error: bool,
    );
    fn pending_approval(
        &self,
        session_id: &str,
        call_id: &str,
        tool_id: &str,
        tool_name: &str,
        mutation: MutationPlan,
        preview_text: Option<String>,
    );
    fn proxy_call(
        &self,
        session_id: &str,
        call_id: &str,
        tool_id: &str,
        tool_name: &str,
        arguments: Value,
    );
}

pub(crate) struct PendingApproval {
    pub(crate) call_id: String,
    pub(crate) tool_id: String,
    pub(crate) tool_name: String,
    pub(crate) plan: MutationPlan,
    pub(crate) preview_text: Option<String>,
}

struct CompactedHistory {
    messages: Vec<ChatMessage>,
}

struct SessionControl {
    status: SessionStatus,
    cancel: Option<CancellationToken>,
    deferred_cancel: bool,
}

#[derive(Debug, Clone)]
struct PathSnapshot {
    checksum: String,
    is_dir: bool,
}

pub struct SessionRuntime {
    pub id: String,
    mode: RwLock<ChatMode>,
    pub messages: RwLock<Vec<ChatMessage>>,
    pub editor_context: RwLock<EditorContext>,
    approvals: Mutex<HashMap<String, oneshot::Sender<ApprovalDecision>>>,
    path_snapshots: Mutex<HashMap<String, PathSnapshot>>,
    control: Mutex<SessionControl>,
}

impl SessionRuntime {
    pub fn new(mode: ChatMode) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            mode: RwLock::new(mode),
            messages: RwLock::new(Vec::new()),
            editor_context: RwLock::new(EditorContext::default()),
            approvals: Mutex::new(HashMap::new()),
            path_snapshots: Mutex::new(HashMap::new()),
            control: Mutex::new(SessionControl {
                status: SessionStatus::Idle,
                cancel: None,
                deferred_cancel: false,
            }),
        }
    }

    fn replace_mode(&self, mode: ChatMode) -> ChatMode {
        let mut current = self.mode.write();
        std::mem::replace(&mut *current, mode)
    }

    pub fn start_run(&self) -> Result<CancellationToken, AiError> {
        let mut control = self.control.lock();
        if control.status != SessionStatus::Idle {
            return Err(AiError::SessionBusy);
        }

        let cancel = CancellationToken::new();
        control.status = SessionStatus::Streaming;
        control.cancel = Some(cancel.clone());
        control.deferred_cancel = false;
        Ok(cancel)
    }

    pub fn cancel(&self) {
        let mut control = self.control.lock();
        match control.status {
            SessionStatus::Applying => {
                control.deferred_cancel = true;
                if let Some(cancel) = control.cancel.as_ref() {
                    cancel.cancel();
                }
            }
            _ => {
                if let Some(cancel) = control.cancel.take() {
                    cancel.cancel();
                }
            }
        }
    }

    pub fn begin_awaiting_approval(
        &self,
        call_id: String,
    ) -> Result<oneshot::Receiver<ApprovalDecision>, AiError> {
        let (tx, rx) = oneshot::channel();
        self.approvals.lock().insert(call_id, tx);
        self.control.lock().status = SessionStatus::AwaitingApproval;
        Ok(rx)
    }

    pub fn resolve_approval(&self, call_id: &str, approved: bool) -> Result<(), AiError> {
        let sender = self
            .approvals
            .lock()
            .remove(call_id)
            .ok_or(AiError::ApprovalNotFound)?;
        sender
            .send(if approved {
                ApprovalDecision::Approve
            } else {
                ApprovalDecision::Reject
            })
            .map_err(|_| AiError::ApprovalNotFound)
    }

    pub fn clear_approval(&self, call_id: &str) {
        self.approvals.lock().remove(call_id);
    }

    pub fn set_status(&self, status: SessionStatus) {
        self.control.lock().status = status;
    }

    pub fn status(&self) -> SessionStatus {
        self.control.lock().status
    }

    pub fn remember_path_snapshot(&self, path: String, checksum: String, is_dir: bool) {
        self.path_snapshots
            .lock()
            .insert(path, PathSnapshot { checksum, is_dir });
    }

    pub fn path_snapshot(&self, path: &str) -> Option<(String, bool)> {
        self.path_snapshots
            .lock()
            .get(path)
            .map(|snapshot| (snapshot.checksum.clone(), snapshot.is_dir))
    }

    pub fn apply_successful_mutation(&self, operations: &[MutationOp]) {
        let mut snapshots = self.path_snapshots.lock();
        for op in operations {
            match op {
                MutationOp::CreateFile { path, content }
                | MutationOp::ReplaceFile { path, content, .. } => {
                    snapshots.insert(
                        path.clone(),
                        PathSnapshot {
                            checksum: checksum_for_content(content),
                            is_dir: false,
                        },
                    );
                }
                MutationOp::CreateDirectory { path } => {
                    snapshots.insert(
                        path.clone(),
                        PathSnapshot {
                            checksum: empty_directory_checksum(),
                            is_dir: true,
                        },
                    );
                }
                MutationOp::DeleteFile { path, .. } | MutationOp::DeleteDirectory { path, .. } => {
                    snapshots.remove(path);
                }
                MutationOp::RenameFile { from, to } => {
                    if let Some(snapshot) = snapshots.remove(from) {
                        snapshots.insert(to.clone(), snapshot);
                    } else {
                        snapshots.remove(to);
                    }
                }
            }
        }
    }

    pub fn clear_mutation_snapshots(&self, operations: &[MutationOp]) {
        let mut snapshots = self.path_snapshots.lock();
        for op in operations {
            match op {
                MutationOp::CreateFile { path, .. }
                | MutationOp::CreateDirectory { path }
                | MutationOp::ReplaceFile { path, .. }
                | MutationOp::DeleteFile { path, .. }
                | MutationOp::DeleteDirectory { path, .. } => {
                    snapshots.remove(path);
                }
                MutationOp::RenameFile { from, to } => {
                    snapshots.remove(from);
                    snapshots.remove(to);
                }
            }
        }
    }

    pub fn complete_run(&self) -> bool {
        let mut control = self.control.lock();
        let was_deferred = control.deferred_cancel;
        control.status = SessionStatus::Idle;
        control.cancel = None;
        control.deferred_cancel = false;
        was_deferred
    }
}

pub async fn run_turn(
    app: AppHandle<Wry>,
    state: AiState,
    session: Arc<SessionRuntime>,
    mode: ChatMode,
    content: String,
    editor_context: EditorContext,
) {
    let result = run_turn_inner(
        Some(&app),
        &app,
        &state,
        session.clone(),
        mode,
        content,
        editor_context,
    )
    .await;
    finalize_run(&session, &app, result);
}

pub(crate) fn finalize_run(
    session: &SessionRuntime,
    sink: &dyn TurnEventSink,
    result: Result<(FinishReason, Option<crate::types::TokenUsage>), AiError>,
) {
    let deferred_cancel = session.complete_run();
    match result {
        Ok((finish_reason, usage)) => {
            let finish_reason = if deferred_cancel {
                FinishReason::Cancelled
            } else {
                finish_reason
            };
            sink.done(&session.id, finish_reason, usage);
        }
        Err(error) => {
            let finish_reason = if matches!(error, AiError::Cancelled) || deferred_cancel {
                FinishReason::Cancelled
            } else {
                FinishReason::Error
            };
            sink.error(&session.id, &error);
            sink.done(&session.id, finish_reason, None);
        }
    }
}

pub(crate) async fn run_turn_inner(
    app: Option<&AppHandle<Wry>>,
    sink: &dyn TurnEventSink,
    state: &AiState,
    session: Arc<SessionRuntime>,
    mode: ChatMode,
    content: String,
    editor_context: EditorContext,
) -> Result<(FinishReason, Option<crate::types::TokenUsage>), AiError> {
    let cancel = session.start_run()?;
    let previous_mode = session.replace_mode(mode.clone());
    let run_mode = mode;
    remember_embedded_file_snapshots(&session, &editor_context);
    let content =
        content_with_turn_context(previous_mode, run_mode.clone(), content, &editor_context);
    *session.editor_context.write() = editor_context.clone();
    session.messages.write().push(ChatMessage::User {
        content,
        editor_context: Some(editor_context),
    });

    let backend = state.backend()?;
    let config = state.config();
    let descriptors = state.tool_descriptors();
    let allowed = allowed_tools(run_mode.clone(), &descriptors);

    let mut final_usage = None;

    for _round in 0..config.round_limit {
        let compacted = {
            let messages = session.messages.read();
            compact_history_for_model(&messages)
        };
        let system_prompt = build_system_prompt(run_mode.clone(), &allowed);
        let authorization_header = match config.provider {
            crate::types::ProviderKind::Remote => Some(
                state
                    .host()
                    .ok_or(AiError::HostUnavailable)?
                    .authorization_header(REMOTE_AUTH_REQUESTER_PLUGIN_ID)
                    .await?
                    .ok_or(AiError::NotConfigured)?,
            ),
            _ => None,
        };
        let request = CompletionTurnRequest {
            model: config.model.clone(),
            system_prompt: Some(system_prompt),
            messages: compacted.messages,
            tools: allowed.clone(),
            tool_choice: ToolChoice::Auto,
            authorization_header,
        };

        // Token may have expired between the proactive 60s-buffer check above
        // and the server actually serving the request (long upstream latency,
        // client clock drift, etc). On Unauthorized, force a refresh and try
        // exactly once more before surfacing the error.
        let mut stream = match backend.stream_turn(request.clone()).await {
            Ok(stream) => stream,
            Err(AiError::Unauthorized)
                if matches!(config.provider, crate::types::ProviderKind::Remote) =>
            {
                let refreshed_header = state
                    .host()
                    .ok_or(AiError::HostUnavailable)?
                    .refresh_authorization_header(REMOTE_AUTH_REQUESTER_PLUGIN_ID)
                    .await?
                    .ok_or(AiError::NotConfigured)?;
                let mut retry = request;
                retry.authorization_header = Some(refreshed_header);
                backend.stream_turn(retry).await?
            }
            Err(error) => return Err(error),
        };
        let mut assistant_text = String::new();
        let mut tool_calls = Vec::new();
        let mut round_reason = FinishReason::Stop;
        let mut round_usage = None;

        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    return Err(AiError::Cancelled);
                }
                item = futures::StreamExt::next(&mut stream) => {
                    let Some(item) = item else {
                        break;
                    };

                    match item? {
                        CompletionEvent::TextDelta(delta) => {
                            assistant_text.push_str(&delta);
                            sink.stream_chunk(&session.id, delta);
                        }
                        CompletionEvent::ToolCalls(calls) => {
                            tool_calls.extend(calls);
                        }
                        CompletionEvent::Finished { finish_reason, usage } => {
                            round_reason = finish_reason;
                            round_usage = usage;
                        }
                    }
                }
            }
        }

        if !assistant_text.is_empty() || !tool_calls.is_empty() {
            session.messages.write().push(ChatMessage::Assistant {
                content: assistant_text,
                tool_calls: tool_calls.clone(),
            });
        }

        final_usage = round_usage;

        if tool_calls.is_empty() {
            return Ok((round_reason, final_usage));
        }

        for tool_call in tool_calls {
            let result = handle_tool_call(
                app, sink, state, &session, &cancel, &run_mode, &allowed, &tool_call,
            )
            .await?;
            session.messages.write().push(ChatMessage::ToolResult {
                call_id: tool_call.call_id.clone(),
                tool_name: tool_call.tool_name.clone(),
                output: result.0.clone(),
                is_error: result.1,
                tool_call_id: tool_call.tool_call_id.clone(),
                provider_call_id: tool_call.provider_call_id.clone(),
            });
        }
    }

    Ok((FinishReason::ToolRoundLimit, final_usage))
}

#[allow(clippy::too_many_arguments)]
async fn handle_tool_call(
    app: Option<&AppHandle<Wry>>,
    sink: &dyn TurnEventSink,
    state: &AiState,
    session: &Arc<SessionRuntime>,
    cancel: &CancellationToken,
    mode: &ChatMode,
    allowed: &[ToolDescriptor],
    tool_call: &ModelToolCall,
) -> Result<(String, bool), AiError> {
    let descriptor = allowed
        .iter()
        .find(|tool| tool.name == tool_call.tool_name)
        .cloned();
    let tool_id = descriptor
        .as_ref()
        .map(|tool| tool.tool_id.clone())
        .unwrap_or_else(|| fallback_tool_id(&tool_call.tool_name));

    sink.tool_start(&session.id, tool_call, &tool_id);

    let outcome = match descriptor {
        None => (tool_not_allowed_message(&tool_call.tool_name, mode), true),
        Some(descriptor) => match descriptor.source {
            ToolSource::Native => {
                match execute_native_tool(
                    app, sink, state, session, cancel, mode, tool_call, descriptor,
                )
                .await
                {
                    Ok(outcome) => outcome,
                    Err(AiError::Cancelled) => return Err(AiError::Cancelled),
                    Err(error) => (error.to_string(), true),
                }
            }
            ToolSource::Proxy => {
                match execute_proxy_tool(sink, state, session, cancel, tool_call, &tool_id).await {
                    Ok(outcome) => outcome,
                    Err(AiError::Cancelled) => return Err(AiError::Cancelled),
                    Err(error) => (error.to_string(), true),
                }
            }
        },
    };

    sink.tool_end(&session.id, tool_call, &tool_id, &outcome.0, outcome.1);
    Ok(outcome)
}

fn content_with_mode_notice(
    previous_mode: ChatMode,
    run_mode: ChatMode,
    content: String,
) -> String {
    if previous_mode == run_mode {
        return content;
    }

    format!(
        "[Internal context: The user switched AI mode from {} to {} before this message. Use the current {} mode instructions and available tools for this turn.]\n\n{}",
        mode_label(previous_mode),
        mode_label(run_mode.clone()),
        mode_label(run_mode),
        content
    )
}

fn content_with_turn_context(
    previous_mode: ChatMode,
    run_mode: ChatMode,
    content: String,
    editor_context: &EditorContext,
) -> String {
    let selected_text = selected_text_context(editor_context);
    let active_editor_context = active_editor_context_block(editor_context);
    if selected_text.is_none()
        && editor_context.embedded_files.is_empty()
        && active_editor_context.is_none()
    {
        return content_with_mode_notice(previous_mode, run_mode, content);
    }

    let mut sections = Vec::new();
    if previous_mode != run_mode {
        sections.push(mode_notice(previous_mode, run_mode));
    }
    if let Some(active_editor_context) = active_editor_context {
        sections.push(active_editor_context);
    }
    if let Some(selected_text) = selected_text {
        sections.push(selected_text_block(
            selected_text,
            editor_context.active_file.as_deref(),
        ));
    }
    if !editor_context.embedded_files.is_empty() {
        sections.push(embedded_files_context(&editor_context.embedded_files));
    }
    sections.push(format!("--- USER MESSAGE ---\n{content}"));
    sections.join("\n\n")
}

fn compact_history_for_model(messages: &[ChatMessage]) -> CompactedHistory {
    if messages.is_empty() {
        return CompactedHistory {
            messages: Vec::new(),
        };
    }

    let mut kept_rev = Vec::new();
    let mut kept_bytes = 0usize;
    let mut kept_user_turns = 0usize;

    for message in messages.iter().rev() {
        let message_bytes = model_input_size(message);
        let would_exceed = kept_bytes.saturating_add(message_bytes) > HISTORY_HARD_CAP_BYTES;
        if kept_user_turns >= HISTORY_MIN_RAW_USER_TURNS && would_exceed {
            break;
        }

        kept_bytes = kept_bytes.saturating_add(message_bytes);
        if matches!(message, ChatMessage::User { .. }) {
            kept_user_turns += 1;
        }
        kept_rev.push(message.clone());
    }

    if kept_rev.len() == messages.len() {
        return CompactedHistory {
            messages: messages.to_vec(),
        };
    }

    let mut omitted_len = messages.len().saturating_sub(kept_rev.len());
    while omitted_len < messages.len() && !matches!(messages[omitted_len], ChatMessage::User { .. })
    {
        omitted_len += 1;
    }
    let kept_messages = messages[omitted_len..].to_vec();
    let kept_bytes = kept_messages.iter().map(model_input_size).sum::<usize>();
    let summary_messages = build_history_summary_messages(
        &messages[..omitted_len],
        HISTORY_HARD_CAP_BYTES
            .saturating_sub(kept_bytes)
            .min(HISTORY_SUMMARY_MAX_BYTES),
    );

    let mut compacted_messages = summary_messages.unwrap_or_default();
    compacted_messages.extend(kept_messages);
    CompactedHistory {
        messages: compacted_messages,
    }
}

fn build_history_summary_messages(
    messages: &[ChatMessage],
    max_bytes: usize,
) -> Option<Vec<ChatMessage>> {
    let overhead = HISTORY_SUMMARY_CONTEXT_MESSAGE.len() + HISTORY_SUMMARY_ASSISTANT_PREFIX.len();
    if max_bytes <= overhead {
        return None;
    }

    let summary = build_history_summary(messages, max_bytes.saturating_sub(overhead))?;
    Some(vec![
        ChatMessage::User {
            content: HISTORY_SUMMARY_CONTEXT_MESSAGE.to_string(),
            editor_context: None,
        },
        ChatMessage::Assistant {
            content: format!("{HISTORY_SUMMARY_ASSISTANT_PREFIX}{summary}"),
            tool_calls: Vec::new(),
        },
    ])
}

fn build_history_summary(messages: &[ChatMessage], max_bytes: usize) -> Option<String> {
    if messages.is_empty() || max_bytes < 128 {
        return None;
    }

    let omitted_user_turns = messages
        .iter()
        .filter(|message| matches!(message, ChatMessage::User { .. }))
        .count();
    let omitted_assistant_turns = messages
        .iter()
        .filter(|message| matches!(message, ChatMessage::Assistant { .. }))
        .count();
    let omitted_tool_results = messages
        .iter()
        .filter(|message| matches!(message, ChatMessage::ToolResult { .. }))
        .count();

    let mut sections = vec![format!(
        "Summarized earlier turns: {omitted_user_turns} user, {omitted_assistant_turns} assistant, {omitted_tool_results} tool result."
    )];

    push_summary_section(
        &mut sections,
        "Recent omitted user requests:",
        messages
            .iter()
            .rev()
            .filter_map(summary_user_message)
            .take(HISTORY_SUMMARY_MAX_REQUESTS)
            .collect(),
    );
    push_summary_section(
        &mut sections,
        "Recent omitted tool outcomes:",
        messages
            .iter()
            .rev()
            .filter_map(summary_tool_result_message)
            .take(HISTORY_SUMMARY_MAX_TOOL_RESULTS)
            .collect(),
    );
    push_summary_section(
        &mut sections,
        "Recent omitted assistant replies:",
        messages
            .iter()
            .rev()
            .filter_map(summary_assistant_message)
            .take(HISTORY_SUMMARY_MAX_ASSISTANT_REPLIES)
            .collect(),
    );

    let summary = truncate_text_bytes(&sections.join("\n\n"), max_bytes);
    (!summary.trim().is_empty()).then_some(summary)
}

fn push_summary_section(sections: &mut Vec<String>, heading: &str, mut lines: Vec<String>) {
    if lines.is_empty() {
        return;
    }
    lines.reverse();
    let body = lines
        .into_iter()
        .map(|line| format!("- {line}"))
        .collect::<Vec<_>>()
        .join("\n");
    sections.push(format!("{heading}\n{body}"));
}

fn summary_user_message(message: &ChatMessage) -> Option<String> {
    let ChatMessage::User {
        content,
        editor_context,
    } = message
    else {
        return None;
    };

    let request = truncate_text_bytes(
        &normalize_summary_text(extract_user_request(content)),
        HISTORY_SUMMARY_ITEM_MAX_BYTES,
    );
    if request.is_empty() {
        return None;
    }

    let editor_suffix = editor_context
        .as_ref()
        .and_then(summary_editor_context_suffix)
        .unwrap_or_default();
    Some(format!("{request}{editor_suffix}"))
}

fn summary_tool_result_message(message: &ChatMessage) -> Option<String> {
    let ChatMessage::ToolResult {
        tool_name,
        output,
        is_error,
        ..
    } = message
    else {
        return None;
    };

    let excerpt = truncate_text_bytes(
        &normalize_summary_text(output),
        HISTORY_SUMMARY_ITEM_MAX_BYTES,
    );
    if excerpt.is_empty() {
        return Some(format!(
            "{} {}",
            tool_name,
            if *is_error {
                "returned an error"
            } else {
                "completed"
            }
        ));
    }
    Some(format!(
        "{} {}: {}",
        tool_name,
        if *is_error {
            "resulted in error"
        } else {
            "result"
        },
        excerpt
    ))
}

fn summary_assistant_message(message: &ChatMessage) -> Option<String> {
    let ChatMessage::Assistant {
        content,
        tool_calls,
    } = message
    else {
        return None;
    };

    let mut parts = Vec::new();
    let excerpt = truncate_text_bytes(
        &normalize_summary_text(content),
        HISTORY_SUMMARY_ITEM_MAX_BYTES,
    );
    if !excerpt.is_empty() {
        parts.push(excerpt);
    }
    if !tool_calls.is_empty() {
        let mut tool_names = Vec::new();
        for tool_call in tool_calls {
            if !tool_names.contains(&tool_call.tool_name) {
                tool_names.push(tool_call.tool_name.clone());
            }
        }
        parts.push(format!("tool calls: {}", tool_names.join(", ")));
    }

    (!parts.is_empty()).then(|| parts.join(" | "))
}

fn summary_editor_context_suffix(editor_context: &EditorContext) -> Option<String> {
    let mut details = Vec::new();

    if let Some(active_file) = editor_context
        .active_file
        .as_deref()
        .map(str::trim)
        .filter(|path| !path.is_empty())
    {
        details.push(format!("active file {active_file}"));
    }
    if let Some(selected_text) = editor_context
        .selected_text
        .as_deref()
        .filter(|text| !text.trim().is_empty())
    {
        details.push(format!("selected excerpt {}B", selected_text.len()));
    }
    if !editor_context.embedded_files.is_empty() {
        let attached = editor_context
            .embedded_files
            .iter()
            .take(HISTORY_SUMMARY_MAX_ATTACHMENTS)
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        details.push(format!("attached {attached}"));
    }
    if !editor_context.open_tabs.is_empty() {
        let open_tabs = editor_context
            .open_tabs
            .iter()
            .map(String::as_str)
            .map(str::trim)
            .filter(|path| !path.is_empty())
            .take(HISTORY_SUMMARY_MAX_OPEN_TABS)
            .collect::<Vec<_>>()
            .join(", ");
        if !open_tabs.is_empty() {
            details.push(format!("open tabs {open_tabs}"));
        }
    }

    (!details.is_empty()).then(|| format!(" [context: {}]", details.join("; ")))
}

fn extract_user_request(content: &str) -> &str {
    content
        .rsplit_once(USER_MESSAGE_MARKER)
        .map(|(_, request)| request)
        .unwrap_or(content)
}

fn normalize_summary_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn truncate_text_bytes(text: &str, max_bytes: usize) -> String {
    if max_bytes == 0 {
        return String::new();
    }
    if text.len() <= max_bytes {
        return text.to_string();
    }
    if max_bytes <= 3 {
        return ".".repeat(max_bytes);
    }

    let cutoff = max_bytes - 3;
    let mut end = 0usize;
    for (index, ch) in text.char_indices() {
        let next = index + ch.len_utf8();
        if next > cutoff {
            break;
        }
        end = next;
    }
    if end == 0 {
        return "...".to_string();
    }
    format!("{}...", &text[..end])
}

fn model_input_size(message: &ChatMessage) -> usize {
    match message {
        ChatMessage::System { content } | ChatMessage::User { content, .. } => content.len(),
        ChatMessage::Assistant {
            content,
            tool_calls,
        } => {
            content.len()
                + tool_calls
                    .iter()
                    .map(model_tool_call_input_size)
                    .sum::<usize>()
        }
        ChatMessage::ToolResult {
            call_id,
            tool_name,
            output,
            tool_call_id,
            provider_call_id,
            ..
        } => {
            call_id.len()
                + tool_name.len()
                + output.len()
                + tool_call_id.as_ref().map_or(0, String::len)
                + provider_call_id.as_ref().map_or(0, String::len)
        }
    }
}

fn model_tool_call_input_size(call: &ModelToolCall) -> usize {
    call.call_id.len()
        + call.tool_name.len()
        + serde_json::to_string(&call.arguments).map_or(0, |json| json.len())
        + call.signature.as_ref().map_or(0, Vec::len)
        + call.tool_call_id.as_ref().map_or(0, String::len)
        + call.provider_call_id.as_ref().map_or(0, String::len)
}

fn remember_embedded_file_snapshots(session: &SessionRuntime, editor_context: &EditorContext) {
    for file in &editor_context.embedded_files {
        session.remember_path_snapshot(file.path.clone(), file.checksum.clone(), false);
    }
}

fn mode_notice(previous_mode: ChatMode, run_mode: ChatMode) -> String {
    format!(
        "[Internal context: The user switched AI mode from {} to {} before this message. Use the current {} mode instructions and available tools for this turn.]",
        mode_label(previous_mode),
        mode_label(run_mode.clone()),
        mode_label(run_mode)
    )
}

fn selected_text_context(editor_context: &EditorContext) -> Option<&str> {
    editor_context
        .selected_text
        .as_deref()
        .filter(|text| !text.trim().is_empty())
}

fn active_editor_context_block(editor_context: &EditorContext) -> Option<String> {
    let active_file = editor_context
        .active_file
        .as_deref()
        .map(str::trim)
        .filter(|path| !path.is_empty());
    let open_tabs = editor_context
        .open_tabs
        .iter()
        .map(String::as_str)
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .fold(Vec::<&str>::new(), |mut acc, path| {
            if !acc.contains(&path) {
                acc.push(path);
            }
            acc
        });

    if active_file.is_none() && open_tabs.is_empty() {
        return None;
    }

    let mut output = String::from(
        "[Internal context: The user is working in the editor. Resolve references like 'this document' against the active file first. Open tabs provide nearby document context by path only; they are not attached as full content.]",
    );

    if let Some(active_file) = active_file {
        output.push_str("\n\n");
        output.push_str(&format!("Active file: {}", escape_prompt_attr(active_file)));
    }

    if !open_tabs.is_empty() {
        output.push_str("\nOpen tabs:");
        for path in open_tabs {
            output.push_str("\n- ");
            output.push_str(&escape_prompt_attr(path));
        }
    }

    Some(output)
}

fn selected_text_block(selected_text: &str, active_file: Option<&str>) -> String {
    let active_file = active_file.unwrap_or_default();
    let guidance = if active_file.is_empty() {
        "This selected text is a focus excerpt, not a full document.".to_string()
    } else {
        format!(
            "This selected text is a focus excerpt from the active file, not the full document. If you need to modify {}, read the full active file before proposing edits and preserve all unrelated content outside the target section.",
            active_file
        )
    };
    let mut output = format!(
        "[Internal context: The user selected text in the active editor. {guidance}]\n\n--- BEGIN SELECTED TEXT activeFile=\"{}\" sizeBytes=\"{}\" ---\n",
        escape_prompt_attr(active_file),
        selected_text.len()
    );
    output.push_str(selected_text);
    if !selected_text.ends_with('\n') {
        output.push('\n');
    }
    output.push_str("--- END SELECTED TEXT ---");
    output
}

fn embedded_files_context(files: &[EmbeddedFileContext]) -> String {
    let label = if files.len() == 1 { "file" } else { "files" };
    let mut output = format!(
        "[Internal context: The user attached {} vault markdown {label}. Treat them as user-provided context. Paths are vault-relative. Attached files are already available in this user message.]",
        files.len()
    );

    for file in files {
        output.push_str("\n\n");
        output.push_str(&format!(
            "--- BEGIN ATTACHED FILE path=\"{}\" checksum=\"{}\" sizeBytes=\"{}\" ---\n",
            escape_prompt_attr(&file.path),
            escape_prompt_attr(&file.checksum),
            file.size_bytes
        ));
        output.push_str(&file.content);
        if !file.content.ends_with('\n') {
            output.push('\n');
        }
        output.push_str(&format!(
            "--- END ATTACHED FILE path=\"{}\" ---",
            escape_prompt_attr(&file.path)
        ));
    }

    output
}

fn escape_prompt_attr(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn tool_not_allowed_message(tool_name: &str, mode: &ChatMode) -> String {
    format!(
        "Tool '{tool_name}' is not available in {} mode for this turn.",
        mode_label(mode.clone())
    )
}

fn mode_label(mode: ChatMode) -> &'static str {
    match mode {
        ChatMode::Ask => "Ask",
        ChatMode::Agent => "Agent",
        ChatMode::Inline => "Inline",
    }
}

#[allow(clippy::too_many_arguments)]
async fn execute_native_tool(
    app: Option<&AppHandle<Wry>>,
    sink: &dyn TurnEventSink,
    state: &AiState,
    session: &Arc<SessionRuntime>,
    cancel: &CancellationToken,
    mode: &ChatMode,
    tool_call: &ModelToolCall,
    descriptor: ToolDescriptor,
) -> Result<(String, bool), AiError> {
    let app = app.ok_or(AiError::HostUnavailable)?;
    let tool = state
        .tools()
        .get_native(&tool_call.tool_name)
        .ok_or_else(|| AiError::ToolNotFound(tool_call.tool_name.clone()))?;

    let editor_context = session.editor_context.read().clone();
    let ctx = ToolCallContext {
        app,
        session_id: &session.id,
        mode: mode.clone(),
        editor_context: &editor_context,
    };

    let native_result = match tool.call(&ctx, tool_call.arguments.clone()).await {
        Ok(result) => result,
        Err(error) => {
            return Ok((error.to_string(), true));
        }
    };

    let Some(mutation) = native_result
        .mutation
        .clone()
        .filter(|_| descriptor.access != ToolAccess::ReadOnly)
    else {
        return Ok((native_result.text, false));
    };
    gate_and_apply(
        sink,
        || state.host(),
        session,
        cancel,
        PendingApproval {
            call_id: tool_call.call_id.clone(),
            tool_id: descriptor.tool_id,
            tool_name: tool_call.tool_name.clone(),
            plan: mutation,
            preview_text: native_result.preview_text,
        },
    )
    .await
}

async fn execute_proxy_tool(
    sink: &dyn TurnEventSink,
    state: &AiState,
    session: &Arc<SessionRuntime>,
    cancel: &CancellationToken,
    tool_call: &ModelToolCall,
    tool_id: &str,
) -> Result<(String, bool), AiError> {
    if state.tools().get_proxy(&tool_call.tool_name).is_none() {
        return Ok((
            format!("Proxy tool {} is not registered", tool_call.tool_name),
            true,
        ));
    }

    let receiver = state
        .proxy_broker()
        .register_pending(tool_call.call_id.clone());
    sink.proxy_call(
        &session.id,
        &tool_call.call_id,
        tool_id,
        &tool_call.tool_name,
        tool_call.arguments.clone(),
    );

    let response = tokio::select! {
        _ = cancel.cancelled() => {
            state.proxy_broker().clear(&tool_call.call_id);
            return Err(AiError::Cancelled);
        }
        result = timeout(Duration::from_millis(state.config().proxy_tool_timeout_ms), receiver) => {
            match result {
                Ok(Ok(output)) => output,
                Ok(Err(_)) => return Ok(("Proxy tool responder dropped".to_string(), true)),
                Err(_) => {
                    state.proxy_broker().clear(&tool_call.call_id);
                    return Err(AiError::ProxyTimeout(tool_call.tool_name.clone()));
                }
            }
        }
    };

    Ok((response.output, response.is_error))
}

pub(crate) async fn gate_and_apply(
    sink: &dyn TurnEventSink,
    host: impl FnOnce() -> Option<Arc<dyn crate::AiHostBindings>>,
    session: &Arc<SessionRuntime>,
    cancel: &CancellationToken,
    pending: PendingApproval,
) -> Result<(String, bool), AiError> {
    let mutation_operations = pending.plan.operations.clone();
    let approval_rx = session.begin_awaiting_approval(pending.call_id.clone())?;
    sink.pending_approval(
        &session.id,
        &pending.call_id,
        &pending.tool_id,
        &pending.tool_name,
        pending.plan.clone(),
        pending.preview_text,
    );

    let decision = tokio::select! {
        _ = cancel.cancelled() => {
            session.clear_approval(&pending.call_id);
            return Err(AiError::Cancelled);
        }
        decision = approval_rx => decision.map_err(|_| AiError::ApprovalNotFound)?,
    };

    if matches!(decision, ApprovalDecision::Reject) {
        session.set_status(SessionStatus::Streaming);
        return Ok(("Rejected by user".to_string(), true));
    }

    let host = host().ok_or(AiError::HostUnavailable)?;
    session.set_status(SessionStatus::Applying);
    let apply_result = host.apply_mutation(pending.plan).await?;
    match &apply_result {
        MutationApplyResult::Applied { .. } => {
            session.apply_successful_mutation(&mutation_operations);
        }
        MutationApplyResult::PartiallyApplied { .. } => {
            session.clear_mutation_snapshots(&mutation_operations);
        }
        MutationApplyResult::Conflict { .. } => {}
    }
    let output = describe_apply_result(&apply_result);
    session.set_status(SessionStatus::Streaming);
    if cancel.is_cancelled() {
        return Err(AiError::Cancelled);
    }
    Ok((
        output,
        matches!(apply_result, MutationApplyResult::Conflict { .. }),
    ))
}

fn describe_apply_result(result: &MutationApplyResult) -> String {
    match result {
        MutationApplyResult::Applied { summary, warnings } => {
            if warnings.is_empty() {
                format!("Applied: {summary}")
            } else {
                format!("Applied: {summary}\nWarnings: {}", warnings.join("; "))
            }
        }
        MutationApplyResult::PartiallyApplied {
            summary,
            applied,
            failed,
            skipped,
            warnings,
        } => {
            let mut parts = vec![format!("Partially applied: {summary}")];
            if !applied.is_empty() {
                parts.push(format!("Applied: {}", applied.join(", ")));
            }
            if !failed.is_empty() {
                parts.push(format!("Failed: {}", failed.join(", ")));
            }
            if !skipped.is_empty() {
                parts.push(format!("Skipped: {}", skipped.join(", ")));
            }
            if !warnings.is_empty() {
                parts.push(format!("Warnings: {}", warnings.join("; ")));
            }
            parts.join("\n")
        }
        MutationApplyResult::Conflict { summary, conflicts } => {
            let detail = conflicts
                .iter()
                .map(|conflict| format!("{} ({})", conflict.path, conflict.reason))
                .collect::<Vec<_>>()
                .join(", ");
            format!("Conflict: {summary}. {detail}")
        }
    }
}

impl TurnEventSink for AppHandle<Wry> {
    fn stream_chunk(&self, session_id: &str, delta: String) {
        emit_stream_chunk(self, session_id, delta);
    }

    fn done(
        &self,
        session_id: &str,
        finish_reason: FinishReason,
        usage: Option<crate::types::TokenUsage>,
    ) {
        emit_done(self, session_id, finish_reason, usage);
    }

    fn error(&self, session_id: &str, error: &AiError) {
        emit_error(self, session_id, error);
    }

    fn tool_start(&self, session_id: &str, tool_call: &ModelToolCall, tool_id: &str) {
        emit_tool_start(self, session_id, tool_call, tool_id);
    }

    fn tool_end(
        &self,
        session_id: &str,
        tool_call: &ModelToolCall,
        tool_id: &str,
        output: &str,
        is_error: bool,
    ) {
        emit_tool_end(
            self,
            session_id,
            &tool_call.call_id,
            tool_id,
            &tool_call.tool_name,
            output,
            is_error,
        );
    }

    fn pending_approval(
        &self,
        session_id: &str,
        call_id: &str,
        tool_id: &str,
        tool_name: &str,
        mutation: MutationPlan,
        preview_text: Option<String>,
    ) {
        emit_pending_approval(
            self,
            session_id,
            call_id,
            tool_id,
            tool_name,
            mutation,
            preview_text,
        );
    }

    fn proxy_call(
        &self,
        session_id: &str,
        call_id: &str,
        tool_id: &str,
        tool_name: &str,
        arguments: Value,
    ) {
        emit_proxy_call(self, session_id, call_id, tool_id, tool_name, arguments);
    }
}

pub fn emit_stream_chunk(app: &AppHandle<Wry>, session_id: &str, delta: String) {
    let _ = app.emit(
        "ai:stream-chunk",
        StreamChunkPayload {
            session_id: session_id.to_string(),
            delta,
        },
    );
}

pub fn emit_done(
    app: &AppHandle<Wry>,
    session_id: &str,
    finish_reason: FinishReason,
    usage: Option<crate::types::TokenUsage>,
) {
    let _ = app.emit(
        "ai:done",
        DonePayload {
            session_id: session_id.to_string(),
            finish_reason,
            usage,
        },
    );
}

pub fn emit_error(app: &AppHandle<Wry>, session_id: &str, error: &AiError) {
    let _ = app.emit(
        "ai:error",
        ErrorPayload {
            session_id: session_id.to_string(),
            message: error.message(),
        },
    );
}

fn emit_tool_start(
    app: &AppHandle<Wry>,
    session_id: &str,
    tool_call: &ModelToolCall,
    tool_id: &str,
) {
    let _ = app.emit(
        "ai:tool-call-start",
        ToolCallStartPayload {
            session_id: session_id.to_string(),
            call_id: tool_call.call_id.clone(),
            tool_id: tool_id.to_string(),
            tool_name: tool_call.tool_name.clone(),
            arguments: tool_call.arguments.clone(),
        },
    );
}

fn emit_tool_end(
    app: &AppHandle<Wry>,
    session_id: &str,
    call_id: &str,
    tool_id: &str,
    tool_name: &str,
    output: &str,
    is_error: bool,
) {
    let output = summarize_output(output);
    let _ = app.emit(
        "ai:tool-call-end",
        ToolCallEndPayload {
            session_id: session_id.to_string(),
            call_id: call_id.to_string(),
            tool_id: tool_id.to_string(),
            tool_name: tool_name.to_string(),
            output,
            is_error,
        },
    );
}

fn emit_pending_approval(
    app: &AppHandle<Wry>,
    session_id: &str,
    call_id: &str,
    tool_id: &str,
    tool_name: &str,
    mutation: crate::mutation::MutationPlan,
    preview_text: Option<String>,
) {
    let _ = app.emit(
        "ai:pending-approval",
        PendingApprovalPayload {
            session_id: session_id.to_string(),
            call_id: call_id.to_string(),
            tool_id: tool_id.to_string(),
            tool_name: tool_name.to_string(),
            mutation,
            preview_text,
        },
    );
}

fn emit_proxy_call(
    app: &AppHandle<Wry>,
    session_id: &str,
    call_id: &str,
    tool_id: &str,
    tool_name: &str,
    arguments: Value,
) {
    let _ = app.emit(
        "ai:proxy-tool-call",
        ProxyToolCallPayload {
            session_id: session_id.to_string(),
            call_id: call_id.to_string(),
            tool_id: tool_id.to_string(),
            tool_name: tool_name.to_string(),
            arguments,
        },
    );
}

fn fallback_tool_id(tool_name: &str) -> String {
    if tool_name.contains('.') {
        tool_name.to_string()
    } else {
        format!("builtin.{tool_name}")
    }
}

fn summarize_output(output: &str) -> String {
    const MAX: usize = 600;
    let Some((end, _)) = output.char_indices().nth(MAX) else {
        return output.to_string();
    };
    format!("{}...", &output[..end])
}

fn checksum_for_content(content: &str) -> String {
    blake3::hash(content.as_bytes()).to_hex().to_string()
}

fn empty_directory_checksum() -> String {
    blake3::Hasher::new().finalize().to_hex().to_string()
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };

    use async_trait::async_trait;
    use parking_lot::Mutex;
    use serde_json::{Value, json};
    use tokio::{sync::Notify, time::timeout};

    use super::{
        ApprovalDecision, PendingApproval, SessionRuntime, SessionStatus, TurnEventSink,
        compact_history_for_model, content_with_mode_notice, content_with_turn_context,
        finalize_run, gate_and_apply, remember_embedded_file_snapshots, run_turn_inner,
        summarize_output, tool_not_allowed_message,
    };
    use crate::{
        AiConfig, AiError, AiHostBindings, AiState, ConflictItem, MutationApplyResult, MutationOp,
        MutationPlan, ProxyToolDescriptor, ProxyToolResult,
        provider::{
            CompletionBackend, CompletionEvent, CompletionTurnRequest, CompletionTurnStream,
        },
        types::{
            ChatMessage, ChatMode, EditorContext, EmbeddedFileContext, FinishReason, ModelToolCall,
            ProviderKind, TokenUsage,
        },
    };

    #[test]
    fn summarize_output_keeps_short_strings() {
        let input = "short output";
        assert_eq!(summarize_output(input), input);
    }

    #[test]
    fn summarize_output_truncates_on_char_boundary() {
        let input = format!("{}끝", "가".repeat(600));
        let summarized = summarize_output(&input);

        assert!(summarized.ends_with("..."));
        assert_eq!(summarized.chars().count(), 603);
        assert_eq!(summarized, format!("{}...", "가".repeat(600)));
    }

    #[test]
    fn cancel_during_apply_cancels_the_running_token() {
        let session = SessionRuntime::new(ChatMode::Agent);
        let cancel = session.start_run().expect("start run");
        session.set_status(SessionStatus::Applying);

        session.cancel();

        assert!(cancel.is_cancelled());
        assert!(session.complete_run());
    }

    #[test]
    fn content_with_mode_notice_keeps_content_when_mode_is_same() {
        let content = "hello".to_string();

        assert_eq!(
            content_with_mode_notice(ChatMode::Ask, ChatMode::Ask, content),
            "hello"
        );
    }

    #[test]
    fn content_with_mode_notice_describes_mode_changes() {
        let content = content_with_mode_notice(
            ChatMode::Agent,
            ChatMode::Ask,
            "answer without editing".to_string(),
        );

        assert!(content.contains("from Agent to Ask"));
        assert!(content.contains("current Ask mode"));
        assert!(content.ends_with("answer without editing"));
    }

    #[test]
    fn content_with_turn_context_includes_embedded_files() {
        let context = EditorContext {
            embedded_files: vec![EmbeddedFileContext {
                path: "notes/Base.md".to_string(),
                content: "# Base\ncontent".to_string(),
                checksum: "checksum-1".to_string(),
                size_bytes: 14,
            }],
            ..EditorContext::default()
        };

        let content = content_with_turn_context(
            ChatMode::Ask,
            ChatMode::Ask,
            "summarize it".to_string(),
            &context,
        );

        assert!(content.contains("attached 1 vault markdown file"));
        assert!(content.contains("--- BEGIN ATTACHED FILE path=\"notes/Base.md\""));
        assert!(content.contains("checksum=\"checksum-1\""));
        assert!(content.contains("# Base\ncontent"));
        assert!(content.ends_with("--- USER MESSAGE ---\nsummarize it"));
    }

    #[test]
    fn content_with_turn_context_includes_active_file_and_open_tabs() {
        let context = EditorContext {
            active_file: Some("notes/Current.md".to_string()),
            open_tabs: vec![
                "notes/Current.md".to_string(),
                "notes/Related.md".to_string(),
                "notes/Related.md".to_string(),
            ],
            ..EditorContext::default()
        };

        let content = content_with_turn_context(
            ChatMode::Ask,
            ChatMode::Ask,
            "고도화해줘".to_string(),
            &context,
        );

        assert!(content.contains("Resolve references like 'this document'"));
        assert!(content.contains("Active file: notes/Current.md"));
        assert!(content.contains("Open tabs:"));
        assert!(content.contains("- notes/Current.md"));
        assert!(content.contains("- notes/Related.md"));
        assert_eq!(content.matches("- notes/Related.md").count(), 1);
        assert!(content.ends_with("--- USER MESSAGE ---\n고도화해줘"));
    }

    #[test]
    fn content_with_turn_context_includes_selected_text() {
        let context = EditorContext {
            active_file: Some("notes/Base.md".to_string()),
            selected_text: Some("selected paragraph".to_string()),
            ..EditorContext::default()
        };

        let content = content_with_turn_context(
            ChatMode::Ask,
            ChatMode::Ask,
            "explain this".to_string(),
            &context,
        );

        assert!(content.contains("selected text in the active editor"));
        assert!(content.contains("focus excerpt"));
        assert!(content.contains("not the full document"));
        assert!(content.contains("read the full active file before proposing edits"));
        assert!(content.contains("preserve all unrelated content"));
        assert!(content.contains("--- BEGIN SELECTED TEXT activeFile=\"notes/Base.md\""));
        assert!(content.contains("selected paragraph"));
        assert!(content.contains("--- END SELECTED TEXT ---"));
        assert!(content.ends_with("--- USER MESSAGE ---\nexplain this"));
        assert!(!content.contains("attached 0"));
    }

    #[test]
    fn embedded_files_register_session_snapshots() {
        let session = SessionRuntime::new(ChatMode::Agent);
        let context = EditorContext {
            embedded_files: vec![EmbeddedFileContext {
                path: "notes/Base.md".to_string(),
                content: "content".to_string(),
                checksum: "checksum-1".to_string(),
                size_bytes: 7,
            }],
            ..EditorContext::default()
        };

        remember_embedded_file_snapshots(&session, &context);

        assert_eq!(
            session.path_snapshot("notes/Base.md"),
            Some(("checksum-1".to_string(), false))
        );
    }

    #[test]
    fn tool_not_allowed_message_mentions_current_mode() {
        assert_eq!(
            tool_not_allowed_message("edit_file", &ChatMode::Ask),
            "Tool 'edit_file' is not available in Ask mode for this turn."
        );
    }

    #[test]
    fn compact_history_keeps_all_messages_when_within_budget() {
        let messages = vec![
            ChatMessage::User {
                content: "hello".to_string(),
                editor_context: None,
            },
            ChatMessage::Assistant {
                content: "world".to_string(),
                tool_calls: Vec::new(),
            },
        ];

        let compacted = compact_history_for_model(&messages);

        assert_eq!(compacted.messages.len(), 2);
        assert!(matches!(
            &compacted.messages[0],
            ChatMessage::User { content, .. } if content == "hello"
        ));
    }

    #[test]
    fn compact_history_summarizes_older_turns_but_keeps_recent_raw_history() {
        let messages = vec![
            ChatMessage::User {
                content: format!(
                    "{}{}",
                    "old context ".repeat(6_000),
                    "--- USER MESSAGE ---\nplease summarize old file"
                ),
                editor_context: Some(EditorContext {
                    active_file: Some("notes/Old.md".to_string()),
                    embedded_files: vec![EmbeddedFileContext {
                        path: "notes/Base.md".to_string(),
                        content: "base".to_string(),
                        checksum: "checksum-1".to_string(),
                        size_bytes: 4,
                    }],
                    ..EditorContext::default()
                }),
            },
            ChatMessage::ToolResult {
                call_id: "call-1".to_string(),
                tool_name: "read_file".to_string(),
                output: "tool output ".repeat(2_000),
                is_error: false,
                tool_call_id: Some("call-1".to_string()),
                provider_call_id: Some("call-1".to_string()),
            },
            ChatMessage::Assistant {
                content: "assistant reply".to_string(),
                tool_calls: Vec::new(),
            },
            ChatMessage::User {
                content: "recent request 1".to_string(),
                editor_context: None,
            },
            ChatMessage::Assistant {
                content: "recent answer 1".to_string(),
                tool_calls: Vec::new(),
            },
            ChatMessage::User {
                content: "recent request 2".to_string(),
                editor_context: None,
            },
            ChatMessage::Assistant {
                content: "recent answer 2".to_string(),
                tool_calls: Vec::new(),
            },
            ChatMessage::User {
                content: "current request".to_string(),
                editor_context: None,
            },
        ];

        let compacted = compact_history_for_model(&messages);

        assert_eq!(compacted.messages.len(), 7);
        assert!(matches!(
            &compacted.messages[0],
            ChatMessage::User { content, .. }
                if content.contains("Earlier conversation turns were compacted")
        ));
        assert!(matches!(
            &compacted.messages[1],
            ChatMessage::Assistant { content, tool_calls }
                if tool_calls.is_empty()
                    && content.contains("Background summary of earlier conversation")
                    && content.contains("please summarize old file")
                    && content.contains("read_file result")
                    && content.contains("notes/Base.md")
        ));
        assert!(matches!(
            &compacted.messages[2],
            ChatMessage::User { content, .. } if content == "recent request 1"
        ));
        assert!(!compacted.messages.iter().any(|message| matches!(
            message,
            ChatMessage::User { content, .. } if content.contains("old context")
        )));
        assert!(matches!(
            compacted.messages.last(),
            Some(ChatMessage::User { content, .. }) if content == "current request"
        ));
    }

    #[test]
    fn compact_history_places_summary_into_synthetic_history_messages() {
        let large_old_message = ChatMessage::User {
            content: format!(
                "{}{}",
                "older context ".repeat(6_000),
                "--- USER MESSAGE ---\ncarry this forward"
            ),
            editor_context: None,
        };
        let messages = vec![
            large_old_message,
            ChatMessage::Assistant {
                content: "older answer".to_string(),
                tool_calls: Vec::new(),
            },
            ChatMessage::User {
                content: "recent request 1".to_string(),
                editor_context: None,
            },
            ChatMessage::Assistant {
                content: "recent answer 1".to_string(),
                tool_calls: Vec::new(),
            },
            ChatMessage::User {
                content: "recent request 2".to_string(),
                editor_context: None,
            },
            ChatMessage::Assistant {
                content: "recent answer 2".to_string(),
                tool_calls: Vec::new(),
            },
            ChatMessage::User {
                content: "current request".to_string(),
                editor_context: None,
            },
        ];

        let compacted = compact_history_for_model(&messages);

        assert!(matches!(
            &compacted.messages[0],
            ChatMessage::User { content, editor_context }
                if editor_context.is_none()
                    && content.contains("The next assistant message is a background summary")
        ));
        assert!(matches!(
            &compacted.messages[1],
            ChatMessage::Assistant { content, tool_calls }
                if tool_calls.is_empty()
                    && content.contains("Background summary of earlier conversation")
                    && content.contains("carry this forward")
        ));
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    enum SinkEvent {
        StreamChunk(String),
        Done(FinishReason, Option<(u64, u64, u64, u64)>),
        Error(String),
        ToolStart(String),
        ToolEnd(String, String, bool),
        PendingApproval(String),
        ProxyCall(String),
    }

    #[derive(Default)]
    struct RecordingSink {
        events: Mutex<Vec<SinkEvent>>,
        proxy_called: Notify,
    }

    impl RecordingSink {
        fn events(&self) -> Vec<SinkEvent> {
            self.events.lock().clone()
        }
    }

    impl TurnEventSink for RecordingSink {
        fn stream_chunk(&self, _session_id: &str, delta: String) {
            self.events.lock().push(SinkEvent::StreamChunk(delta));
        }

        fn done(&self, _session_id: &str, finish_reason: FinishReason, usage: Option<TokenUsage>) {
            self.events.lock().push(SinkEvent::Done(
                finish_reason,
                usage.map(|usage| {
                    (
                        usage.input_tokens,
                        usage.output_tokens,
                        usage.total_tokens,
                        usage.cached_input_tokens,
                    )
                }),
            ));
        }

        fn error(&self, _session_id: &str, error: &AiError) {
            self.events.lock().push(SinkEvent::Error(error.to_string()));
        }

        fn tool_start(&self, _session_id: &str, tool_call: &ModelToolCall, _tool_id: &str) {
            self.events
                .lock()
                .push(SinkEvent::ToolStart(tool_call.tool_name.clone()));
        }

        fn tool_end(
            &self,
            _session_id: &str,
            tool_call: &ModelToolCall,
            _tool_id: &str,
            output: &str,
            is_error: bool,
        ) {
            self.events.lock().push(SinkEvent::ToolEnd(
                tool_call.tool_name.clone(),
                output.to_string(),
                is_error,
            ));
        }

        fn pending_approval(
            &self,
            _session_id: &str,
            call_id: &str,
            _tool_id: &str,
            _tool_name: &str,
            _mutation: MutationPlan,
            _preview_text: Option<String>,
        ) {
            self.events
                .lock()
                .push(SinkEvent::PendingApproval(call_id.to_string()));
        }

        fn proxy_call(
            &self,
            _session_id: &str,
            call_id: &str,
            _tool_id: &str,
            _tool_name: &str,
            _arguments: Value,
        ) {
            self.events
                .lock()
                .push(SinkEvent::ProxyCall(call_id.to_string()));
            self.proxy_called.notify_one();
        }
    }

    #[derive(Clone)]
    struct FakeHost {
        calls: Arc<AtomicUsize>,
        result: Result<MutationApplyResult, AiError>,
        cancel_during_apply: Option<Arc<SessionRuntime>>,
    }

    #[async_trait]
    impl AiHostBindings for FakeHost {
        async fn apply_mutation(
            &self,
            _plan: MutationPlan,
        ) -> Result<MutationApplyResult, AiError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if let Some(session) = &self.cancel_during_apply {
                session.cancel();
            }
            self.result.clone()
        }
    }

    fn mutation_plan(content: &str) -> MutationPlan {
        MutationPlan {
            summary: "write note".to_string(),
            operations: vec![MutationOp::CreateFile {
                path: "notes/a.md".to_string(),
                content: content.to_string(),
            }],
        }
    }

    fn pending(plan: MutationPlan) -> PendingApproval {
        PendingApproval {
            call_id: "call-1".to_string(),
            tool_id: "builtin.edit_file".to_string(),
            tool_name: "edit_file".to_string(),
            plan,
            preview_text: Some("preview".to_string()),
        }
    }

    async fn wait_for_status(session: &SessionRuntime, expected: SessionStatus) {
        timeout(Duration::from_secs(2), async {
            loop {
                if session.status() == expected {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("session reached expected status");
    }

    fn fake_host(
        result: Result<MutationApplyResult, AiError>,
    ) -> (Arc<AtomicUsize>, Arc<dyn AiHostBindings>) {
        let calls = Arc::new(AtomicUsize::new(0));
        (
            calls.clone(),
            Arc::new(FakeHost {
                calls,
                result,
                cancel_during_apply: None,
            }),
        )
    }

    #[test]
    fn gate_and_apply_preserves_approval_semantics_reject_without_host() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let sink = RecordingSink::default();
                let session = Arc::new(SessionRuntime::new(ChatMode::Agent));
                let cancel = session.start_run().expect("start run");
                let resolver = session.clone();
                tokio::spawn(async move {
                    wait_for_status(&resolver, SessionStatus::AwaitingApproval).await;
                    resolver
                        .resolve_approval("call-1", false)
                        .expect("reject approval");
                });
                let host_resolutions = AtomicUsize::new(0);
                let outcome = gate_and_apply(
                    &sink,
                    || {
                        host_resolutions.fetch_add(1, Ordering::SeqCst);
                        None
                    },
                    &session,
                    &cancel,
                    pending(mutation_plan("new")),
                )
                .await
                .expect("rejection is a tool output");
                assert_eq!(outcome, ("Rejected by user".to_string(), true));
                assert_eq!(host_resolutions.load(Ordering::SeqCst), 0);
                assert_eq!(session.status(), SessionStatus::Streaming);
                assert_eq!(
                    sink.events(),
                    vec![SinkEvent::PendingApproval("call-1".to_string())]
                );
            });
    }

    #[test]
    fn gate_and_apply_preserves_approval_semantics_cancelled_while_waiting() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let sink = RecordingSink::default();
                let session = Arc::new(SessionRuntime::new(ChatMode::Agent));
                let cancel = session.start_run().expect("start run");
                let canceller = session.clone();
                tokio::spawn(async move {
                    wait_for_status(&canceller, SessionStatus::AwaitingApproval).await;
                    canceller.cancel();
                });
                let result = gate_and_apply(
                    &sink,
                    || None,
                    &session,
                    &cancel,
                    pending(mutation_plan("new")),
                )
                .await;
                assert!(matches!(result, Err(AiError::Cancelled)));
                assert!(matches!(
                    session.resolve_approval("call-1", true),
                    Err(AiError::ApprovalNotFound)
                ));
            });
    }

    #[test]
    fn gate_and_apply_preserves_approval_semantics_cancelled_during_apply() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let sink = RecordingSink::default();
                let session = Arc::new(SessionRuntime::new(ChatMode::Agent));
                session.remember_path_snapshot("notes/a.md".to_string(), "old".to_string(), false);
                let cancel = session.start_run().expect("start run");
                let resolver = session.clone();
                tokio::spawn(async move {
                    wait_for_status(&resolver, SessionStatus::AwaitingApproval).await;
                    resolver
                        .resolve_approval("call-1", true)
                        .expect("approve mutation");
                });
                let calls = Arc::new(AtomicUsize::new(0));
                let host: Arc<dyn AiHostBindings> = Arc::new(FakeHost {
                    calls: calls.clone(),
                    result: Ok(MutationApplyResult::Applied {
                        summary: "saved".to_string(),
                        warnings: Vec::new(),
                    }),
                    cancel_during_apply: Some(session.clone()),
                });
                let result = gate_and_apply(
                    &sink,
                    || Some(host),
                    &session,
                    &cancel,
                    pending(mutation_plan("new")),
                )
                .await;
                assert!(matches!(result, Err(AiError::Cancelled)));
                assert_eq!(calls.load(Ordering::SeqCst), 1);
                assert_eq!(
                    session.path_snapshot("notes/a.md"),
                    Some((blake3::hash(b"new").to_hex().to_string(), false))
                );
                assert_eq!(session.status(), SessionStatus::Streaming);
            });
    }

    #[test]
    fn gate_and_apply_preserves_approval_semantics_applied_updates_snapshots() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let sink = RecordingSink::default();
                let session = Arc::new(SessionRuntime::new(ChatMode::Agent));
                session.remember_path_snapshot("notes/a.md".to_string(), "old".to_string(), false);
                let cancel = session.start_run().expect("start run");
                let resolver = session.clone();
                tokio::spawn(async move {
                    wait_for_status(&resolver, SessionStatus::AwaitingApproval).await;
                    resolver.resolve_approval("call-1", true).unwrap();
                });
                let (calls, host) = fake_host(Ok(MutationApplyResult::Applied {
                    summary: "saved".to_string(),
                    warnings: Vec::new(),
                }));
                let outcome = gate_and_apply(
                    &sink,
                    || Some(host),
                    &session,
                    &cancel,
                    pending(mutation_plan("new")),
                )
                .await
                .expect("apply mutation");
                assert_eq!(outcome, ("Applied: saved".to_string(), false));
                assert_eq!(calls.load(Ordering::SeqCst), 1);
                assert_eq!(
                    session.path_snapshot("notes/a.md"),
                    Some((blake3::hash(b"new").to_hex().to_string(), false))
                );
                assert_eq!(session.status(), SessionStatus::Streaming);
            });
    }

    #[test]
    fn gate_and_apply_preserves_approval_semantics_partially_applied_clears_snapshots() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let sink = RecordingSink::default();
                let session = Arc::new(SessionRuntime::new(ChatMode::Agent));
                session.remember_path_snapshot("notes/a.md".to_string(), "old".to_string(), false);
                let cancel = session.start_run().expect("start run");
                let resolver = session.clone();
                tokio::spawn(async move {
                    wait_for_status(&resolver, SessionStatus::AwaitingApproval).await;
                    resolver.resolve_approval("call-1", true).unwrap();
                });
                let (calls, host) = fake_host(Ok(MutationApplyResult::PartiallyApplied {
                    summary: "partial".to_string(),
                    applied: Vec::new(),
                    failed: vec!["notes/a.md".to_string()],
                    skipped: Vec::new(),
                    warnings: Vec::new(),
                }));
                let outcome = gate_and_apply(
                    &sink,
                    || Some(host),
                    &session,
                    &cancel,
                    pending(mutation_plan("new")),
                )
                .await
                .expect("partial apply is reported");
                assert_eq!(calls.load(Ordering::SeqCst), 1);
                assert_eq!(session.path_snapshot("notes/a.md"), None);
                assert!(!outcome.1);
            });
    }

    #[test]
    fn gate_and_apply_preserves_approval_semantics_conflict_is_error_output() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let sink = RecordingSink::default();
                let session = Arc::new(SessionRuntime::new(ChatMode::Agent));
                let cancel = session.start_run().expect("start run");
                let resolver = session.clone();
                tokio::spawn(async move {
                    wait_for_status(&resolver, SessionStatus::AwaitingApproval).await;
                    resolver.resolve_approval("call-1", true).unwrap();
                });
                let (_calls, host) = fake_host(Ok(MutationApplyResult::Conflict {
                    summary: "changed".to_string(),
                    conflicts: vec![ConflictItem {
                        path: "notes/a.md".to_string(),
                        reason: "checksum mismatch".to_string(),
                        expected: Some("old".to_string()),
                        actual: Some("new".to_string()),
                    }],
                }));
                let outcome = gate_and_apply(
                    &sink,
                    || Some(host),
                    &session,
                    &cancel,
                    pending(mutation_plan("new")),
                )
                .await
                .expect("conflict is a tool output");
                assert_eq!(
                    outcome,
                    (
                        "Conflict: changed. notes/a.md (checksum mismatch)".to_string(),
                        true
                    )
                );
            });
    }

    #[test]
    fn gate_and_apply_preserves_approval_semantics_host_failure_propagates() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let sink = RecordingSink::default();
                let session = Arc::new(SessionRuntime::new(ChatMode::Agent));
                let cancel = session.start_run().expect("start run");
                let resolver = session.clone();
                tokio::spawn(async move {
                    wait_for_status(&resolver, SessionStatus::AwaitingApproval).await;
                    resolver.resolve_approval("call-1", true).unwrap();
                });
                let (_calls, host) = fake_host(Err(AiError::State("host failed".to_string())));
                let result = gate_and_apply(
                    &sink,
                    || Some(host),
                    &session,
                    &cancel,
                    pending(mutation_plan("new")),
                )
                .await;
                assert!(matches!(
                    result,
                    Err(AiError::State(message)) if message == "host failed"
                ));
            });
    }

    #[test]
    fn gate_and_apply_preserves_approval_semantics_sender_dropped_is_approval_not_found() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let sink = RecordingSink::default();
                let session = Arc::new(SessionRuntime::new(ChatMode::Agent));
                let cancel = session.start_run().expect("start run");
                let clearer = session.clone();
                tokio::spawn(async move {
                    wait_for_status(&clearer, SessionStatus::AwaitingApproval).await;
                    clearer.clear_approval("call-1");
                });
                let result = timeout(
                    Duration::from_secs(2),
                    gate_and_apply(
                        &sink,
                        || None,
                        &session,
                        &cancel,
                        pending(mutation_plan("new")),
                    ),
                )
                .await
                .expect("sender-drop case must not hang");
                assert!(matches!(result, Err(AiError::ApprovalNotFound)));
            });
    }

    #[test]
    fn resolve_approval_unknown_call_id_is_approval_not_found() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let session = SessionRuntime::new(ChatMode::Agent);
                let receiver = session
                    .begin_awaiting_approval("active".to_string())
                    .expect("start active approval");
                assert!(matches!(
                    session.resolve_approval("unknown", true),
                    Err(AiError::ApprovalNotFound)
                ));
                session
                    .resolve_approval("active", true)
                    .expect("active waiter remains");
                assert!(matches!(
                    receiver.await.expect("receive active decision"),
                    ApprovalDecision::Approve
                ));
            });
    }

    #[test]
    fn run_finalization_always_completes_the_run() {
        let cancelled_sink = RecordingSink::default();
        let cancelled_session = SessionRuntime::new(ChatMode::Agent);
        cancelled_session.start_run().expect("start cancelled run");
        cancelled_session.set_status(SessionStatus::Streaming);
        finalize_run(&cancelled_session, &cancelled_sink, Err(AiError::Cancelled));
        assert_eq!(cancelled_session.status(), SessionStatus::Idle);
        assert_eq!(
            cancelled_sink.events(),
            vec![
                SinkEvent::Error("AI request was cancelled.".to_string()),
                SinkEvent::Done(FinishReason::Cancelled, None)
            ]
        );

        let success_sink = RecordingSink::default();
        let success_session = SessionRuntime::new(ChatMode::Agent);
        success_session.start_run().expect("start successful run");
        let usage = TokenUsage {
            input_tokens: 3,
            output_tokens: 2,
            total_tokens: 5,
            cached_input_tokens: 1,
        };
        finalize_run(
            &success_session,
            &success_sink,
            Ok((FinishReason::Stop, Some(usage))),
        );
        assert_eq!(success_session.status(), SessionStatus::Idle);
        assert_eq!(
            success_sink.events(),
            vec![SinkEvent::Done(FinishReason::Stop, Some((3, 2, 5, 1)))]
        );
    }

    struct ScriptedBackend {
        requests: Mutex<Vec<CompletionTurnRequest>>,
        calls: AtomicUsize,
    }

    impl ScriptedBackend {
        fn new() -> Self {
            Self {
                requests: Mutex::new(Vec::new()),
                calls: AtomicUsize::new(0),
            }
        }
    }

    #[async_trait]
    impl CompletionBackend for ScriptedBackend {
        async fn stream_turn(
            &self,
            request: CompletionTurnRequest,
        ) -> Result<CompletionTurnStream, AiError> {
            self.requests.lock().push(request);
            let call = self.calls.fetch_add(1, Ordering::SeqCst);
            let events = match call {
                0 => vec![
                    CompletionEvent::ToolCalls(vec![ModelToolCall {
                        call_id: "internal-call".to_string(),
                        tool_name: "list_files".to_string(),
                        arguments: json!({ "path": "" }),
                        signature: None,
                        tool_call_id: Some("tool-call-id".to_string()),
                        provider_call_id: Some("provider-call-id".to_string()),
                    }]),
                    CompletionEvent::Finished {
                        finish_reason: FinishReason::ToolCalls,
                        usage: None,
                    },
                ],
                1 => vec![
                    CompletionEvent::TextDelta("done".to_string()),
                    CompletionEvent::Finished {
                        finish_reason: FinishReason::Stop,
                        usage: Some(TokenUsage {
                            input_tokens: 4,
                            output_tokens: 1,
                            total_tokens: 5,
                            cached_input_tokens: 0,
                        }),
                    },
                ],
                other => panic!("unexpected backend round {other}"),
            };
            Ok(Box::pin(futures::stream::iter(events.into_iter().map(Ok))))
        }
    }

    #[test]
    fn session_loop_dispatches_tool_result_and_runs_second_round() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let state = AiState::default();
                state
                    .set_config(AiConfig {
                        provider: ProviderKind::OpenAi,
                        api_key: None,
                        openai_api_key: None,
                        openai_base_url: Some("http://127.0.0.1:11434/v1".to_string()),
                        openai_model: Some("fake".to_string()),
                        model: "fake".to_string(),
                        server_url: None,
                        round_limit: 3,
                        proxy_tool_timeout_ms: 2_000,
                    })
                    .expect("set fake config");
                let backend = Arc::new(ScriptedBackend::new());
                state.set_backend_for_test(backend.clone());
                state.register_proxy_tool(ProxyToolDescriptor {
                    tool_id: "proxy.list_files".to_string(),
                    name: "list_files".to_string(),
                    description: "List files".to_string(),
                    parameters: json!({ "type": "object" }),
                    category: "test".to_string(),
                });
                let session = state.create_session(ChatMode::Agent);
                let sink = Arc::new(RecordingSink::default());
                let responder_sink = sink.clone();
                let broker = state.proxy_broker().clone();
                let responder = tokio::spawn(async move {
                    timeout(
                        Duration::from_secs(2),
                        responder_sink.proxy_called.notified(),
                    )
                    .await
                    .expect("proxy call emitted");
                    broker
                        .resolve(
                            "internal-call",
                            ProxyToolResult {
                                output: r#"{"files":[]}"#.to_string(),
                                is_error: false,
                            },
                        )
                        .expect("resolve proxy call");
                });
                let result = run_turn_inner(
                    None,
                    sink.as_ref(),
                    &state,
                    session,
                    ChatMode::Agent,
                    "go".to_string(),
                    EditorContext::default(),
                )
                .await
                .expect("run scripted turn");
                responder.await.expect("proxy responder");
                assert_eq!(result.0, FinishReason::Stop);
                let usage = result.1.expect("second-round usage");
                assert_eq!(usage.input_tokens, 4);
                assert_eq!(usage.output_tokens, 1);
                assert_eq!(usage.total_tokens, 5);
                assert_eq!(backend.calls.load(Ordering::SeqCst), 2);
                let requests = backend.requests.lock();
                assert_eq!(requests.len(), 2);
                let tool_results = requests[1]
                    .messages
                    .iter()
                    .filter_map(|message| match message {
                        ChatMessage::ToolResult {
                            call_id,
                            output,
                            tool_call_id,
                            provider_call_id,
                            ..
                        } => Some((call_id, output, tool_call_id, provider_call_id)),
                        _ => None,
                    })
                    .collect::<Vec<_>>();
                assert_eq!(tool_results.len(), 1);
                assert_eq!(tool_results[0].0, "internal-call");
                assert_eq!(tool_results[0].1, r#"{"files":[]}"#);
                assert_eq!(tool_results[0].2.as_deref(), Some("tool-call-id"));
                assert_eq!(tool_results[0].3.as_deref(), Some("provider-call-id"));
                let events = sink.events();
                assert_eq!(
                    events
                        .iter()
                        .filter(|event| matches!(event, SinkEvent::ToolStart(_)))
                        .count(),
                    1
                );
                assert_eq!(
                    events
                        .iter()
                        .filter(|event| matches!(event, SinkEvent::ProxyCall(_)))
                        .count(),
                    1
                );
                assert_eq!(
                    events
                        .iter()
                        .filter(|event| matches!(event, SinkEvent::ToolEnd(_, _, _)))
                        .count(),
                    1
                );
                assert_eq!(
                    events
                        .iter()
                        .filter(
                            |event| matches!(event, SinkEvent::StreamChunk(text) if text == "done")
                        )
                        .count(),
                    1
                );
            });
    }
}
