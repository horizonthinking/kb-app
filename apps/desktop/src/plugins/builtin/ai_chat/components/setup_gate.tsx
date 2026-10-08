import { Show, type JSX } from "solid-js";

import { switchProviderAndSave, chatState } from "../chat_store";
import { panelStateFor, type ChatReadiness } from "../provider_readiness";
import type { AiProvider } from "../types";
import { setupPromptFor } from "./settings_copy";
import { KukuIcon, SettingsIcon } from "~/components/icons";
import { SettingsBanner } from "~/components/settings/settings_blocks";
import { t } from "~/i18n";
import { authState, getAuthService } from "~/plugins/builtin/core_auth/auth_service";
import { openSettings } from "~/stores/files";

interface SetupGateProps {
  provider: AiProvider;
  readiness: ChatReadiness;
  children: JSX.Element;
}

interface AccessPromptProps {
  provider: AiProvider;
  readiness: Exclude<ChatReadiness, "ready">;
  promptKey: NonNullable<ReturnType<typeof panelStateFor>["promptKey"]>;
}

function AccessPrompt(props: AccessPromptProps): JSX.Element {
  const signInWithKuku = async () => {
    if (chatState.config.saving || authState.loading) return;

    await switchProviderAndSave("remote");

    openSettings({
      kind: "plugin",
      fillId: "core-auth.settings",
      anchor: "session",
    });

    if (!authState.authenticated) {
      await getAuthService()?.login();
    }
  };

  return (
    <div
      class="flex flex-1 flex-col items-center justify-center px-5 py-10"
      data-setup-prompt={props.promptKey}
    >
      <div class="w-full max-w-sm rounded-lg border border-border/70 bg-bg-secondary/80 p-8 text-center">
        <div class="mb-1 inline-flex size-10 items-center justify-center rounded-lg border border-border/60 bg-bg-elevated text-text-secondary">
          <Show when={props.provider === "remote"} fallback={<SettingsIcon size={22} />}>
            <KukuIcon size={22} />
          </Show>
        </div>
        <div class="mt-4 space-y-1.5">
          <h2 class="text-lg font-semibold tracking-tight text-text-primary">
            {t("chat.panel.setup.title")}
          </h2>
          <p class="mx-auto max-w-56 text-[0.8125rem] leading-relaxed text-text-secondary">
            {t(props.promptKey)}
          </p>
        </div>

        <Show when={props.provider === "openai" && props.readiness === "missing_key"}>
          <SettingsBanner
            tone="warning"
            class="mt-4 text-left"
            title={t("settings.plugin.ai_chat.openai_banner.key_title")}
            description={t("settings.plugin.ai_chat.openai_banner.key_description")}
          />
        </Show>
        <Show when={props.provider === "openai" && props.readiness === "missing_model"}>
          <SettingsBanner
            tone="warning"
            class="mt-4 text-left"
            title={t("settings.plugin.ai_chat.openai_banner.model_title")}
            description={t("settings.plugin.ai_chat.openai_banner.model_description")}
          />
        </Show>

        <div class="mt-6 flex flex-col items-stretch gap-2.5">
          <Show when={props.provider === "remote" && props.readiness === "needs_login"}>
            <button
              type="button"
              class="inline-flex min-h-10 items-center justify-center gap-2 rounded-lg border border-accent/35 bg-accent/12 px-4 text-sm font-medium text-accent transition hover:bg-accent/20 active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-50"
              disabled={chatState.config.saving || authState.loading}
              onClick={() => void signInWithKuku()}
            >
              <KukuIcon size={14} />
              {authState.loading ? t("chat.panel.setup.opening") : t("chat.panel.setup.sign_in")}
            </button>
          </Show>

          <button
            type="button"
            class="inline-flex min-h-10 items-center justify-center gap-2 rounded-lg border border-border/80 bg-bg-elevated px-4 text-sm font-medium text-text-primary transition hover:bg-ghost-hover active:scale-[0.99]"
            onClick={() =>
              openSettings({
                kind: "plugin",
                fillId:
                  props.readiness === "needs_login" || props.readiness === "needs_permission"
                    ? "core-auth.settings"
                    : "ai-chat.settings",
                anchor: props.readiness === "needs_permission" ? "authorizations" : "api-key",
              })
            }
          >
            <SettingsIcon size={14} />
            {t("chat.panel.setup.open_settings")}
          </button>
        </div>

        <Show when={authState.error}>
          {(error) => <p class="mt-4 text-[0.7rem] text-error">{error()}</p>}
        </Show>
        <Show when={chatState.config.error}>
          {(error) => <p class="mt-2 text-[0.7rem] text-error">{error()}</p>}
        </Show>
      </div>
    </div>
  );
}

function SetupGate(props: SetupGateProps): JSX.Element {
  const panelState = () => panelStateFor(props.provider, props.readiness);
  return (
    <Show
      when={panelState().inputEnabled}
      fallback={
        <AccessPrompt
          provider={props.provider}
          readiness={props.readiness as Exclude<ChatReadiness, "ready">}
          promptKey={panelState().promptKey ?? setupPromptFor(props.provider)}
        />
      }
    >
      {props.children}
    </Show>
  );
}

export { AccessPrompt, SetupGate };
