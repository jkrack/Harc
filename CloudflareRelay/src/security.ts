export const OPAQUE_TOKEN_BYTES = 32;
export const OPAQUE_TOKEN_LENGTH = 43;
export const MAX_RELAY_FRAME_BYTES = 1_048_576;
export const MAX_CONTROL_MESSAGE_BYTES = 4_096;

const opaqueTokenPattern = /^[A-Za-z0-9_-]{43}$/;

export function isOpaqueToken(value: unknown): value is string {
  if (typeof value !== "string" || !opaqueTokenPattern.test(value)) {
    return false;
  }
  try {
    const bytes = Uint8Array.from(
      atob(value.replaceAll("-", "+").replaceAll("_", "/") + "="),
      (character) => character.charCodeAt(0),
    );
    return bytes.length === OPAQUE_TOKEN_BYTES &&
      bytesToBase64URL(bytes) === value;
  } catch {
    return false;
  }
}

export function randomOpaqueToken(): string {
  const bytes = new Uint8Array(OPAQUE_TOKEN_BYTES);
  crypto.getRandomValues(bytes);
  return bytesToBase64URL(bytes);
}

export async function hashOpaqueToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  return bytesToBase64URL(new Uint8Array(digest));
}

export async function tokenMatchesHash(
  token: string,
  expectedHash: string,
): Promise<boolean> {
  if (!isOpaqueToken(token) || !isOpaqueToken(expectedHash)) {
    return false;
  }
  return constantTimeEqual(await hashOpaqueToken(token), expectedHash);
}

export function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) {
    return false;
  }
  return crypto.subtle.timingSafeEqual(
    new TextEncoder().encode(left),
    new TextEncoder().encode(right),
  );
}

function bytesToBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}
