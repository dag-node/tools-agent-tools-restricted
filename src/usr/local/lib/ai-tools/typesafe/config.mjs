// SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
// SPDX-License-Identifier: MIT
// src/config.mts
// Reads the configuration from the KEY=value file `--config` names, and refuses every state in which the key could
// leak or reach another host: a symlink, a file readable or writable by other, a placeholder key, a base URL that
// is not https or whose host the file does not also name in TYPESAFE_ENDPOINT_HOST. Every option the transport
// takes is pinned from this file, so the client does not read an environment variable for one. The file is opened
// for reading only, with O_NOFOLLOW, and every check runs on the open descriptor: the file that is checked is the
// file that is read, so a path swapped between the two is not a way past the checks.
//
// The file carries the values an operator tunes per host as well -- the keep threshold, the uncertain band and the
// per-attempt timeout -- because an operator's file survives an upgrade of the artifact, where the constants in
// core.mts are replaced along with it. A value outside its documented range is refused rather than replaced with
// the default: a threshold that silently reverts changes what is kept, with no line saying so. The default for
// each key is the one defaults.mts exports; this file does not hold a copy.
//
// Every value here is untrusted input that an operator hand-edits, so each one is checked against the form its use
// requires -- a probability, a whole number of milliseconds, a bounded token, a hostname, an https origin -- and a
// refusal names the key, shows the value it read, and states the form expected. The key's own value is the one
// exception: a refusal reports its length and character class, and leaves the text out. A base URL carrying a
// userinfo is shown without it for the same reason.
import { closeSync, constants, fstatSync, openSync, readSync } from "node:fs";
import { DEFAULT_BASE_URL, DEFAULT_ENDPOINT_HOST, DEFAULT_MODEL, DEFAULT_THRESHOLD, DEFAULT_TIMEOUT_MS, DEFAULT_UNCERTAIN_BAND, } from "./defaults.mjs";
import { configurationError } from "./errors.mjs";
/** The largest file read. A configuration past it is refused rather than parsed from a prefix. */
const MAX_CONFIG_BYTES = 64 * 1024;
const KEY_MIN_CHARS = 8;
const KEY_MAX_CHARS = 512;
const MODEL_MAX_CHARS = 128;
const HOSTNAME_MAX_CHARS = 253;
const URL_MAX_CHARS = 512;
const MIN_TIMEOUT_MS = 1_000;
const MAX_TIMEOUT_MS = 120_000;
/** Printable ASCII with no space: what fits in an HTTP header value without escaping. */
const PRINTABLE_TOKEN = /^[\x21-\x7e]+$/;
/** A model id as the vendor spells one: a letter or digit, then letters, digits, dot, underscore or dash. */
const MODEL_TOKEN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
/** One DNS label: letters, digits and dashes, neither leading nor trailing a dash, at most 63 characters. */
const DNS_LABEL = /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;
/**
 * The subset of the project's KEY=value grammar the file needs: a leading byte-order mark dropped, lines trimmed,
 * one matched quote layer (a comment may follow the closing quote), `#` starts a comment at line start or after
 * whitespace, a repeated key takes its last assignment, only UPPERCASE keys count.
 */
export function parseKeyValue(text) {
    const out = new Map();
    for (const raw of text.replace(/^\uFEFF/, "").split(/\r?\n/)) {
        const line = raw.trim();
        if (line === "" || line.startsWith("#"))
            continue;
        const eq = line.indexOf("=");
        if (eq < 0)
            continue;
        const key = line.slice(0, eq).trim();
        let value = line.slice(eq + 1).trim();
        const quote = value[0];
        const quoted = quote === '"' || quote === "'";
        const close = quoted ? value.indexOf(quote, 1) : -1;
        if (quoted && value.length >= 2 && value.endsWith(quote)) {
            value = value.slice(1, -1);
        }
        else if (close > 0 && /^\s#/.test(value.slice(close + 1))) {
            value = value.slice(1, close);
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
/** The value as a message shows it: one line, cut, so a pasted blob does not become the error. */
const shown = (value) => {
    const line = value.replace(/\s+/g, " ").trim();
    return line.length <= 60 ? line : `${line.slice(0, 60)}...`;
};
/** The file's setting for `key`, or undefined where the file leaves it to the default. */
const setting = (kv, key) => {
    const value = kv.get(key);
    return value === undefined || value === "" ? undefined : value;
};
/** Reads `key` as a probability in [0, 1]. */
function readProbability(kv, key, fallback) {
    const raw = setting(kv, key);
    if (raw === undefined)
        return fallback;
    const value = Number(raw);
    if (!Number.isFinite(value) || value < 0 || value > 1) {
        throw configurationError(`${key} '${shown(raw)}' is not a probability -- give a number from 0 to 1, as ${fallback}`, { key });
    }
    return value;
}
/** Reads `TYPESAFE_UNCERTAIN_BAND` as `low,high`, both probabilities, low no greater than high. */
function readUncertainBand(kv, fallback) {
    const key = "TYPESAFE_UNCERTAIN_BAND";
    const raw = setting(kv, key);
    if (raw === undefined)
        return fallback;
    const parts = raw.split(",");
    const low = Number(parts[0]);
    const high = Number(parts[1]);
    const wellFormed = parts.length === 2
        && Number.isFinite(low) && Number.isFinite(high)
        && low >= 0 && high <= 1 && low <= high;
    if (!wellFormed) {
        throw configurationError(`${key} '${shown(raw)}' is not a band -- give two probabilities as 'low,high', as ${fallback[0]},${fallback[1]}`, { key });
    }
    return [low, high];
}
/** Reads `TYPESAFE_TIMEOUT_MS` as a whole number of milliseconds inside the supported range. */
function readTimeoutMs(kv, fallback) {
    const key = "TYPESAFE_TIMEOUT_MS";
    const raw = setting(kv, key);
    if (raw === undefined)
        return fallback;
    const value = Number(raw);
    if (!Number.isInteger(value) || value < MIN_TIMEOUT_MS || value > MAX_TIMEOUT_MS) {
        throw configurationError(`${key} '${shown(raw)}' is not a timeout -- give whole milliseconds from ${MIN_TIMEOUT_MS} to ${MAX_TIMEOUT_MS}, as ${fallback}`, { key });
    }
    return value;
}
/** Reads `key` as a hostname, lowercased so a host spelled in capitals still matches the URL's. */
function readHostname(kv, key, fallback) {
    const raw = setting(kv, key);
    if (raw === undefined)
        return fallback;
    const host = raw.toLowerCase();
    const wellFormed = host.length <= HOSTNAME_MAX_CHARS
        && host !== ""
        && !host.endsWith(".")
        && host.split(".").every((label) => DNS_LABEL.test(label));
    if (!wellFormed) {
        throw configurationError(`${key} '${shown(raw)}' is not a hostname -- give the host alone, as ${fallback}`, { key });
    }
    return host;
}
/** Reads the key. A refusal names its length and character class, not the value, which the caller would read. */
function readApiKey(kv, path) {
    const key = "TYPESAFE_API_KEY";
    const raw = setting(kv, key);
    if (raw === undefined)
        throw configurationError(`${key} is not set in ${path}`, { path });
    if (!PRINTABLE_TOKEN.test(raw)) {
        throw configurationError(`${key} is not a single printable token -- check for a space, a quote, or a line break in the value`, { key });
    }
    if (raw.length < KEY_MIN_CHARS || raw.length > KEY_MAX_CHARS) {
        throw configurationError(`${key} is ${raw.length} characters -- a key is from ${KEY_MIN_CHARS} to ${KEY_MAX_CHARS}`, { key, length: raw.length });
    }
    if (/replace-with|your-key|example/i.test(raw)) {
        throw configurationError(`${key} still holds the template placeholder -- put the key TypeSafe issued in ${path}`, { path });
    }
    return raw;
}
/** Reads the base URL as an https origin whose host the file also names in `TYPESAFE_ENDPOINT_HOST`. */
function readBaseURL(kv, endpointHost) {
    const key = "TYPESAFE_BASE_URL";
    const raw = (setting(kv, key) ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    if (raw.length > URL_MAX_CHARS) {
        throw configurationError(`${key} is ${raw.length} characters -- a URL here is at most ${URL_MAX_CHARS}`, { key });
    }
    let url;
    try {
        url = new URL(raw);
    }
    catch {
        throw configurationError(`${key} '${shown(raw)}' is not a URL -- give an origin, as ${DEFAULT_BASE_URL}`, { key });
    }
    if (url.protocol !== "https:") {
        throw configurationError(`${key} '${shown(raw)}' is ${url.protocol} -- the key is sent over https alone`, { key });
    }
    if (url.username !== "" || url.password !== "") {
        // Shown without the userinfo: a password in the file is a secret even where the file is wrong.
        throw configurationError(`${key} '${shown(`${url.protocol}//***@${url.host}${url.pathname}`)}' carries a credential -- give the origin alone, as ${DEFAULT_BASE_URL}`, { key });
    }
    if (url.pathname !== "/" || url.search !== "" || url.hash !== "") {
        throw configurationError(`${key} '${shown(raw)}' carries a path, query or fragment -- give the origin alone, as ${DEFAULT_BASE_URL}`, { key });
    }
    if (url.hostname !== endpointHost) {
        throw configurationError(`${key} host '${url.hostname}' is not the declared endpoint host '${endpointHost}' -- the key is sent only to a host the file names twice`, { key });
    }
    return url.origin;
}
/**
 * Opens `path` without following a final symlink, checks the open descriptor -- a regular file, no other bits, under
 * the size bound -- and reads it whole. A FIFO does not block the open (O_NONBLOCK) and is refused on the type check.
 */
function readConfigFile(path) {
    // O_NOFOLLOW is absent on Windows, where every symlink check is the platform's own.
    const flags = constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0);
    let fd;
    try {
        fd = openSync(path, flags);
    }
    catch (err) {
        const code = err instanceof Error && "code" in err ? String(err.code) : "unknown";
        if (code === "ELOOP")
            throw configurationError(`configuration file ${path} is a symlink`, { path });
        throw configurationError(`configuration file ${path} is not readable (${code})`, { path });
    }
    try {
        const st = fstatSync(fd);
        const mode = st.mode & 0o777;
        if (st.isSymbolicLink())
            throw configurationError(`configuration file ${path} is a symlink`, { path });
        if (!st.isFile())
            throw configurationError(`configuration file ${path} is not a regular file`, { path });
        // The other bits alone are refused. A group bit is not read: on a file under a claimed project the group
        // class shows the ACL mask, which the collaborative tree sets to rwx by design, and the group is the account
        // that runs the command, which already reads the key -- a group write there does not widen access.
        if (mode & 0o004)
            throw configurationError(`configuration file ${path} is world-readable -- it holds a credential; chmod o-r`, { path, mode: mode.toString(8) });
        if (mode & 0o002)
            throw configurationError(`configuration file ${path} is world-writable -- chmod o-w`, { path, mode: mode.toString(8) });
        if (st.size > MAX_CONFIG_BYTES) {
            throw configurationError(`configuration file ${path} is ${st.size} bytes -- a configuration is at most ${MAX_CONFIG_BYTES}`, { path, size: st.size });
        }
        // Read through the same descriptor, one byte past the bound: a file that grew since the stat is refused too.
        const buffer = Buffer.alloc(MAX_CONFIG_BYTES + 1);
        let length = 0;
        for (;;) {
            const n = readSync(fd, buffer, length, buffer.length - length, null);
            if (n === 0)
                break;
            length += n;
            if (length > MAX_CONFIG_BYTES) {
                throw configurationError(`configuration file ${path} is over ${MAX_CONFIG_BYTES} bytes -- a configuration is at most ${MAX_CONFIG_BYTES}`, { path });
            }
        }
        return buffer.toString("utf8", 0, length);
    }
    finally {
        closeSync(fd);
    }
}
/** Reads and validates the configuration file at `path`; every refusal is a configuration error naming the cause. */
export function readConfig(path) {
    const kv = parseKeyValue(readConfigFile(path));
    const apiKey = readApiKey(kv, path);
    const endpointHost = readHostname(kv, "TYPESAFE_ENDPOINT_HOST", DEFAULT_ENDPOINT_HOST);
    const baseURL = readBaseURL(kv, endpointHost);
    const model = setting(kv, "TYPESAFE_MODEL") ?? DEFAULT_MODEL;
    if (!MODEL_TOKEN.test(model) || model.length > MODEL_MAX_CHARS) {
        throw configurationError(`TYPESAFE_MODEL '${shown(model)}' is not a model id -- give a versioned name, as ${DEFAULT_MODEL}`, { key: "TYPESAFE_MODEL" });
    }
    return {
        apiKey,
        baseURL,
        endpointHost,
        model,
        threshold: readProbability(kv, "TYPESAFE_THRESHOLD", DEFAULT_THRESHOLD),
        uncertainBand: readUncertainBand(kv, DEFAULT_UNCERTAIN_BAND),
        timeoutMs: readTimeoutMs(kv, DEFAULT_TIMEOUT_MS),
    };
}
