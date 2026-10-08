mod commands;
mod contract;
mod error;
mod host;
mod mutation;
mod prompts;
mod provider;
mod session;
mod state;
mod tools;
mod types;

use std::sync::Arc;

pub use error::{AiError, ToolError};
pub use host::AiHostBindings;
pub use mutation::{ConflictItem, MutationApplyResult, MutationOp, MutationPlan};
pub use state::AiState;
use tauri::{
    AppHandle, Manager, Wry,
    plugin::{Builder, TauriPlugin},
};
pub use tools::{
    AiNativeTool, NativeToolResult, ProxyToolDescriptor, ProxyToolResult, ToolAccess,
    ToolCallContext, ToolDescriptor, ToolSource,
};
pub use types::{
    AiConfig, ChatMode, EditorContext, EmbeddedFileContext, FinishReason, ModelToolCall,
    NewSessionPayload, ProviderKind,
};

pub fn init() -> TauriPlugin<Wry> {
    Builder::new("kuku-ai")
        .setup(|app, _api| {
            app.manage(AiState::default());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::ai_new_session,
            commands::ai_send_message,
            commands::ai_cancel,
            commands::ai_get_config,
            commands::ai_set_config,
            commands::ai_reset_state,
            commands::ai_list_tools,
            commands::ai_list_models,
            commands::ai_resolve_approval,
            commands::ai_register_proxy_tool,
            commands::ai_unregister_proxy_tool,
            commands::ai_submit_proxy_tool_result,
        ])
        .build()
}

pub fn register_host(app: &AppHandle<Wry>, host: Arc<dyn AiHostBindings>) {
    let state = app.state::<AiState>();
    state.set_host(host);
}

pub fn register_tool(app: &AppHandle<Wry>, tool: Arc<dyn AiNativeTool>) {
    let state = app.state::<AiState>();
    state.register_tool(tool);
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    fn command_names(source: &str) -> BTreeSet<String> {
        source
            .split('"')
            .filter(|part| part.starts_with("ai_"))
            .map(str::to_string)
            .collect()
    }

    fn handler_names(source: &str) -> BTreeSet<String> {
        source
            .split("commands::")
            .skip(1)
            .map(|part| {
                part.chars()
                    .take_while(|character| character.is_ascii_alphanumeric() || *character == '_')
                    .collect::<String>()
            })
            .filter(|name| name.starts_with("ai_"))
            .collect()
    }

    fn permission_names(source: &str) -> BTreeSet<String> {
        source
            .split('"')
            .filter_map(|part| part.strip_prefix("allow-ai-"))
            .map(|part| format!("ai_{}", part.replace('-', "_")))
            .collect()
    }

    #[test]
    fn commands_permissions_and_handler_are_in_three_way_agreement() {
        let build_commands = command_names(include_str!("../build.rs"));
        let handler_commands = handler_names(include_str!("lib.rs"));
        let permissions = permission_names(include_str!("../permissions/default.toml"));

        assert_eq!(build_commands, handler_commands);
        assert_eq!(handler_commands, permissions);
        assert!(permissions.contains("ai_list_models"));
    }
}
