/**
 * A failure the host tells apart by its code: BAD_REQUEST (a call the page can't take), RPC_FAILED (a sync that
 * failed while the Ethereum RPC did not answer; rpc-probe.js); anything else reaches it as FAILED.
 */
export class RailgunError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export const badRequest = (message) => new RailgunError('BAD_REQUEST', message);

export const errorCode = (error) => (error instanceof RailgunError ? error.code : 'FAILED');
