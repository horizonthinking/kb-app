/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_KUKU_API_URL?: string;
  readonly VITE_KUKU_WEB_URL?: string;
  readonly VITE_KUKU_UPDATER?: string;
  readonly VITE_KUKU_BUILD_LABEL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

// eslint-disable-next-line no-underscore-dangle -- R9's Vite-injected build constant.
declare const __KUKU_UPDATER__: boolean;

declare module "*.glb" {
  const src: string;
  export default src;
}
