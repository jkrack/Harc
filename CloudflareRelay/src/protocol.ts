import {
  MAX_CONTROL_MESSAGE_BYTES,
  isOpaqueToken,
} from "./security";

export const HEADER_CAPABILITY = "x-harc-relay-capability";
export const HEADER_DEVICE_ROUTE = "x-harc-relay-device-route";
export const HEADER_ROLE = "x-harc-relay-role";
export const HEADER_SESSION_ID = "x-harc-relay-session-id";

export const SESSION_LIFETIME_MS = 24 * 60 * 60 * 1_000;
export const SESSION_IDLE_TIMEOUT_MS = 2 * 60 * 1_000;
export const MAX_DEVICE_CAPABILITY_LIFETIME_MS = 366 * 24 * 60 * 60 * 1_000;
export const MAX_PAIRING_CAPABILITY_LIFETIME_MS = 2 * 60 * 1_000;
export const MAX_ACTIVE_SESSIONS_PER_HOST = 8;
export const MAX_RELAY_ROUTES_PER_HOST = 32;
export const SESSION_ADMISSION_BURST = 3;
export const SESSION_ADMISSION_REFILL_MS = 1_000;

export type RelayRole = "host" | "client";
export type AdmissionKind = "device" | "pairing";

export interface SessionInitialization {
  version: 1;
  rendezvousRouteID: string;
  sessionID: string;
  hostCapabilityHash: string;
  clientCapabilityHash: string;
  createdAt: number;
  expiresAt: number;
}

export interface SocketAttachment {
  version: 1;
  role: RelayRole;
  ready: boolean;
  awaitingAcknowledgement: boolean;
  sessionID: string;
  rendezvousRouteID: string;
  expiresAt: number;
  lastPayloadAt: number;
}

export interface AuthorizeCapabilityCommand {
  type: "authorize";
  routeID: string;
  capabilityHash: string;
  kind: AdmissionKind;
  expiresAt: number;
}

export interface RevokeCapabilityCommand {
  type: "revoke";
  routeID: string;
}

export type HostControlCommand =
  | AuthorizeCapabilityCommand
  | RevokeCapabilityCommand;

export function parseHostControlCommand(
  message: string,
  now: number,
): HostControlCommand | null {
  if (new TextEncoder().encode(message).byteLength > MAX_CONTROL_MESSAGE_BYTES) {
    return null;
  }

  let value: unknown;
  try {
    value = JSON.parse(message);
  } catch {
    return null;
  }

  if (!isRecord(value) || typeof value.type !== "string") {
    return null;
  }

  if (value.type === "revoke") {
    return hasExactKeys(value, ["type", "routeID"]) &&
      isOpaqueToken(value.routeID)
      ? { type: "revoke", routeID: value.routeID }
      : null;
  }

  if (value.type !== "authorize" ||
      !hasExactKeys(value, [
        "type",
        "routeID",
        "capabilityHash",
        "kind",
        "expiresAt",
      ]) ||
      !isOpaqueToken(value.routeID) ||
      !isOpaqueToken(value.capabilityHash) ||
      (value.kind !== "device" && value.kind !== "pairing") ||
      typeof value.expiresAt !== "number" ||
      !Number.isSafeInteger(value.expiresAt)) {
    return null;
  }

  const maximumLifetime = value.kind === "pairing"
    ? MAX_PAIRING_CAPABILITY_LIFETIME_MS
    : MAX_DEVICE_CAPABILITY_LIFETIME_MS;
  if (value.expiresAt <= now || value.expiresAt > now + maximumLifetime) {
    return null;
  }

  return {
    type: "authorize",
    routeID: value.routeID,
    capabilityHash: value.capabilityHash,
    kind: value.kind,
    expiresAt: value.expiresAt,
  };
}

export function isSessionInitialization(
  value: unknown,
  now: number,
): value is SessionInitialization {
  if (!isRecord(value) ||
      !hasExactKeys(value, [
        "version",
        "rendezvousRouteID",
        "sessionID",
        "hostCapabilityHash",
        "clientCapabilityHash",
        "createdAt",
        "expiresAt",
      ]) ||
      value.version !== 1 ||
      !isOpaqueToken(value.rendezvousRouteID) ||
      !isOpaqueToken(value.sessionID) ||
      !isOpaqueToken(value.hostCapabilityHash) ||
      !isOpaqueToken(value.clientCapabilityHash) ||
      typeof value.createdAt !== "number" ||
      typeof value.expiresAt !== "number" ||
      !Number.isSafeInteger(value.createdAt) ||
      !Number.isSafeInteger(value.expiresAt)) {
    return false;
  }

  return value.createdAt <= now &&
    value.expiresAt > now &&
    value.expiresAt <= value.createdAt + SESSION_LIFETIME_MS;
}

export function isSocketAttachment(value: unknown): value is SocketAttachment {
  return isRecord(value) &&
    value.version === 1 &&
    (value.role === "host" || value.role === "client") &&
    typeof value.ready === "boolean" &&
    typeof value.awaitingAcknowledgement === "boolean" &&
    isOpaqueToken(value.sessionID) &&
    isOpaqueToken(value.rendezvousRouteID) &&
    typeof value.expiresAt === "number" &&
    Number.isSafeInteger(value.expiresAt) &&
    typeof value.lastPayloadAt === "number" &&
    Number.isSafeInteger(value.lastPayloadAt);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(
  value: Record<string, unknown>,
  expectedKeys: readonly string[],
): boolean {
  const keys = Object.keys(value).sort();
  const expected = [...expectedKeys].sort();
  return keys.length === expected.length &&
    keys.every((key, index) => key === expected[index]);
}
