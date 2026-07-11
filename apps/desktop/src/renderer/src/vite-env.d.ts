/// <reference types="vite/client" />

import type { RockyApi } from "../../shared/types";

declare global {
  interface Window {
    rocky: RockyApi;
  }
}

export {};

