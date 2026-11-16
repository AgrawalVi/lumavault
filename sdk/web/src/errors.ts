import type {
  DataPlaneErrorCode,
  LumaVaultDataPlaneErrorOptions,
} from "./types.js";

/** Structured error thrown by LumaVault HTTP Data Plane operations. */
export class LumaVaultDataPlaneError extends Error {
  readonly code: DataPlaneErrorCode;
  readonly status?: number;

  constructor(
    code: DataPlaneErrorCode,
    message: string,
    options?: LumaVaultDataPlaneErrorOptions,
  ) {
    super(message, options?.cause !== undefined ? { cause: options.cause } : undefined);
    this.name = "LumaVaultDataPlaneError";
    this.code = code;
    if (options?.status !== undefined) {
      this.status = options.status;
    }
  }
}
