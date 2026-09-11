import { createEffect, on, onCleanup, onMount, Show, type JSX } from "solid-js";

import { chatState, loadConfig } from "./chat_store";
import { normalizeAiConfig } from "./config";
import { chatReadiness } from "./provider_readiness";
import { ChatHeader } from "./components/chat_header";
import { ChatInput } from "./components/chat_input";
import { ChatMessages } from "./components/chat_messages";
import { SetupGate } from "./components/setup_gate";
import ScrollArea, { type ScrollAreaHandle } from "~/components/scroll_area";
import { vaultDragState } from "~/stores/vault_drag";
import { authState, getAuthService } from "~/plugins/builtin/core_auth/auth_service";

// ── Main Chat Panel ──

function ChatPanel(): JSX.Element {
  let scrollHandle: ScrollAreaHandle | undefined;
  let pendingAutoscroll = false;
  let pendingScrollFrame = 0;
  let userScrolledAway = false;
  /** After programmatic scroll, ignore a few onScrolls so "follow" is not lost. */
  let ignoreScrollEvents = 0;

  // Reload config when panel mounts so we pick up changes made in Settings.
  onMount(() => {
    void loadConfig();
  });

  createEffect(() => {
    if (chatState.config.provider === "remote") {
      void getAuthService()?.authorizationHeaders("ai-chat");
    }
  });

  onCleanup(() => {
    if (pendingScrollFrame) {
      cancelAnimationFrame(pendingScrollFrame);
    }
  });

  // ── Scroll: follow the bottom of the transcript (classic chat) unless the user scrolls up ──

  function isNearBottom(): boolean {
    if (!scrollHandle) return true;
    const position = scrollHandle.getScrollPosition();
    const threshold = 80;
    return position.scrollHeight - position.top - position.height < threshold;
  }

  function isAwaitingResponse(): boolean {
    const activeId = chatState.activeSessionId;
    const session = activeId ? (chatState.sessions[activeId] ?? null) : null;
    return session?.status === "streaming" || session?.status === "applying";
  }

  function scrollToBottom(behavior: ScrollBehavior = "smooth"): void {
    if (!scrollHandle) return;
    // Smooth scroll emits many onScrolls; do not let them clear "follow" mid-animation.
    ignoreScrollEvents = 20;
    scrollHandle.update();
    const position = scrollHandle.getScrollPosition();
    scrollHandle.scrollTo({
      top: position.scrollHeight,
      behavior,
    });
    userScrolledAway = false;
  }

  /** Nudge the scroll target so the latest user line sits under the header with air (OS viewport). */
  function revealLatestUserToView(): void {
    if (!scrollHandle) return;
    const el = document.querySelector<HTMLElement>("[data-kuku-latest-user]");
    if (el) {
      ignoreScrollEvents = 20;
      scrollHandle.update();
      scrollHandle.alignElementToBlockStart(el, { paddingTop: 40, behavior: "smooth" });
    } else {
      scrollToBottom("smooth");
    }
    userScrolledAway = false;
  }

  function runPendingAutoscroll(): void {
    if (!scrollHandle) return;
    if (userScrolledAway) {
      return;
    }
    const activeId = chatState.activeSessionId;
    const session = activeId ? (chatState.sessions[activeId] ?? null) : null;
    if (!session || session.messages.length === 0) {
      return;
    }
    const last = session.messages[session.messages.length - 1];
    if (last.kind === "text" && last.role === "user" && !isAwaitingResponse()) {
      revealLatestUserToView();
    } else {
      scrollToBottom("smooth");
    }
  }

  function cancelPendingAutoscroll(): void {
    pendingAutoscroll = false;
    if (!pendingScrollFrame) return;
    cancelAnimationFrame(pendingScrollFrame);
    pendingScrollFrame = 0;
  }

  function scheduleAutoscroll(): void {
    if (userScrolledAway) return;
    pendingAutoscroll = true;
    if (pendingScrollFrame) return;

    pendingScrollFrame = requestAnimationFrame(() => {
      scrollHandle?.update();
      pendingScrollFrame = 0;
      if (!pendingAutoscroll) return;
      pendingAutoscroll = false;
      runPendingAutoscroll();
    });
  }

  function handleScroll(): void {
    if (ignoreScrollEvents > 0) {
      ignoreScrollEvents -= 1;
      return;
    }
    userScrolledAway = !isNearBottom();
    if (userScrolledAway) {
      cancelPendingAutoscroll();
    }
  }

  function handleWheel(event: WheelEvent): void {
    if (event.deltaY >= 0 || !scrollHandle) return;
    const position = scrollHandle.getScrollPosition();
    if (position.top <= 0 || position.scrollHeight <= position.height) return;
    ignoreScrollEvents = 0;
    userScrolledAway = true;
    cancelPendingAutoscroll();
    scrollHandle.scrollTo({ top: position.top, behavior: "auto" });
  }

  // Structural + coarser streaming: last message is user → reveal; assistant reply → follow bottom (bucketed).

  createEffect(
    on(
      () => {
        const activeId = chatState.activeSessionId;
        const session = activeId ? (chatState.sessions[activeId] ?? null) : null;
        const count = session?.messages.length ?? 0;
        const last = count > 0 && session ? session.messages[count - 1] : null;
        const status = session?.status ?? "idle";
        let hasFirstToken = false;
        let lastStreaming = false;
        let streamChunk = 0;
        if (last?.kind === "text") {
          hasFirstToken = last.content.length > 0;
          lastStreaming = last.streaming === true;
          if (last.role === "assistant" && lastStreaming) {
            // Coarse buckets so we do not start overlapping smooth scroll animations too often.
            streamChunk = Math.floor(last.content.length / 96);
          }
        }
        return `${activeId ?? ""}|${status}|${count}|${last?.id ?? ""}|${lastStreaming}|${hasFirstToken}|${streamChunk}`;
      },
      () => {
        const activeId = chatState.activeSessionId;
        const session = activeId ? (chatState.sessions[activeId] ?? null) : null;
        const count = session?.messages.length ?? 0;
        if (!activeId || count === 0) return;
        if (userScrolledAway) return;
        scheduleAutoscroll();
      },
    ),
  );

  // Reset scroll position when the active session changes.
  createEffect(
    on(
      () => chatState.activeSessionId,
      () => {
        userScrolledAway = false;
        scheduleAutoscroll();
      },
    ),
  );

  // ── Render ──

  return (
    <div
      class="relative flex h-full min-h-0 flex-col"
      data-kuku-ai-chat
      data-ai-chat-dropzone="true"
    >
      <Show when={vaultDragState.chatDropActive}>
        <div data-kuku-ai-chat-drop />
      </Show>
      <ChatHeader />

      <SetupGate
        provider={chatState.config.provider}
        readiness={chatReadiness(
          normalizeAiConfig(chatState.config.rawConfig),
          authState.authenticated,
          getAuthService()?.isPluginAuthorized("ai-chat") ?? false,
        )}
      >
        <div class="flex min-h-0 flex-1 flex-col">
          <ScrollArea
            axis="y"
            class="min-h-0 flex-1"
            handleRef={(handle) => {
              scrollHandle = handle;
            }}
            onViewportReady={() => {
              scheduleAutoscroll();
            }}
            onLayout={(_, reason) => {
              if (reason === "resize" || (reason === "content" && !isAwaitingResponse())) {
                scheduleAutoscroll();
              }
            }}
            onScroll={() => {
              handleScroll();
            }}
            onWheel={(event) => {
              handleWheel(event);
            }}
          >
            <ChatMessages />
          </ScrollArea>

          <ChatInput />
        </div>
      </SetupGate>
    </div>
  );
}

export default ChatPanel;
