/** A failure the host tells apart by its code; anything else reaches it as FAILED. */
export class RailgunError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export const badRequest = (message) => new RailgunError('BAD_REQUEST', message);

export const errorCode = (error) => (error instanceof RailgunError ? error.code : 'FAILED');
