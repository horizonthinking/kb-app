import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mockCheck = vi.fn();
const mockDownloadAndInstall = vi.fn();

vi.mock("@tauri-apps/plugin-updater", () => ({ check: mockCheck }));
vi.mock("@tauri-apps/plugin-process", () => ({ relaunch: vi.fn() }));

async function loadUpdater(marker: "off" | "on") {
  vi.stubEnv("VITE_KUKU_UPDATER", marker);
  vi.resetModules();
  return import("../updater");
}

describe("updater action boundary", () => {
  beforeEach(() => {
    mockCheck.mockReset();
    mockDownloadAndInstall.mockReset();
    vi.stubGlobal("window", {});
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  it("keeps disabled builds idle without calling the updater plugin", async () => {
    const updater = await loadUpdater("off");

    await updater.checkForUpdates();
    await updater.downloadAndInstall();

    expect(updater.UPDATER_BUILD_MARKER).toBe("kuku-updater-disabled");
    expect(mockCheck).not.toHaveBeenCalled();
    expect(mockDownloadAndInstall).not.toHaveBeenCalled();
    expect(updater.updaterState.status).toBe("idle");
  });

  it("checks and installs exactly once when enabled", async () => {
    mockCheck.mockResolvedValue({
      version: "0.99.0",
      downloadAndInstall: mockDownloadAndInstall,
    });
    mockDownloadAndInstall.mockResolvedValue(undefined);
    const updater = await loadUpdater("on");

    await updater.checkForUpdates();
    await updater.downloadAndInstall();

    expect(updater.UPDATER_BUILD_MARKER).toBe("kuku-updater-enabled");
    expect(mockCheck).toHaveBeenCalledTimes(1);
    expect(mockDownloadAndInstall).toHaveBeenCalledTimes(1);
    expect(updater.updaterState.status).toBe("ready");
  });
});
