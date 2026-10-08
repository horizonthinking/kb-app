use std::{collections::HashMap, sync::Arc};

use parking_lot::RwLock;

use crate::{
    AiConfig, AiError, AiHostBindings, AiNativeTool,
    provider::{
        CompletionBackend,
        gemini::GeminiBackend,
        openai::{KeyRequirement, OpenAiBackend, normalize_api_key, parse_endpoint},
        remote::RemoteBackend,
    },
    session::SessionRuntime,
    tools::{ProxyBroker, ProxyToolDescriptor, ToolDescriptor, ToolRegistry},
    types::{ChatMode, ProviderKind},
};

struct AiStateInner {
    config: RwLock<AiConfig>,
    provider: RwLock<Option<Arc<dyn CompletionBackend>>>,
    sessions: RwLock<HashMap<String, Arc<SessionRuntime>>>,
    tools: ToolRegistry,
    proxy_broker: ProxyBroker,
    host: RwLock<Option<Arc<dyn AiHostBindings>>>,
}

#[derive(Clone)]
pub struct AiState {
    inner: Arc<AiStateInner>,
}

impl Default for AiState {
    fn default() -> Self {
        let config = AiConfig::default();
        Self {
            inner: Arc::new(AiStateInner {
                config: RwLock::new(config),
                provider: RwLock::new(None),
                sessions: RwLock::new(HashMap::new()),
                tools: ToolRegistry::default(),
                proxy_broker: ProxyBroker::default(),
                host: RwLock::new(None),
            }),
        }
    }
}

impl AiState {
    pub fn config(&self) -> AiConfig {
        self.inner.config.read().clone()
    }

    pub fn set_config(&self, mut config: AiConfig) -> Result<(), AiError> {
        config.api_key = normalize_api_key(config.api_key.as_deref());
        config.openai_api_key = normalize_api_key(config.openai_api_key.as_deref());
        let backend = build_backend(&config)?;
        *self.inner.config.write() = config;
        *self.inner.provider.write() = backend;
        Ok(())
    }

    pub fn reset_state(&self) -> Result<(), AiError> {
        for (_, session) in self.inner.sessions.write().drain() {
            session.cancel();
        }

        let config = AiConfig::default();
        *self.inner.config.write() = config;
        *self.inner.provider.write() = None;
        Ok(())
    }

    pub fn backend(&self) -> Result<Arc<dyn CompletionBackend>, AiError> {
        if let Some(provider) = self.inner.provider.read().clone() {
            return Ok(provider);
        }

        let config = self.config();
        let provider = build_backend(&config)?.ok_or(AiError::NotConfigured)?;
        *self.inner.provider.write() = Some(provider.clone());
        Ok(provider)
    }

    pub fn create_session(&self, mode: ChatMode) -> Arc<SessionRuntime> {
        let session = Arc::new(SessionRuntime::new(mode));
        self.inner
            .sessions
            .write()
            .insert(session.id.clone(), session.clone());
        session
    }

    pub fn get_session(&self, session_id: &str) -> Result<Arc<SessionRuntime>, AiError> {
        self.inner
            .sessions
            .read()
            .get(session_id)
            .cloned()
            .ok_or(AiError::SessionNotFound)
    }

    pub fn register_tool(&self, tool: Arc<dyn AiNativeTool>) {
        self.inner.tools.register_native(tool);
    }

    pub fn register_proxy_tool(&self, descriptor: ProxyToolDescriptor) {
        self.inner.tools.register_proxy(descriptor);
    }

    pub fn remember_path_snapshot(
        &self,
        session_id: &str,
        path: String,
        checksum: String,
        is_dir: bool,
    ) -> Result<(), AiError> {
        let session = self.get_session(session_id)?;
        session.remember_path_snapshot(path, checksum, is_dir);
        Ok(())
    }

    pub fn path_snapshot(
        &self,
        session_id: &str,
        path: &str,
    ) -> Result<Option<(String, bool)>, AiError> {
        let session = self.get_session(session_id)?;
        Ok(session.path_snapshot(path))
    }

    pub fn unregister_proxy_tool(&self, name: &str) {
        self.inner.tools.unregister_proxy(name);
    }

    pub fn tool_descriptors(&self) -> Vec<ToolDescriptor> {
        self.inner.tools.descriptors()
    }

    pub fn tools(&self) -> &ToolRegistry {
        &self.inner.tools
    }

    pub fn proxy_broker(&self) -> &ProxyBroker {
        &self.inner.proxy_broker
    }

    pub fn set_host(&self, host: Arc<dyn AiHostBindings>) {
        *self.inner.host.write() = Some(host);
    }

    pub fn host(&self) -> Option<Arc<dyn AiHostBindings>> {
        self.inner.host.read().clone()
    }

    #[cfg(test)]
    pub(crate) fn set_backend_for_test(&self, backend: Arc<dyn CompletionBackend>) {
        *self.inner.provider.write() = Some(backend);
    }
}
fn build_backend(config: &AiConfig) -> Result<Option<Arc<dyn CompletionBackend>>, AiError> {
    match config.provider {
        ProviderKind::Gemini => {
            let Some(api_key) = config.api_key.as_deref() else {
                return Ok(None);
            };
            Ok(Some(
                Arc::new(GeminiBackend::new(api_key, &config.model)?) as Arc<dyn CompletionBackend>
            ))
        }
        ProviderKind::Remote => {
            let base_url = config
                .server_url
                .as_deref()
                .unwrap_or(if cfg!(debug_assertions) {
                    "http://localhost:8080"
                } else {
                    "https://api.kuku.mom"
                });
            Ok(Some(Arc::new(RemoteBackend::new(base_url, &config.model)?)
                as Arc<dyn CompletionBackend>))
        }
        ProviderKind::OpenAi => {
            let model = config.model.trim();
            if model.is_empty() {
                return Ok(None);
            }
            let base_url = config
                .openai_base_url
                .as_deref()
                .unwrap_or("https://api.openai.com/v1");
            let key = normalize_api_key(config.openai_api_key.as_deref());
            let endpoint = parse_endpoint(base_url, key.is_some())?;
            if endpoint.requirement == KeyRequirement::Required && key.is_none() {
                return Ok(None);
            }
            Ok(Some(
                Arc::new(OpenAiBackend::new(key.as_deref(), base_url, model)?)
                    as Arc<dyn CompletionBackend>,
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };

    use super::{AiState, build_backend};
    use crate::{AiConfig, AiError, provider::openai, types::ProviderKind};

    fn openai_config(base_url: &str, key: Option<&str>, model: &str) -> AiConfig {
        AiConfig {
            provider: ProviderKind::OpenAi,
            api_key: None,
            openai_api_key: key.map(str::to_string),
            openai_base_url: Some(base_url.to_string()),
            openai_model: if model.is_empty() {
                None
            } else {
                Some(model.to_string())
            },
            model: model.to_string(),
            server_url: None,
            round_limit: 12,
            proxy_tool_timeout_ms: 15_000,
        }
    }

    fn model_stub() -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind model stub");
        let address = listener.local_addr().expect("model stub address");
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept model request");
            let mut request = [0_u8; 4096];
            let read = stream.read(&mut request).expect("read model request");
            assert_eq!(
                String::from_utf8_lossy(&request[..read])
                    .lines()
                    .next()
                    .expect("request line"),
                "GET /v1/models HTTP/1.1"
            );
            let body = r#"{"data":[{"id":"model-a"}]}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write models");
        });
        (format!("http://{address}"), handle)
    }

    #[test]
    fn build_backend_openai_requires_model_and_key_policy() {
        assert!(
            build_backend(&openai_config("https://api.openai.com/v1", Some("key"), ""))
                .expect("empty model config")
                .is_none()
        );
        assert!(
            build_backend(&openai_config("https://api.openai.com/v1", None, "model"))
                .expect("required host without key")
                .is_none()
        );
        assert!(
            build_backend(&openai_config("http://127.0.0.1:11434/v1", None, "model"))
                .expect("optional host without key")
                .is_some()
        );
    }

    #[test]
    fn set_config_stores_incomplete_openai_config_without_backend() {
        let (base_url, stub) = model_stub();
        let state = AiState::default();
        state
            .set_config(openai_config(&base_url, Some("   "), ""))
            .expect("store incomplete local config");
        let stored = state.config();
        assert_eq!(stored.openai_base_url.as_deref(), Some(base_url.as_str()));
        assert_eq!(stored.openai_api_key, None);
        assert_eq!(stored.model, "");
        assert!(matches!(state.backend(), Err(AiError::NotConfigured)));
        let models = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(openai::list_models(
                stored.openai_base_url.as_deref().expect("stored base URL"),
                stored.openai_api_key.as_deref(),
            ))
            .expect("discover before model selection");
        assert_eq!(models, vec!["model-a".to_string()]);
        stub.join().expect("model stub thread");

        state
            .set_config(openai_config(&base_url, None, "model-a"))
            .expect("complete local config");
        assert!(state.backend().is_ok());

        let keyed = AiState::default();
        let mut keyed_config = openai_config("https://api.openai.com/v1", Some("  sk-test  "), "");
        keyed_config.api_key = Some("  gemini-test  ".to_string());
        keyed
            .set_config(keyed_config)
            .expect("store incomplete keyed config without network");
        assert_eq!(keyed.config().openai_api_key, Some("sk-test".to_string()));
        assert_eq!(keyed.config().api_key, Some("gemini-test".to_string()));
        assert!(matches!(keyed.backend(), Err(AiError::NotConfigured)));

        let optional = AiState::default();
        let mut optional_config =
            openai_config("http://127.0.0.1:11434/v1", Some("   "), "model-a");
        optional_config.api_key = Some("   ".to_string());
        optional
            .set_config(optional_config)
            .expect("normalize whitespace key on optional host");
        assert_eq!(optional.config().openai_api_key, None);
        assert_eq!(optional.config().api_key, None);
        assert!(optional.backend().is_ok());
    }
}
