// SPDX-License-Identifier: AGPL-3.0-only
// clients/typesafe/src/config.mts
// Reads the operator's TypeSafe configuration from the KEY=value file the session-env fragment names, and refuses
// every state in which the key could leak or reach another host: a symlink, a file readable or writable by other,
// a placeholder key, a base URL that is not https or whose host the file does not also name in
// TYPESAFE_ENDPOINT_HOST. The client is then constructed with every option pinned from this file, so the SDK's
// TYPESAFE_* environment fallbacks are never consulted. The file's reference is ai-tools-typesafe.conf(5).
import { lstatSync, readFileSync } from "node:fs";
import { configurationError } from "./errors.mjs";
export const DEFAULT_BASE_URL = "https://api.typesafe.ai";
export const DEFAULT_ENDPOINT_HOST = "api.typesafe.ai";
/** A versioned model, not the moving alias: the vendor documents that `jev-latest` changes answers on a release. */
export const DEFAULT_MODEL = "jev-1.13.0";
/**
 * The subset of the project's KEY=value grammar the file needs: trimmed, one matched quote layer, `#` starts
 * a comment at line start or after whitespace, a repeated key takes its last assignment, only UPPERCASE keys count.
 */
export function parseKeyValue(text) {
    const out = new Map();
    for (const raw of text.split(/\r?\n/)) {
        const line = raw.trim();
        if (line === "" || line.startsWith("#"))
            continue;
        const eq = line.indexOf("=");
        if (eq < 0)
            continue;
        const key = line.slice(0, eq).trim();
        let value = line.slice(eq + 1).trim();
        if (value.length >= 2 && ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
            value = value.slice(1, -1);
        }
        else {
            const hash = value.search(/\s#/);
            if (hash >= 0)
                value = value.slice(0, hash).trim();
            if (value.startsWith("#"))
                value = "";
        }
        if (/^[A-Z][A-Z0-9_]*$/.test(key))
            out.set(key, value);
    }
    return out;
}
const PRINTABLE_TOKEN = /^[\x21-\x7e]+$/;
/** Reads and validates the configuration file at `path`; every refusal is a configuration error naming the cause. */
export function readConfig(path) {
    let mode;
    try {
        const st = lstatSync(path);
        if (st.isSymbolicLink())
            throw configurationError(`configuration file ${path} is a symlink`, { path });
        if (!st.isFile())
            throw configurationError(`configuration file ${path} is not a regular file`, { path });
        mode = st.mode & 0o777;
    }
    catch (err) {
        if (err instanceof Error && "code" in err) {
            throw configurationError(`configuration file ${path} is not readable (${String(err.code)})`, { path });
        }
        throw err;
    }
    // The other bits alone are refused. A group bit is not read: on a file under a claimed project the group class
    // shows the ACL mask, which the collaborative tree sets to rwx by design, and the group is the sandbox account,
    // which already reads the key -- a group write there does not widen access. The installed file is 0640 root:ai-tools.
    if (mode & 0o004)
        throw configurationError(`configuration file ${path} is world-readable -- it holds a credential; chmod o-r`, { path, mode: mode.toString(8) });
    if (mode & 0o002)
        throw configurationError(`configuration file ${path} is world-writable`, { path, mode: mode.toString(8) });
    const kv = parseKeyValue(readFileSync(path, "utf8"));
    const apiKey = kv.get("TYPESAFE_API_KEY") ?? "";
    if (apiKey === "")
        throw configurationError(`TYPESAFE_API_KEY is not set in ${path}`, { path });
    // A key's format is the vendor's; the only shape checked is that it is one token that fits in a header.
    if (!PRINTABLE_TOKEN.test(apiKey))
        throw configurationError("TYPESAFE_API_KEY is not a single printable token");
    if (/replace-with|your-key|example/i.test(apiKey))
        throw configurationError("TYPESAFE_API_KEY still holds the template placeholder");
    const rawBase = (kv.get("TYPESAFE_BASE_URL") || DEFAULT_BASE_URL).replace(/\/+$/, "");
    let url;
    try {
        url = new URL(rawBase);
    }
    catch {
        throw configurationError(`TYPESAFE_BASE_URL '${rawBase}' is not a URL`);
    }
    if (url.protocol !== "https:")
        throw configurationError(`TYPESAFE_BASE_URL must be https, got ${url.protocol}`);
    if (url.pathname !== "/" || url.search !== "" || url.hash !== "")
        throw configurationError("TYPESAFE_BASE_URL must be an origin with no path");
    const endpointHost = kv.get("TYPESAFE_ENDPOINT_HOST") || DEFAULT_ENDPOINT_HOST;
    if (url.hostname !== endpointHost) {
        throw configurationError(`TYPESAFE_BASE_URL host '${url.hostname}' is not the declared endpoint host '${endpointHost}' -- the key is sent only to a host the file names twice`);
    }
    const model = kv.get("TYPESAFE_MODEL") || DEFAULT_MODEL;
    if (!PRINTABLE_TOKEN.test(model))
        throw configurationError("TYPESAFE_MODEL is not a single printable token");
    return { apiKey, baseURL: url.origin, endpointHost, model };
}
