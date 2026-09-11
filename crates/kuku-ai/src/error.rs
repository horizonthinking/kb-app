use http::StatusCode;
use rig::{completion::CompletionError, http_client};
use thiserror::Error;

#[derive(Debug, Error, Clone)]
pub enum AiError {
    #[error("AI is not configured. Choose a connection in Settings and add its API key or model.")]
    NotConfigured,
    #[error("AI session not found.")]
    SessionNotFound,
    #[error("AI session is already running.")]
    SessionBusy,
    #[error("AI request was cancelled.")]
    Cancelled,
    #[error("AI host is not registered.")]
    HostUnavailable,
    #[error("Approval request not found.")]
    ApprovalNotFound,
    #[error("Authorization expired or invalid.")]
    Unauthorized,
    #[error("Provider init failed: {0}")]
    ProviderInit(String),
    #[error("Provider request failed: {0}")]
    ProviderError(String),
    #[error("Invalid arguments: {0}")]
    InvalidArguments(String),
    #[error("Tool not found: {0}")]
    ToolNotFound(String),
    #[error("Proxy tool timeout: {0}")]
    ProxyTimeout(String),
    #[error("State error: {0}")]
    State(String),
    #[error("I/O error: {0}")]
    Io(String),
}

impl AiError {
    pub fn message(&self) -> String {
        self.to_string()
    }
}

impl From<std::io::Error> for AiError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value.to_string())
    }
}

impl From<CompletionError> for AiError {
    fn from(value: CompletionError) -> Self {
        map_completion_error(value)
    }
}

pub fn map_status(status: StatusCode) -> AiError {
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => AiError::Unauthorized,
        StatusCode::TOO_MANY_REQUESTS => AiError::ProviderError(format!("rate limited: {status}")),
        _ => AiError::ProviderError(format!("HTTP status {status}")),
    }
}

pub fn map_completion_error(error: CompletionError) -> AiError {
    let status = match &error {
        CompletionError::HttpError(http_client::Error::InvalidStatusCode(status))
        | CompletionError::HttpError(http_client::Error::InvalidStatusCodeWithMessage(
            status,
            ..,
        )) => Some(*status),
        CompletionError::ProviderError(text) => status_from_rig_display(text),
        _ => None,
    };

    match status {
        Some(StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) => AiError::Unauthorized,
        Some(StatusCode::TOO_MANY_REQUESTS) => {
            let detail = match error {
                CompletionError::ProviderError(text) => text,
                CompletionError::HttpError(error) => error.to_string(),
                other => other.to_string(),
            };
            AiError::ProviderError(format!("rate limited: {detail}"))
        }
        _ => AiError::ProviderError(error.to_string()),
    }
}

fn status_from_rig_display(text: &str) -> Option<StatusCode> {
    let remainder = text.strip_prefix("Invalid status code ")?;
    let digits = remainder.get(..3)?;
    if !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    if remainder
        .as_bytes()
        .get(3)
        .is_some_and(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
    {
        return None;
    }
    StatusCode::from_u16(digits.parse().ok()?).ok()
}

#[derive(Debug, Error, Clone)]
pub enum ToolError {
    #[error("Invalid tool arguments: {0}")]
    InvalidArguments(String),
    #[error("Tool execution failed: {0}")]
    ExecutionFailed(String),
}
