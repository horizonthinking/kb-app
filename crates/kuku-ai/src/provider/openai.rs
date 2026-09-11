use std::{collections::BTreeSet, net::IpAddr};

use async_stream::stream;
use async_trait::async_trait;
use futures::{Stream, StreamExt};
use rig::{
    OneOrMany,
    client::CompletionClient,
    completion::{AssistantContent, CompletionError, CompletionModel, Message, ToolDefinition},
    http_client::{self, HttpClientExt, NoBody},
    message::{Text, ToolCall, ToolChoice as RigToolChoice, ToolFunction},
    providers::openai,
    streaming::StreamedAssistantContent,
};
use serde::Deserialize;
use url::{Host, Url};

use crate::{
    AiError,
    error::map_completion_error,
    provider::{
        CompletionBackend, CompletionEvent, CompletionTurnRequest, CompletionTurnStream, ToolChoice,
    },
    tools::ToolDescriptor,
    types::{ChatMessage, FinishReason, ModelToolCall, TokenUsage},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KeyRequirement {
    Required,
    Optional,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Endpoint {
    pub(crate) base: String,
    pub(crate) requirement: KeyRequirement,
}

pub struct OpenAiBackend<H = reqwest::Client> {
    client: openai::CompletionsClient<H>,
    model_id: String,
}

impl OpenAiBackend<reqwest::Client> {
    pub fn new(api_key: Option<&str>, base_url: &str, model: &str) -> Result<Self, AiError> {
        Self::with_http_client(api_key, base_url, model, reqwest::Client::default())
    }
}

impl<H> OpenAiBackend<H>
where
    H: HttpClientExt + Clone + std::fmt::Debug + Default + 'static,
{
    pub(crate) fn with_http_client(
        api_key: Option<&str>,
        base_url: &str,
        model: &str,
        http_client: H,
    ) -> Result<Self, AiError> {
        let key = normalize_api_key(api_key);
        let endpoint = parse_endpoint(base_url, key.is_some())?;
        let key = match (key, endpoint.requirement) {
            (Some(key), _) => key,
            (None, KeyRequirement::Optional) => "local".to_string(),
            (None, KeyRequirement::Required) => return Err(AiError::NotConfigured),
        };
        let client = openai::Client::builder()
            .api_key(key)
            .base_url(&endpoint.base)
            .http_client(http_client)
            .build()
            .map_err(|error| AiError::ProviderInit(error.to_string()))?
            .completions_api();

        Ok(Self {
            client,
            model_id: model.to_string(),
        })
    }
}

#[async_trait]
impl<H> CompletionBackend for OpenAiBackend<H>
where
    H: HttpClientExt + Clone + std::fmt::Debug + Default + 'static,
{
    async fn stream_turn(
        &self,
        request: CompletionTurnRequest,
    ) -> Result<CompletionTurnStream, AiError> {
        let model_name = self.model_id.clone();
        let model = self.client.completion_model(model_name.clone());
        let (history, prompt) = split_history(request.messages)?;
        let has_tools = !request.tools.is_empty();
        let mut builder = model
            .completion_request(prompt)
            .messages(history)
            .model(model_name)
            .tools(
                request
                    .tools
                    .into_iter()
                    .map(tool_definition_from)
                    .collect(),
            );

        if has_tools {
            builder = builder.tool_choice(match request.tool_choice {
                ToolChoice::Auto => RigToolChoice::Auto,
                ToolChoice::Required => RigToolChoice::Required,
                ToolChoice::None => RigToolChoice::None,
            });
        }
        if let Some(system_prompt) = request.system_prompt {
            builder = builder.preamble(system_prompt);
        }

        let response = builder.stream().await.map_err(map_completion_error)?;
        Ok(adapt_stream(response))
    }
}

pub(crate) fn normalize_api_key(api_key: Option<&str>) -> Option<String> {
    api_key
        .map(str::trim)
        .filter(|key| !key.is_empty())
        .map(str::to_string)
}

pub(crate) fn key_requirement(host: &str) -> KeyRequirement {
    let normalized = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if normalized == "localhost"
        || normalized.ends_with(".local")
        || normalized.ends_with(".ts.net")
    {
        return KeyRequirement::Optional;
    }

    match normalized.parse::<IpAddr>() {
        Ok(IpAddr::V4(address)) if address.is_loopback() || address.is_private() => {
            KeyRequirement::Optional
        }
        Ok(IpAddr::V6(address)) if address.is_loopback() => KeyRequirement::Optional,
        _ => KeyRequirement::Required,
    }
}

pub(crate) fn parse_endpoint(base_url: &str, key_present: bool) -> Result<Endpoint, AiError> {
    let mut url = Url::parse(base_url.trim())
        .map_err(|error| AiError::InvalidArguments(format!("invalid OpenAI base URL: {error}")))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(AiError::InvalidArguments(
            "OpenAI base URL must use http or https".to_string(),
        ));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(AiError::InvalidArguments(
            "OpenAI base URL must not contain userinfo".to_string(),
        ));
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(AiError::InvalidArguments(
            "OpenAI base URL must not contain a query or fragment".to_string(),
        ));
    }

    let host = match url.host() {
        Some(Host::Domain(host)) => host.to_string(),
        Some(Host::Ipv4(host)) => host.to_string(),
        Some(Host::Ipv6(host)) => host.to_string(),
        None => {
            return Err(AiError::InvalidArguments(
                "OpenAI base URL must contain a host".to_string(),
            ));
        }
    };
    let requirement = key_requirement(&host);
    if url.scheme() != "https" && (key_present || requirement == KeyRequirement::Required) {
        return Err(AiError::InvalidArguments(
            "OpenAI base URL must use https when a key is present or the host requires a key"
                .to_string(),
        ));
    }

    let path = url.path().trim_end_matches('/').to_string();
    url.set_path(if path.is_empty() { "/v1" } else { &path });

    Ok(Endpoint {
        base: url.to_string().trim_end_matches('/').to_string(),
        requirement,
    })
}

pub(crate) async fn list_models(
    base_url: &str,
    api_key: Option<&str>,
) -> Result<Vec<String>, AiError> {
    let key = normalize_api_key(api_key);
    list_models_at(
        &reqwest::Client::default(),
        &parse_endpoint(base_url, key.is_some())?,
        key.as_deref(),
    )
    .await
}

pub(crate) async fn list_models_at<H: HttpClientExt>(
    client: &H,
    endpoint: &Endpoint,
    api_key: Option<&str>,
) -> Result<Vec<String>, AiError> {
    let mut request = http_client::Request::get(format!("{}/models", endpoint.base))
        .body(NoBody)
        .map_err(|error| AiError::ProviderError(error.to_string()))?;
    if let Some(key) = api_key {
        http_client::bearer_auth_header(request.headers_mut(), key)
            .map_err(|error| AiError::ProviderError(error.to_string()))?;
    }

    let response: http_client::Response<http_client::LazyBody<Vec<u8>>> = client
        .send(request)
        .await
        .map_err(|error| map_completion_error(CompletionError::HttpError(error)))?;
    if !response.status().is_success() {
        return Err(crate::error::map_status(response.status()));
    }
    let body = http_client::text(response)
        .await
        .map_err(|error| map_completion_error(CompletionError::HttpError(error)))?;
    let response: ModelsResponse =
        serde_json::from_str(&body).map_err(|error| AiError::ProviderError(error.to_string()))?;
    Ok(response
        .data
        .into_iter()
        .map(|model| model.id)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect())
}

#[derive(Deserialize)]
struct ModelsResponse {
    data: Vec<ModelEntry>,
}

#[derive(Deserialize)]
struct ModelEntry {
    id: String,
}

fn adapt_stream<S>(input: S) -> CompletionTurnStream
where
    S: Stream<
            Item = Result<
                StreamedAssistantContent<
                    openai::completion::streaming::StreamingCompletionResponse,
                >,
                CompletionError,
            >,
        > + Send
        + 'static,
{
    let adapted = stream! {
        let mut input = Box::pin(input);
        let mut saw_tool_calls = false;
        let mut yielded_finished = false;

        while let Some(item) = input.next().await {
            match item {
                Err(error) => {
                    yield Err(map_completion_error(error));
                    break;
                }
                Ok(StreamedAssistantContent::Text(Text { text })) => {
                    if !text.is_empty() {
                        yield Ok(CompletionEvent::TextDelta(text));
                    }
                }
                Ok(StreamedAssistantContent::ToolCall {
                    tool_call,
                    internal_call_id,
                }) => {
                    saw_tool_calls = true;
                    yield Ok(CompletionEvent::ToolCalls(vec![ModelToolCall {
                        call_id: internal_call_id,
                        tool_name: tool_call.function.name,
                        arguments: tool_call.function.arguments,
                        signature: None,
                        tool_call_id: Some(tool_call.id),
                        provider_call_id: tool_call.call_id,
                    }]));
                }
                Ok(StreamedAssistantContent::ToolCallDelta { .. })
                | Ok(StreamedAssistantContent::Reasoning(_))
                | Ok(StreamedAssistantContent::ReasoningDelta { .. }) => {}
                Ok(StreamedAssistantContent::Final(response)) => {
                    yielded_finished = true;
                    yield Ok(CompletionEvent::Finished {
                        finish_reason: if saw_tool_calls {
                            FinishReason::ToolCalls
                        } else {
                            FinishReason::Stop
                        },
                        usage: Some(token_usage_from_response(&response)),
                    });
                }
            }
        }

        if !yielded_finished {
            yield Ok(CompletionEvent::Finished {
                finish_reason: if saw_tool_calls {
                    FinishReason::ToolCalls
                } else {
                    FinishReason::Stop
                },
                usage: None,
            });
        }
    };
    Box::pin(adapted)
}

fn token_usage_from_response(
    response: &openai::completion::streaming::StreamingCompletionResponse,
) -> TokenUsage {
    let prompt = response.usage.prompt_tokens as u64;
    let total = response.usage.total_tokens as u64;
    TokenUsage {
        input_tokens: prompt,
        output_tokens: total.saturating_sub(prompt),
        total_tokens: total,
        cached_input_tokens: response
            .usage
            .prompt_tokens_details
            .as_ref()
            .map(|details| details.cached_tokens as u64)
            .unwrap_or(0),
    }
}

fn split_history(messages: Vec<ChatMessage>) -> Result<(Vec<Message>, Message), AiError> {
    let mut iter = messages.into_iter();
    let Some(last) = iter.next_back() else {
        return Err(AiError::InvalidArguments(
            "Completion request requires at least one message".to_string(),
        ));
    };
    let history = iter
        .map(into_rig_message)
        .collect::<Result<Vec<_>, AiError>>()?;
    Ok((history, into_rig_message(last)?))
}

fn tool_definition_from(tool: ToolDescriptor) -> ToolDefinition {
    ToolDefinition {
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
    }
}

fn into_rig_message(message: ChatMessage) -> Result<Message, AiError> {
    Ok(match message {
        ChatMessage::System { .. } => {
            return Err(AiError::InvalidArguments(
                "System messages should be passed via the system prompt".to_string(),
            ));
        }
        ChatMessage::User { content, .. } => Message::user(content),
        ChatMessage::ToolResult {
            call_id,
            output,
            tool_call_id,
            provider_call_id,
            ..
        } => {
            let tool_result_id = tool_call_id.unwrap_or(call_id.clone());
            match provider_call_id {
                Some(provider_call_id) => Message::tool_result_with_call_id(
                    tool_result_id,
                    Some(provider_call_id),
                    output,
                ),
                None => Message::tool_result(tool_result_id, output),
            }
        }
        ChatMessage::Assistant {
            content,
            tool_calls,
        } => {
            let mut items = Vec::new();
            if !content.is_empty() {
                items.push(AssistantContent::Text(Text { text: content }));
            }
            for tool_call in tool_calls {
                items.push(AssistantContent::ToolCall(ToolCall {
                    id: tool_call
                        .tool_call_id
                        .clone()
                        .unwrap_or_else(|| tool_call.call_id.clone()),
                    call_id: tool_call
                        .provider_call_id
                        .clone()
                        .or_else(|| Some(tool_call.call_id.clone())),
                    function: ToolFunction::new(tool_call.tool_name, tool_call.arguments),
                    signature: None,
                    additional_params: None,
                }));
            }
            let content = OneOrMany::many(items).map_err(|_| {
                AiError::InvalidArguments("Assistant message cannot be empty".to_string())
            })?;
            Message::Assistant { id: None, content }
        }
    })
}

#[cfg(test)]
mod tests {
    use std::{
        collections::BTreeMap,
        fs::{self, OpenOptions},
        future::Future,
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        path::PathBuf,
        sync::{Mutex, OnceLock, mpsc},
        thread,
        time::{Duration, SystemTime, UNIX_EPOCH},
    };

    use futures::StreamExt;
    use rig::{
        completion::{AssistantContent, CompletionError, Message, message::UserContent},
        http_client::{self, HttpClientExt, MultipartForm, NoBody},
        message::{Text, ToolCall, ToolFunction},
        providers::openai::{
            self,
            completion::{PromptTokensDetails, Usage},
        },
        streaming::StreamedAssistantContent,
        wasm_compat::WasmCompatSend,
    };
    use serde::Deserialize;
    use serde_json::{Value, json};
    use tokio::runtime::Builder;
    use tokio_util::bytes::Bytes;
    use uuid::Uuid;

    use super::{
        Endpoint, KeyRequirement, OpenAiBackend, adapt_stream, into_rig_message, key_requirement,
        list_models, list_models_at, normalize_api_key, parse_endpoint, token_usage_from_response,
    };
    use crate::{
        AiError,
        error::map_completion_error,
        provider::{
            CompletionBackend, CompletionEvent, CompletionTurnRequest, CompletionTurnStream,
            ToolChoice,
        },
        tools::{ToolAccess, ToolDescriptor, ToolSource},
        types::{ChatMessage, FinishReason, ModelToolCall},
    };

    const LIVE_STREAMS: &str = "live_streams_text_with_usage_identities";
    const LIVE_TOOLS: &str = "live_two_round_tool_call_replays_ids";
    const LIVE_MODELS: &str = "live_list_models_contains_the_configured_model_once";

    #[derive(Debug)]
    struct RecordedRequest {
        request_line: String,
        headers: BTreeMap<String, String>,
        body: Vec<u8>,
    }

    #[derive(Debug, Deserialize)]
    struct PolicyFixture {
        url: String,
        key_present: bool,
        requirement: String,
        accepted: bool,
    }

    fn runtime() -> tokio::runtime::Runtime {
        Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build current-thread runtime")
    }

    fn tool_descriptor() -> ToolDescriptor {
        ToolDescriptor {
            tool_id: "builtin.list_files".to_string(),
            name: "list_files".to_string(),
            description: "List files".to_string(),
            parameters: json!({
                "type": "object",
                "properties": { "path": { "type": "string" } }
            }),
            category: "test".to_string(),
            access: ToolAccess::ReadOnly,
            source: ToolSource::Native,
        }
    }

    fn turn_request(
        messages: Vec<ChatMessage>,
        tools: Vec<ToolDescriptor>,
        tool_choice: ToolChoice,
    ) -> CompletionTurnRequest {
        CompletionTurnRequest {
            model: "test-model".to_string(),
            system_prompt: None,
            messages,
            tools,
            tool_choice,
            authorization_header: None,
        }
    }

    fn user_message(content: &str) -> ChatMessage {
        ChatMessage::User {
            content: content.to_string(),
            editor_context: None,
        }
    }

    fn http_response(status: &str, content_type: &str, body: &str) -> Vec<u8> {
        format!(
            "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    fn successful_sse(text: &str, prompt: usize, total: usize, cached: usize) -> String {
        format!(
            "data: {{\"choices\":[{{\"delta\":{{\"content\":{}}},\"finish_reason\":\"stop\"}}]}}\n\ndata: {{\"choices\":[],\"usage\":{{\"prompt_tokens\":{prompt},\"total_tokens\":{total},\"prompt_tokens_details\":{{\"cached_tokens\":{cached}}}}}}}\n\ndata: [DONE]\n\n",
            serde_json::to_string(text).expect("serialize SSE text")
        )
    }

    fn spawn_stub(response: Vec<u8>) -> (String, mpsc::Receiver<RecordedRequest>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind stub listener");
        let address = listener.local_addr().expect("stub address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept stub request");
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .expect("set read timeout");
            let request = read_request(&mut stream);
            sender.send(request).expect("record stub request");
            stream.write_all(&response).expect("write stub response");
            stream.flush().expect("flush stub response");
        });
        (format!("http://{address}"), receiver)
    }

    fn read_request(stream: &mut TcpStream) -> RecordedRequest {
        let mut bytes = Vec::new();
        let mut buffer = [0_u8; 4096];
        let header_end = loop {
            let read = stream.read(&mut buffer).expect("read stub request");
            assert_ne!(read, 0, "request ended before headers");
            bytes.extend_from_slice(&buffer[..read]);
            if let Some(position) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
                break position + 4;
            }
        };
        let header_text = String::from_utf8(bytes[..header_end].to_vec()).expect("UTF-8 headers");
        let mut lines = header_text.split("\r\n");
        let request_line = lines.next().expect("request line").to_string();
        let mut headers = BTreeMap::new();
        for line in lines.filter(|line| !line.is_empty()) {
            let (name, value) = line.split_once(':').expect("header separator");
            headers.insert(name.to_ascii_lowercase(), value.trim().to_string());
        }
        let content_length = headers
            .get("content-length")
            .map(|value| value.parse::<usize>().expect("content length"))
            .unwrap_or(0);
        while bytes.len() < header_end + content_length {
            let read = stream.read(&mut buffer).expect("read request body");
            assert_ne!(read, 0, "request ended before body");
            bytes.extend_from_slice(&buffer[..read]);
        }
        RecordedRequest {
            request_line,
            headers,
            body: bytes[header_end..header_end + content_length].to_vec(),
        }
    }

    fn collect_stream(stream: CompletionTurnStream) -> Vec<Result<CompletionEvent, AiError>> {
        runtime().block_on(async move { stream.collect().await })
    }

    #[test]
    fn tool_result_uses_original_tool_call_ids() {
        let message = ChatMessage::ToolResult {
            call_id: "internal-call".into(),
            tool_name: "list_files".into(),
            output: "{\"files\":[]}".into(),
            is_error: false,
            tool_call_id: Some("openai-tool-id".into()),
            provider_call_id: Some("provider-call-id".into()),
        };
        let Message::User { content } = into_rig_message(message).expect("convert tool result")
        else {
            panic!("tool result should become a user message");
        };
        let Some(UserContent::ToolResult(result)) = content.iter().next() else {
            panic!("user message should contain a tool result");
        };
        assert_eq!(result.id, "openai-tool-id");
        assert_eq!(result.call_id.as_deref(), Some("provider-call-id"));
    }

    #[test]
    fn tool_result_without_provider_call_id_still_uses_tool_call_id() {
        let message = ChatMessage::ToolResult {
            call_id: "internal-call".into(),
            tool_name: "list_files".into(),
            output: "plain text".into(),
            is_error: false,
            tool_call_id: Some("openai-tool-id".into()),
            provider_call_id: None,
        };
        let Message::User { content } = into_rig_message(message).expect("convert tool result")
        else {
            panic!("tool result should become a user message");
        };
        let Some(UserContent::ToolResult(result)) = content.iter().next() else {
            panic!("user message should contain a tool result");
        };
        assert_eq!(result.id, "openai-tool-id");
        assert_eq!(result.call_id, None);
    }

    #[test]
    fn assistant_tool_call_round_trips_all_three_ids_without_signature() {
        let message = ChatMessage::Assistant {
            content: String::new(),
            tool_calls: vec![ModelToolCall {
                call_id: "internal-call".into(),
                tool_name: "list_files".into(),
                arguments: json!({ "path": "" }),
                signature: Some(b"must-not-cross".to_vec()),
                tool_call_id: Some("openai-tool-id".into()),
                provider_call_id: Some("provider-call-id".into()),
            }],
        };
        let Message::Assistant { content, .. } =
            into_rig_message(message).expect("convert assistant tool call")
        else {
            panic!("tool call should become an assistant message");
        };
        let Some(AssistantContent::ToolCall(call)) = content.iter().next() else {
            panic!("assistant message should contain a tool call");
        };
        assert_eq!(call.id, "openai-tool-id");
        assert_eq!(call.call_id.as_deref(), Some("provider-call-id"));
        assert_eq!(call.signature, None);
    }

    #[test]
    fn parse_endpoint_normalizes_path_and_strips_trailing_slash() {
        for (url, key_present, expected) in [
            ("https://api.openai.com", true, "https://api.openai.com/v1"),
            (
                "https://openrouter.ai/api/v1",
                true,
                "https://openrouter.ai/api/v1",
            ),
            (
                "http://127.0.0.1:11434/",
                false,
                "http://127.0.0.1:11434/v1",
            ),
            (
                "http://127.0.0.1:11434/v1/",
                false,
                "http://127.0.0.1:11434/v1",
            ),
        ] {
            assert_eq!(
                parse_endpoint(url, key_present)
                    .expect("endpoint should parse")
                    .base,
                expected
            );
        }
    }

    #[test]
    fn endpoint_policy_matches_shared_fixtures() {
        let fixtures: Vec<PolicyFixture> =
            serde_json::from_str(include_str!("../../fixtures/host_policy.json"))
                .expect("parse policy fixtures");
        assert_eq!(fixtures.len(), 25);
        for fixture in fixtures {
            let normalized_key = normalize_api_key(if fixture.key_present {
                Some("  fixture-key  ")
            } else {
                Some("   ")
            });
            assert_eq!(normalized_key.is_some(), fixture.key_present);
            let requirement = url::Url::parse(&fixture.url)
                .ok()
                .and_then(|url| url.host_str().map(key_requirement))
                .unwrap_or(KeyRequirement::Required);
            assert_eq!(
                requirement,
                match fixture.requirement.as_str() {
                    "required" => KeyRequirement::Required,
                    "optional" => KeyRequirement::Optional,
                    other => panic!("unexpected requirement {other}"),
                },
                "requirement for {}",
                fixture.url
            );
            assert_eq!(
                parse_endpoint(&fixture.url, normalized_key.is_some()).is_ok(),
                fixture.accepted,
                "acceptance for {}",
                fixture.url
            );
        }
    }

    #[test]
    fn adapt_stream_synthesizes_finished_when_stream_ends_early() {
        let input = futures::stream::iter(vec![Ok(StreamedAssistantContent::Text::<
            openai::completion::streaming::StreamingCompletionResponse,
        >(Text {
            text: "hello".to_string(),
        }))]);
        let events = collect_stream(adapt_stream(input));
        assert_eq!(events.len(), 2);
        assert!(matches!(
            &events[0],
            Ok(CompletionEvent::TextDelta(text)) if text == "hello"
        ));
        assert!(matches!(
            &events[1],
            Ok(CompletionEvent::Finished {
                finish_reason: FinishReason::Stop,
                usage: None
            })
        ));
    }

    #[test]
    fn adapt_stream_reports_tool_calls_finish_reason_and_three_ids() {
        let input = futures::stream::iter(vec![
            Ok(StreamedAssistantContent::ToolCall::<
                openai::completion::streaming::StreamingCompletionResponse,
            > {
                tool_call: ToolCall {
                    id: "openai-tool-id".to_string(),
                    call_id: Some("provider-call-id".to_string()),
                    function: ToolFunction::new("list_files".to_string(), json!({ "path": "" })),
                    signature: None,
                    additional_params: None,
                },
                internal_call_id: "internal-call".to_string(),
            }),
            Ok(StreamedAssistantContent::Final(
                openai::completion::streaming::StreamingCompletionResponse {
                    usage: Usage::default(),
                },
            )),
        ]);
        let events = collect_stream(adapt_stream(input));
        assert_eq!(events.len(), 2);
        let Ok(CompletionEvent::ToolCalls(calls)) = &events[0] else {
            panic!("first event should contain tool calls");
        };
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].call_id, "internal-call");
        assert_eq!(calls[0].tool_call_id.as_deref(), Some("openai-tool-id"));
        assert_eq!(
            calls[0].provider_call_id.as_deref(),
            Some("provider-call-id")
        );
        assert_eq!(calls[0].signature, None);
        assert!(matches!(
            &events[1],
            Ok(CompletionEvent::Finished {
                finish_reason: FinishReason::ToolCalls,
                usage: Some(_)
            })
        ));
    }

    #[test]
    fn usage_from_final_response_maps_cached_input_tokens() {
        let response = openai::completion::streaming::StreamingCompletionResponse {
            usage: Usage {
                prompt_tokens: 120,
                total_tokens: 150,
                prompt_tokens_details: Some(PromptTokensDetails { cached_tokens: 100 }),
            },
        };
        let usage = token_usage_from_response(&response);
        assert_eq!(usage.input_tokens, 120);
        assert_eq!(usage.output_tokens, 30);
        assert_eq!(usage.total_tokens, 150);
        assert_eq!(usage.cached_input_tokens, 100);
    }

    #[test]
    fn usage_with_total_below_prompt_saturates_output_to_zero() {
        let response = openai::completion::streaming::StreamingCompletionResponse {
            usage: Usage {
                prompt_tokens: 120,
                total_tokens: 100,
                prompt_tokens_details: None,
            },
        };
        let usage = token_usage_from_response(&response);
        assert_eq!(usage.input_tokens, 120);
        assert_eq!(usage.output_tokens, 0);
        assert_eq!(usage.total_tokens, 100);
        assert_eq!(usage.cached_input_tokens, 0);
    }

    #[test]
    fn map_completion_error_classifies_401_403_429() {
        let unauthorized = map_completion_error(CompletionError::HttpError(
            http_client::Error::InvalidStatusCode(http::StatusCode::UNAUTHORIZED),
        ));
        let forbidden = map_completion_error(CompletionError::HttpError(
            http_client::Error::InvalidStatusCodeWithMessage(
                http::StatusCode::FORBIDDEN,
                "denied".to_string(),
            ),
        ));
        let structured_rate_limited = map_completion_error(CompletionError::HttpError(
            http_client::Error::InvalidStatusCodeWithMessage(
                http::StatusCode::TOO_MANY_REQUESTS,
                "stub".to_string(),
            ),
        ));
        let textual_rate_limited = map_completion_error(CompletionError::ProviderError(
            "Invalid status code 429 Too Many Requests with message: stub".to_string(),
        ));
        assert!(matches!(unauthorized, AiError::Unauthorized));
        assert!(matches!(forbidden, AiError::Unauthorized));
        assert!(matches!(
            structured_rate_limited,
            AiError::ProviderError(message)
                if message == "rate limited: Invalid status code 429 Too Many Requests with message: stub"
        ));
        assert!(matches!(
            textual_rate_limited,
            AiError::ProviderError(message)
                if message == "rate limited: Invalid status code 429 Too Many Requests with message: stub"
        ));
        assert!(matches!(
            map_completion_error(CompletionError::ProviderError(
                "prefix Invalid status code 401 Unauthorized".to_string()
            )),
            AiError::ProviderError(message)
                if message == "ProviderError: prefix Invalid status code 401 Unauthorized"
        ));
    }

    #[test]
    fn empty_key_is_allowed_only_for_optional_hosts_and_sends_local_placeholder() {
        assert_eq!(normalize_api_key(None), None);
        assert_eq!(normalize_api_key(Some("")), None);
        assert_eq!(normalize_api_key(Some("   ")), None);
        assert_eq!(
            normalize_api_key(Some("  sk-test  ")),
            Some("sk-test".to_string())
        );
        assert!(matches!(
            OpenAiBackend::new(None, "https://api.openai.com/v1", "model"),
            Err(AiError::NotConfigured)
        ));

        let body = successful_sse("ok", 1, 2, 0);
        let (base, request_rx) = spawn_stub(http_response("200 OK", "text/event-stream", &body));
        runtime().block_on(async {
            let backend = OpenAiBackend::new(None, &base, "model").expect("local backend");
            let mut stream = backend
                .stream_turn(turn_request(
                    vec![user_message("hello")],
                    Vec::new(),
                    ToolChoice::Auto,
                ))
                .await
                .expect("start local stream");
            while stream.next().await.is_some() {}
        });
        let request = request_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("record local request");
        assert_eq!(
            request.headers.get("authorization").map(String::as_str),
            Some("Bearer local")
        );
    }

    #[test]
    fn list_models_against_local_stub_server() {
        for suffix in ["", "/", "/v1", "/v1/"] {
            let (base, request_rx) = spawn_stub(http_response(
                "200 OK",
                "application/json",
                r#"{"data":[{"id":"zeta"},{"id":"alpha"},{"id":"zeta"}]}"#,
            ));
            let models = runtime()
                .block_on(list_models(&format!("{base}{suffix}"), None))
                .expect("list local models");
            assert_eq!(models, vec!["alpha".to_string(), "zeta".to_string()]);
            let request = request_rx
                .recv_timeout(Duration::from_secs(5))
                .expect("record models request");
            assert_eq!(request.request_line, "GET /v1/models HTTP/1.1");
            assert_eq!(request.headers.get("authorization"), None);
        }

        let (base, request_rx) = spawn_stub(http_response(
            "200 OK",
            "application/json",
            r#"{"data":[{"id":"model-a"}]}"#,
        ));
        let endpoint = Endpoint {
            base: format!("{base}/v1"),
            requirement: KeyRequirement::Required,
        };
        let key = normalize_api_key(Some("  sk-test  "));
        let models = runtime()
            .block_on(list_models_at(
                &reqwest::Client::default(),
                &endpoint,
                key.as_deref(),
            ))
            .expect("keyed model request");
        assert_eq!(models, vec!["model-a".to_string()]);
        let request = request_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("record keyed models request");
        assert_eq!(request.request_line, "GET /v1/models HTTP/1.1");
        assert_eq!(
            request.headers.get("authorization").map(String::as_str),
            Some("Bearer sk-test")
        );

        let (base, request_rx) = spawn_stub(http_response(
            "200 OK",
            "application/json",
            r#"{"data":[{"id":"model-a"}]}"#,
        ));
        let endpoint = Endpoint {
            base: format!("{base}/v1"),
            requirement: KeyRequirement::Optional,
        };
        let key = normalize_api_key(Some("   "));
        runtime()
            .block_on(list_models_at(
                &reqwest::Client::default(),
                &endpoint,
                key.as_deref(),
            ))
            .expect("empty-key model request");
        let request = request_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("record empty-key models request");
        assert_eq!(request.headers.get("authorization"), None);

        let (base, _request_rx) = spawn_stub(http_response(
            "401 Unauthorized",
            "application/json",
            r#"{"error":{"message":"stub"}}"#,
        ));
        let error = runtime()
            .block_on(list_models(&base, None))
            .expect_err("401 should fail");
        assert!(matches!(error, AiError::Unauthorized));
    }

    #[test]
    fn stream_turn_classifies_401_403_429_from_stub_server() {
        for (status, expected) in [
            ("401 Unauthorized", None),
            ("403 Forbidden", None),
            (
                "429 Too Many Requests",
                Some(
                    "rate limited: Invalid status code 429 Too Many Requests with message: {\"error\":{\"message\":\"stub\"}}",
                ),
            ),
        ] {
            let (base, _request_rx) = spawn_stub(http_response(
                status,
                "application/json",
                r#"{"error":{"message":"stub"}}"#,
            ));
            let error = runtime().block_on(async {
                let backend = OpenAiBackend::new(None, &base, "model").expect("local backend");
                match backend
                    .stream_turn(turn_request(
                        vec![user_message("hello")],
                        Vec::new(),
                        ToolChoice::Auto,
                    ))
                    .await
                {
                    Err(error) => error,
                    Ok(mut stream) => stream
                        .next()
                        .await
                        .expect("error stream item")
                        .expect_err("status should fail"),
                }
            });
            match expected {
                None => assert!(matches!(error, AiError::Unauthorized), "{status}"),
                Some(message) => assert!(
                    matches!(error, AiError::ProviderError(actual) if actual == message),
                    "{status}"
                ),
            }
        }
    }

    #[test]
    fn sse_usage_with_total_below_prompt_saturates_end_to_end() {
        let body = successful_sse("ok", 120, 100, 0);
        let (base, _request_rx) = spawn_stub(http_response("200 OK", "text/event-stream", &body));
        let events = runtime().block_on(async {
            let backend = OpenAiBackend::new(None, &base, "model").expect("local backend");
            backend
                .stream_turn(turn_request(
                    vec![user_message("hello")],
                    Vec::new(),
                    ToolChoice::Auto,
                ))
                .await
                .expect("start SSE stream")
                .collect::<Vec<_>>()
                .await
        });
        let usage = events
            .iter()
            .find_map(|event| match event {
                Ok(CompletionEvent::Finished {
                    usage: Some(usage), ..
                }) => Some(usage),
                _ => None,
            })
            .expect("finished usage");
        assert_eq!(usage.input_tokens, 120);
        assert_eq!(usage.output_tokens, 0);
        assert_eq!(usage.total_tokens, 100);
    }

    #[test]
    fn request_body_omits_tool_choice_without_tools() {
        for (tools, choice, expected_choice) in [
            (Vec::new(), ToolChoice::Required, None),
            (
                vec![tool_descriptor()],
                ToolChoice::Required,
                Some("required"),
            ),
            (vec![tool_descriptor()], ToolChoice::Auto, Some("auto")),
        ] {
            let body = successful_sse("ok", 1, 2, 0);
            let (base, request_rx) =
                spawn_stub(http_response("200 OK", "text/event-stream", &body));
            runtime().block_on(async {
                let backend = OpenAiBackend::new(None, &base, "model").expect("local backend");
                let mut stream = backend
                    .stream_turn(turn_request(vec![user_message("hello")], tools, choice))
                    .await
                    .expect("start stream");
                while stream.next().await.is_some() {}
            });
            let request = request_rx
                .recv_timeout(Duration::from_secs(5))
                .expect("record completion request");
            assert_eq!(request.request_line, "POST /v1/chat/completions HTTP/1.1");
            let body: Value = serde_json::from_slice(&request.body).expect("request JSON");
            assert_eq!(
                body.get("tool_choice").and_then(Value::as_str),
                expected_choice
            );
            if expected_choice.is_none() {
                assert_eq!(body.get("tools"), None);
                assert_eq!(
                    body,
                    json!({
                        "model": "model",
                        "messages": [{ "role": "user", "content": "hello" }],
                        "stream": true,
                        "stream_options": { "include_usage": true }
                    })
                );
            } else {
                assert_eq!(
                    body["tools"],
                    json!([{
                        "type": "function",
                        "function": {
                            "name": "list_files",
                            "description": "List files",
                            "parameters": {
                                "type": "object",
                                "properties": { "path": { "type": "string" } }
                            }
                        }
                    }])
                );
            }
        }
    }

    #[derive(Clone, Debug)]
    struct CountedHttpClient {
        inner: reqwest::Client,
        log_path: PathBuf,
        attempt: String,
        test_name: String,
    }

    impl Default for CountedHttpClient {
        fn default() -> Self {
            Self::for_test("unknown")
        }
    }

    impl CountedHttpClient {
        fn for_test(test_name: &str) -> Self {
            let log_path = std::env::var_os("KUKU_LIVE_REQUEST_LOG")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from("/tmp")
                        .join(format!("kuku-live-requests-{}.log", std::process::id()))
                });
            let attempt =
                std::env::var("KUKU_LIVE_ATTEMPT").unwrap_or_else(|_| Uuid::new_v4().to_string());
            Self::with_context(log_path, attempt, test_name.to_string())
        }

        fn with_context(log_path: PathBuf, attempt: String, test_name: String) -> Self {
            let inner = reqwest::Client::builder()
                .retry(reqwest::retry::never())
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .expect("build retry-free counted HTTP client");
            Self {
                inner,
                log_path,
                attempt,
                test_name,
            }
        }

        fn record<T>(&self, request: &http_client::Request<T>) -> http_client::Result<()> {
            let kind = if request.uri().path().ends_with("/chat/completions") {
                "chat"
            } else if request.uri().path().ends_with("/models") {
                "models"
            } else {
                return Err(instance_error(format!(
                    "counted HTTP client rejected unexpected request path {}",
                    request.uri().path()
                )));
            };
            let _guard = request_log_lock().lock().expect("request log lock");
            let contents = match fs::read_to_string(&self.log_path) {
                Ok(contents) => contents,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
                Err(error) => return Err(instance_io_error(error)),
            };
            let (chat, models) = count_requests(&contents, None);
            if (kind == "chat" && chat >= 6) || (kind == "models" && models >= 4) {
                return Err(instance_error(format!(
                    "live request ceiling reached before {kind} send: chat={chat} models={models}"
                )));
            }
            let mut file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.log_path)
                .map_err(instance_io_error)?;
            writeln!(
                file,
                "{} attempt={} {} {}",
                iso_timestamp(),
                self.attempt,
                kind,
                self.test_name
            )
            .map_err(instance_io_error)?;
            file.sync_all().map_err(instance_io_error)
        }

        fn attempt_counts(&self) -> (usize, usize) {
            let contents = fs::read_to_string(&self.log_path).expect("read live request log");
            count_requests(&contents, Some(&self.attempt))
        }
    }

    impl HttpClientExt for CountedHttpClient {
        fn send<T, U>(
            &self,
            request: http_client::Request<T>,
        ) -> impl Future<
            Output = http_client::Result<http_client::Response<http_client::LazyBody<U>>>,
        > + WasmCompatSend
        + 'static
        where
            T: Into<Bytes> + WasmCompatSend,
            U: From<Bytes> + WasmCompatSend + 'static,
        {
            let recorded = self.record(&request);
            let inner = self.inner.clone();
            let (parts, body) = request.into_parts();
            let request = http_client::Request::from_parts(parts, body.into());
            async move {
                recorded?;
                delegate_send(inner, request).await
            }
        }

        fn send_multipart<U>(
            &self,
            request: http_client::Request<MultipartForm>,
        ) -> impl Future<
            Output = http_client::Result<http_client::Response<http_client::LazyBody<U>>>,
        > + WasmCompatSend
        + 'static
        where
            U: From<Bytes> + WasmCompatSend + 'static,
        {
            let recorded = self.record(&request);
            let inner = self.inner.clone();
            async move {
                recorded?;
                delegate_send_multipart(inner, request).await
            }
        }

        fn send_streaming<T>(
            &self,
            request: http_client::Request<T>,
        ) -> impl Future<Output = http_client::Result<http_client::StreamingResponse>> + WasmCompatSend
        where
            T: Into<Bytes>,
        {
            let recorded = self.record(&request);
            let inner = self.inner.clone();
            let (parts, body) = request.into_parts();
            let request = http_client::Request::from_parts(parts, body.into());
            async move {
                recorded?;
                delegate_send_streaming(inner, request).await
            }
        }
    }

    async fn delegate_send<U>(
        client: reqwest::Client,
        request: http_client::Request<Bytes>,
    ) -> http_client::Result<http_client::Response<http_client::LazyBody<U>>>
    where
        U: From<Bytes> + WasmCompatSend + 'static,
    {
        client.send(request).await
    }

    async fn delegate_send_multipart<U>(
        client: reqwest::Client,
        request: http_client::Request<MultipartForm>,
    ) -> http_client::Result<http_client::Response<http_client::LazyBody<U>>>
    where
        U: From<Bytes> + WasmCompatSend + 'static,
    {
        client.send_multipart(request).await
    }

    async fn delegate_send_streaming(
        client: reqwest::Client,
        request: http_client::Request<Bytes>,
    ) -> http_client::Result<http_client::StreamingResponse> {
        client.send_streaming(request).await
    }

    fn request_log_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn instance_error(message: String) -> http_client::Error {
        instance_io_error(std::io::Error::other(message))
    }

    fn instance_io_error(error: std::io::Error) -> http_client::Error {
        http_client::Error::Instance(Box::new(error))
    }

    fn count_requests(contents: &str, attempt: Option<&str>) -> (usize, usize) {
        let mut chat = 0;
        let mut models = 0;
        for line in contents.lines() {
            let fields = line.split_whitespace().collect::<Vec<_>>();
            if fields.len() < 4 || !fields[1].starts_with("attempt=") {
                continue;
            }
            if attempt.is_some_and(|attempt| fields[1] != format!("attempt={attempt}")) {
                continue;
            }
            match fields[2] {
                "chat" => chat += 1,
                "models" => models += 1,
                _ => {}
            }
        }
        (chat, models)
    }

    fn iso_timestamp() -> String {
        let seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time after epoch")
            .as_secs() as i64;
        let days = seconds.div_euclid(86_400);
        let day_seconds = seconds.rem_euclid(86_400);
        let (year, month, day) = civil_from_days(days);
        format!(
            "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
            day_seconds / 3_600,
            day_seconds % 3_600 / 60,
            day_seconds % 60
        )
    }

    fn civil_from_days(days_since_epoch: i64) -> (i64, i64, i64) {
        let z = days_since_epoch + 719_468;
        let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
        let day_of_era = z - era * 146_097;
        let year_of_era =
            (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
        let mut year = year_of_era + era * 400;
        let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
        let month_prime = (5 * day_of_year + 2) / 153;
        let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
        let month = month_prime + if month_prime < 10 { 3 } else { -9 };
        year += i64::from(month <= 2);
        (year, month, day)
    }

    #[test]
    fn counted_http_client_logs_before_send_and_refuses_on_log_failure() {
        let temp = std::env::temp_dir().join(format!("kuku-counted-http-{}", Uuid::new_v4()));
        fs::create_dir_all(&temp).expect("create counted client temp dir");

        let failed_log = temp.join("transport.log");
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind unused port");
        let address = listener.local_addr().expect("unused address");
        drop(listener);
        let client = CountedHttpClient::with_context(
            failed_log.clone(),
            "transport".to_string(),
            "transport_failure".to_string(),
        );
        let request = http_client::Request::get(format!("http://{address}/v1/models"))
            .body(NoBody)
            .expect("build transport request");
        let result: http_client::Result<http_client::Response<http_client::LazyBody<Vec<u8>>>> =
            runtime().block_on(client.send(request));
        assert!(result.is_err());
        assert_eq!(
            count_requests(&fs::read_to_string(&failed_log).unwrap(), None),
            (0, 1)
        );

        let unwritable_log = temp.join("unwritable");
        fs::create_dir(&unwritable_log).expect("create directory at log path");
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind no-send listener");
        listener
            .set_nonblocking(true)
            .expect("make no-send listener nonblocking");
        let address = listener.local_addr().expect("no-send address");
        let client = CountedHttpClient::with_context(
            unwritable_log,
            "unwritable".to_string(),
            "unwritable_log".to_string(),
        );
        let request = http_client::Request::get(format!("http://{address}/v1/models"))
            .body(NoBody)
            .expect("build no-send request");
        let result: http_client::Result<http_client::Response<http_client::LazyBody<Vec<u8>>>> =
            runtime().block_on(client.send(request));
        assert!(result.is_err());
        thread::sleep(Duration::from_millis(50));
        assert!(matches!(
            listener.accept(),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock
        ));

        let redirect_log = temp.join("redirect.log");
        let (base, _request_rx) = spawn_stub(http_response(
            "302 Found",
            "text/plain",
            "redirect disabled",
        ));
        let client = CountedHttpClient::with_context(
            redirect_log.clone(),
            "redirect".to_string(),
            "redirect".to_string(),
        );
        let request = http_client::Request::get(format!("{base}/v1/models"))
            .body(NoBody)
            .expect("build redirect request");
        let result: http_client::Result<http_client::Response<http_client::LazyBody<Vec<u8>>>> =
            runtime().block_on(client.send(request));
        assert!(result.is_err());
        assert_eq!(
            count_requests(&fs::read_to_string(&redirect_log).unwrap(), None),
            (0, 1)
        );

        let ceiling_log = temp.join("ceiling.log");
        let mut ceiling_contents = String::new();
        for index in 0..6 {
            ceiling_contents.push_str(&format!(
                "2026-09-11T00:00:00Z attempt=prior chat prior-{index}\n"
            ));
        }
        for index in 0..4 {
            ceiling_contents.push_str(&format!(
                "2026-09-11T00:00:00Z attempt=prior models prior-{index}\n"
            ));
        }
        fs::write(&ceiling_log, ceiling_contents).expect("seed ceiling log");
        let client = CountedHttpClient::with_context(
            ceiling_log.clone(),
            "ceiling".to_string(),
            "ceiling".to_string(),
        );
        let model_request = http_client::Request::get("http://127.0.0.1:1/v1/models")
            .body(NoBody)
            .expect("build model ceiling request");
        let model_result: http_client::Result<
            http_client::Response<http_client::LazyBody<Vec<u8>>>,
        > = runtime().block_on(client.send(model_request));
        assert!(matches!(
            model_result,
            Err(http_client::Error::Instance(error))
                if error.to_string() == "live request ceiling reached before models send: chat=6 models=4"
        ));
        let chat_request = http_client::Request::post("http://127.0.0.1:1/v1/chat/completions")
            .body(Vec::<u8>::new())
            .expect("build chat ceiling request");
        let chat_result = runtime().block_on(client.send_streaming(chat_request));
        assert!(matches!(
            chat_result,
            Err(http_client::Error::Instance(error))
                if error.to_string() == "live request ceiling reached before chat send: chat=6 models=4"
        ));
        assert_eq!(
            count_requests(&fs::read_to_string(&ceiling_log).unwrap(), None),
            (6, 4)
        );

        let dropped_stream_log = temp.join("dropped-stream.log");
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind dropped-stream listener");
        let address = listener.local_addr().expect("dropped-stream address");
        let (request_sender, request_receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept dropped-stream request");
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .expect("set dropped-stream read timeout");
            request_sender
                .send(read_request(&mut stream))
                .expect("record dropped-stream request");
            let prefix = b"data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                prefix.len() + 128
            )
            .expect("write dropped-stream headers");
            stream
                .write_all(prefix)
                .expect("write dropped-stream prefix");
            stream.flush().expect("flush dropped-stream prefix");
        });
        let client = CountedHttpClient::with_context(
            dropped_stream_log.clone(),
            "dropped-stream".to_string(),
            "dropped_stream".to_string(),
        );
        let events = runtime().block_on(async {
            let backend = OpenAiBackend::with_http_client(
                None,
                &format!("http://{address}"),
                "model",
                client,
            )
            .expect("build dropped-stream backend");
            backend
                .stream_turn(turn_request(
                    vec![user_message("hello")],
                    Vec::new(),
                    ToolChoice::Auto,
                ))
                .await
                .expect("start dropped SSE stream")
                .collect::<Vec<_>>()
                .await
        });
        let request = request_receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("record dropped-stream request");
        assert_eq!(request.request_line, "POST /v1/chat/completions HTTP/1.1");
        assert_eq!(
            events.iter().filter(|event| event.is_err()).count(),
            1,
            "the backend must surface the dropped body as one terminal stream error"
        );
        assert!(matches!(
            events.iter().find(|event| event.is_err()),
            Some(Err(AiError::ProviderError(_)))
        ));
        assert_eq!(
            count_requests(
                &fs::read_to_string(&dropped_stream_log).expect("read dropped-stream log"),
                None
            ),
            (1, 0),
            "the concrete OpenAI adapter must not make a second send_streaming call"
        );
    }

    fn live_settings() -> Option<(String, Option<String>, String)> {
        let Ok(base_url) = std::env::var("KUKU_TEST_OPENAI_BASE_URL") else {
            println!("skipped: KUKU_TEST_OPENAI_BASE_URL unset");
            return None;
        };
        let api_key = normalize_api_key(std::env::var("KUKU_TEST_OPENAI_API_KEY").ok().as_deref());
        let model =
            std::env::var("KUKU_TEST_OPENAI_MODEL").unwrap_or_else(|_| "qwen3.5:4b".to_string());
        Some((base_url, api_key, model))
    }

    fn print_live_counts(client: &CountedHttpClient, name: &str, chat: usize, models: usize) {
        let observed = client.attempt_counts();
        assert_eq!(observed, (chat, models));
        println!(
            "LIVE_REQUESTS attempt={} test={} chat={} models={}",
            client.attempt, name, observed.0, observed.1
        );
    }

    #[test]
    fn live_streams_text_with_usage_identities() {
        let Some((base_url, api_key, model)) = live_settings() else {
            return;
        };
        let client = CountedHttpClient::for_test(LIVE_STREAMS);
        let events = runtime().block_on(async {
            let backend = OpenAiBackend::with_http_client(
                api_key.as_deref(),
                &base_url,
                &model,
                client.clone(),
            )
            .expect("build live backend");
            backend
                .stream_turn(turn_request(
                    vec![user_message("Reply with exactly: pong")],
                    Vec::new(),
                    ToolChoice::Auto,
                ))
                .await
                .expect("start live stream")
                .collect::<Vec<_>>()
                .await
        });
        let mut text = String::new();
        let mut finished = Vec::new();
        for event in events {
            match event.expect("live stream event") {
                CompletionEvent::TextDelta(delta) => text.push_str(&delta),
                CompletionEvent::Finished {
                    finish_reason,
                    usage,
                } => finished.push((finish_reason, usage)),
                CompletionEvent::ToolCalls(_) => {}
            }
        }
        assert_eq!(finished.len(), 1);
        assert_eq!(finished[0].0, FinishReason::Stop);
        assert_eq!(text.trim().trim_end_matches('.'), "pong");
        let usage = finished[0].1.as_ref().expect("live usage");
        assert_eq!(usage.total_tokens, usage.input_tokens + usage.output_tokens);
        print_live_counts(&client, LIVE_STREAMS, 1, 0);
    }

    #[test]
    fn live_two_round_tool_call_replays_ids() {
        let Some((base_url, api_key, model)) = live_settings() else {
            return;
        };
        let client = CountedHttpClient::for_test(LIVE_TOOLS);
        let (first_events, second_events) = runtime().block_on(async {
            let backend = OpenAiBackend::with_http_client(
                api_key.as_deref(),
                &base_url,
                &model,
                client.clone(),
            )
            .expect("build live backend");
            let first_messages = vec![user_message(
                "Call list_files once. Do not answer without calling the tool.",
            )];
            let first_events = backend
                .stream_turn(turn_request(
                    first_messages.clone(),
                    vec![tool_descriptor()],
                    ToolChoice::Required,
                ))
                .await
                .expect("start first live round")
                .collect::<Vec<_>>()
                .await;
            let tool_call_events = first_events
                .iter()
                .filter_map(|event| match event {
                    Ok(CompletionEvent::ToolCalls(calls)) => Some(calls),
                    _ => None,
                })
                .collect::<Vec<_>>();
            assert_eq!(tool_call_events.len(), 1);
            let calls = tool_call_events[0].clone();
            assert_eq!(calls.len(), 1);
            assert_eq!(calls[0].tool_name, "list_files");
            assert!(calls[0].tool_call_id.is_some());
            let mut messages = first_messages;
            messages.push(ChatMessage::Assistant {
                content: String::new(),
                tool_calls: calls.clone(),
            });
            messages.push(ChatMessage::ToolResult {
                call_id: calls[0].call_id.clone(),
                tool_name: calls[0].tool_name.clone(),
                output: r#"{"files":["alpha.md"]}"#.to_string(),
                is_error: false,
                tool_call_id: calls[0].tool_call_id.clone(),
                provider_call_id: calls[0].provider_call_id.clone(),
            });
            messages.push(user_message(
                "Reply with exactly the file name from the tool result",
            ));
            let second_events = backend
                .stream_turn(turn_request(messages, Vec::new(), ToolChoice::Auto))
                .await
                .expect("start second live round")
                .collect::<Vec<_>>()
                .await;
            (first_events, second_events)
        });
        assert_eq!(
            first_events
                .iter()
                .filter(|event| matches!(
                    event,
                    Ok(CompletionEvent::Finished {
                        finish_reason: FinishReason::ToolCalls,
                        ..
                    })
                ))
                .count(),
            1
        );
        let mut text = String::new();
        let mut finishes = 0;
        for event in second_events {
            match event.expect("second live event") {
                CompletionEvent::TextDelta(delta) => text.push_str(&delta),
                CompletionEvent::Finished {
                    finish_reason: FinishReason::Stop,
                    ..
                } => finishes += 1,
                CompletionEvent::Finished { finish_reason, .. } => {
                    panic!("unexpected finish reason {finish_reason:?}")
                }
                CompletionEvent::ToolCalls(_) => {}
            }
        }
        assert_eq!(finishes, 1);
        assert!(!text.trim().is_empty());
        if std::env::var("KUKU_TEST_OPENAI_STRICT_TEXT").as_deref() == Ok("1") {
            assert_eq!(text.trim().trim_end_matches('.'), "alpha.md");
        }
        print_live_counts(&client, LIVE_TOOLS, 2, 0);
    }

    #[test]
    fn live_list_models_contains_the_configured_model_once() {
        let Some((base_url, api_key, model)) = live_settings() else {
            return;
        };
        let client = CountedHttpClient::for_test(LIVE_MODELS);
        let endpoint = parse_endpoint(&base_url, api_key.is_some()).expect("parse live endpoint");
        let models = runtime()
            .block_on(list_models_at(&client, &endpoint, api_key.as_deref()))
            .expect("list live models");
        assert_eq!(
            models
                .iter()
                .filter(|candidate| *candidate == &model)
                .count(),
            1
        );
        print_live_counts(&client, LIVE_MODELS, 0, 1);
    }
}
