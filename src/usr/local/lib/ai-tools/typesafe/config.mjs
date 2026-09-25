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
import { isModelName, isProbability } from "./validation.mjs";
/** The largest file read. A configuration past it is refused rather than parsed from a prefix. */
const MAX_CONFIG_BYTES = 64 * 1024;
const KEY_MIN_CHARS = 8;
const KEY_MAX_CHARS = 512;
const HOSTNAME_MAX_CHARS = 253;
const URL_MAX_CHARS = 512;
/** The longest value a refusal quotes before cutting it. */
const DISPLAY_VALUE_MAX_CHARS = 60;
const MIN_TIMEOUT_MS = 1_000;
const MAX_TIMEOUT_MS = 120_000;
/** Printable ASCII with no space: what fits in an HTTP header value without escaping. */
const PRINTABLE_TOKEN = /^[\x21-\x7e]+$/;
/** One DNS label: letters, digits and dashes, neither leading nor trailing a dash, at most 63 characters. */
const DNS_LABEL = /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;
/**
 * The subset of the project's KEY=value grammar the file needs: a leading byte-order mark dropped, lines trimmed,
 * one matched quote layer (a comment may follow the closing quote), `#` starts a comment at line start or after
 * whitespace, a repeated key takes its last assignment, only UPPERCASE keys count.
 */
export function parseKeyValue(text) {
    const settings = new Map();
    for (const rawLine of text.replace(/^\uFEFF/, "").split(/\r?\n/)) {
        const line = rawLine.trim();
        if (line === "" || line.startsWith("#"))
            continue;
        const equalsIndex = line.indexOf("=");
        if (equalsIndex < 0)
            continue;
        const key = line.slice(0, equalsIndex).trim();
        let value = line.slice(equalsIndex + 1).trim();
        const openingQuote = value[0];
        const isQuoted = openingQuote === '"' || openingQuote === "'";
        const closingQuoteIndex = isQuoted ? value.indexOf(openingQuote, 1) : -1;
        if (isQuoted && value.length >= 2 && value.endsWith(openingQuote)) {
            value = value.slice(1, -1);
        }
        else if (closingQuoteIndex > 0 && /^\s#/.test(value.slice(closingQuoteIndex + 1))) {
            value = value.slice(1, closingQuoteIndex);
        }
        else {
            const commentIndex = value.search(/\s#/);
            if (commentIndex >= 0)
                value = value.slice(0, commentIndex).trim();
            if (value.startsWith("#"))
                value = "";
        }
        if (/^[A-Z][A-Z0-9_]*$/.test(key))
            settings.set(key, value);
    }
    return settings;
}
/** The value as a message shows it: one line, cut, so a pasted blob does not become the error. */
const toDisplayValue = (value) => {
    const singleLine = value.replace(/\s+/g, " ").trim();
    return singleLine.length <= DISPLAY_VALUE_MAX_CHARS ? singleLine : `${singleLine.slice(0, DISPLAY_VALUE_MAX_CHARS)}...`;
};
/** The file's setting for `settingName`, or undefined where the file leaves it to the default. */
const readSetting = (settings, settingName) => {
    const value = settings.get(settingName);
    return value === undefined || value === "" ? undefined : value;
};
/** Reads `settingName` as a probability in [0, 1]. */
function readProbability(settings, settingName, defaultValue) {
    const rawValue = readSetting(settings, settingName);
    if (rawValue === undefined)
        return defaultValue;
    const probability = Number(rawValue);
    if (!isProbability(probability)) {
        throw configurationError(`${settingName} '${toDisplayValue(rawValue)}' is not a probability -- give a number from 0 to 1, as ${defaultValue}`, { key: settingName });
    }
    return probability;
}
/** Reads `TYPESAFE_UNCERTAIN_BAND` as `low,high`, both probabilities, low no greater than high. */
function readUncertainBand(settings, defaultValue) {
    const settingName = "TYPESAFE_UNCERTAIN_BAND";
    const rawValue = readSetting(settings, settingName);
    if (rawValue === undefined)
        return defaultValue;
    const parts = rawValue.split(",");
    const low = Number(parts[0]);
    const high = Number(parts[1]);
    const isWellFormed = parts.length === 2 && isProbability(low) && isProbability(high) && low <= high;
    if (!isWellFormed) {
        throw configurationError(`${settingName} '${toDisplayValue(rawValue)}' is not a band -- give two probabilities as 'low,high', as ${defaultValue[0]},${defaultValue[1]}`, { key: settingName });
    }
    return [low, high];
}
/** Reads `TYPESAFE_TIMEOUT_MS` as a whole number of milliseconds inside the supported range. */
function readTimeoutMs(settings, defaultValue) {
    const settingName = "TYPESAFE_TIMEOUT_MS";
    const rawValue = readSetting(settings, settingName);
    if (rawValue === undefined)
        return defaultValue;
    const timeoutMs = Number(rawValue);
    if (!Number.isInteger(timeoutMs) || timeoutMs < MIN_TIMEOUT_MS || timeoutMs > MAX_TIMEOUT_MS) {
        throw configurationError(`${settingName} '${toDisplayValue(rawValue)}' is not a timeout -- give whole milliseconds from ${MIN_TIMEOUT_MS} to ${MAX_TIMEOUT_MS}, as ${defaultValue}`, { key: settingName });
    }
    return timeoutMs;
}
/** Reads `settingName` as a hostname, lowercased so a host spelled in capitals still matches the URL's. */
function readHostname(settings, settingName, defaultValue) {
    const rawValue = readSetting(settings, settingName);
    if (rawValue === undefined)
        return defaultValue;
    const hostname = rawValue.toLowerCase();
    const isWellFormed = hostname.length <= HOSTNAME_MAX_CHARS
        && hostname !== ""
        && !hostname.endsWith(".")
        && hostname.split(".").every((label) => DNS_LABEL.test(label));
    if (!isWellFormed) {
        throw configurationError(`${settingName} '${toDisplayValue(rawValue)}' is not a hostname -- give the host alone, as ${defaultValue}`, { key: settingName });
    }
    return hostname;
}
/** Reads the key. A refusal names its length and character class, not the value, which the caller would read. */
function readApiKey(settings, configPath) {
    const settingName = "TYPESAFE_API_KEY";
    const apiKey = readSetting(settings, settingName);
    if (apiKey === undefined)
        throw configurationError(`${settingName} is not set in ${configPath}`, { path: configPath });
    if (!PRINTABLE_TOKEN.test(apiKey)) {
        throw configurationError(`${settingName} is not a single printable token -- check for a space, a quote, or a line break in the value`, { key: settingName });
    }
    if (apiKey.length < KEY_MIN_CHARS || apiKey.length > KEY_MAX_CHARS) {
        throw configurationError(`${settingName} is ${apiKey.length} characters -- a key is from ${KEY_MIN_CHARS} to ${KEY_MAX_CHARS}`, { key: settingName, length: apiKey.length });
    }
    if (/replace-with|your-key|example/i.test(apiKey)) {
        throw configurationError(`${settingName} still holds the template placeholder -- put the key TypeSafe issued in ${configPath}`, { path: configPath });
    }
    return apiKey;
}
/** Reads the base URL as an https origin whose host the file also names in `TYPESAFE_ENDPOINT_HOST`. */
function readBaseURL(settings, endpointHost) {
    const settingName = "TYPESAFE_BASE_URL";
    const rawUrl = (readSetting(settings, settingName) ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    if (rawUrl.length > URL_MAX_CHARS) {
        throw configurationError(`${settingName} is ${rawUrl.length} characters -- a URL here is at most ${URL_MAX_CHARS}`, { key: settingName });
    }
    let url;
    try {
        url = new URL(rawUrl);
    }
    catch {
        throw configurationError(`${settingName} '${toDisplayValue(rawUrl)}' is not a URL -- give an origin, as ${DEFAULT_BASE_URL}`, { key: settingName });
    }
    if (url.protocol !== "https:") {
        throw configurationError(`${settingName} '${toDisplayValue(rawUrl)}' is ${url.protocol} -- the key is sent over https alone`, { key: settingName });
    }
    if (url.username !== "" || url.password !== "") {
        // Shown without the userinfo: a password in the file is a secret even where the file is wrong.
        throw configurationError(`${settingName} '${toDisplayValue(`${url.protocol}//***@${url.host}${url.pathname}`)}' carries a credential -- give the origin alone, as ${DEFAULT_BASE_URL}`, { key: settingName });
    }
    if (url.pathname !== "/" || url.search !== "" || url.hash !== "") {
        throw configurationError(`${settingName} '${toDisplayValue(rawUrl)}' carries a path, query or fragment -- give the origin alone, as ${DEFAULT_BASE_URL}`, { key: settingName });
    }
    if (url.hostname !== endpointHost) {
        throw configurationError(`${settingName} host '${url.hostname}' is not the declared endpoint host '${endpointHost}' -- the key is sent only to a host the file names twice`, { key: settingName });
    }
    return url.origin;
}
/**
 * Opens `configPath` without following a final symlink, checks the open descriptor -- a regular file, no other bits, under
 * the size bound -- and reads it whole. A FIFO does not block the open (O_NONBLOCK) and is refused on the type check.
 */
function readConfigFile(configPath) {
    // O_NOFOLLOW is absent on Windows, where every symlink check is the platform's own.
    const openFlags = constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0);
    let fileDescriptor;
    try {
        fileDescriptor = openSync(configPath, openFlags);
    }
    catch (error) {
        const errorCode = error instanceof Error && "code" in error ? String(error.code) : "unknown";
        if (errorCode === "ELOOP")
            throw configurationError(`configuration file ${configPath} is a symlink`, { path: configPath });
        throw configurationError(`configuration file ${configPath} is not readable (${errorCode})`, { path: configPath });
    }
    try {
        const fileStats = fstatSync(fileDescriptor);
        const permissionBits = fileStats.mode & 0o777;
        if (fileStats.isSymbolicLink())
            throw configurationError(`configuration file ${configPath} is a symlink`, { path: configPath });
        if (!fileStats.isFile())
            throw configurationError(`configuration file ${configPath} is not a regular file`, { path: configPath });
        // The other bits alone are refused. A group bit is not read: on a file under a claimed project the group
        // class shows the ACL mask, which the collaborative tree sets to rwx by design, and the group is the account
        // that runs the command, which already reads the key -- a group write there does not widen access.
        if (permissionBits & 0o004)
            throw configurationError(`configuration file ${configPath} is world-readable -- it holds a credential; chmod o-r`, { path: configPath, mode: permissionBits.toString(8) });
        if (permissionBits & 0o002)
            throw configurationError(`configuration file ${configPath} is world-writable -- chmod o-w`, { path: configPath, mode: permissionBits.toString(8) });
        if (fileStats.size > MAX_CONFIG_BYTES) {
            throw configurationError(`configuration file ${configPath} is ${fileStats.size} bytes -- a configuration is at most ${MAX_CONFIG_BYTES}`, { path: configPath, size: fileStats.size });
        }
        // Read through the same descriptor, one byte past the bound: a file that grew since the stat is refused too.
        const buffer = Buffer.alloc(MAX_CONFIG_BYTES + 1);
        let bytesRead = 0;
        for (;;) {
            const chunkBytes = readSync(fileDescriptor, buffer, bytesRead, buffer.length - bytesRead, null);
            if (chunkBytes === 0)
                break;
            bytesRead += chunkBytes;
            if (bytesRead > MAX_CONFIG_BYTES) {
                throw configurationError(`configuration file ${configPath} is over ${MAX_CONFIG_BYTES} bytes -- a configuration is at most ${MAX_CONFIG_BYTES}`, { path: configPath });
            }
        }
        return buffer.toString("utf8", 0, bytesRead);
    }
    finally {
        closeSync(fileDescriptor);
    }
}
/** Reads and validates the configuration file at `configPath`; every refusal is a configuration error naming the cause. */
export function readConfig(configPath) {
    const settings = parseKeyValue(readConfigFile(configPath));
    const apiKey = readApiKey(settings, configPath);
    const endpointHost = readHostname(settings, "TYPESAFE_ENDPOINT_HOST", DEFAULT_ENDPOINT_HOST);
    const baseURL = readBaseURL(settings, endpointHost);
    const model = readSetting(settings, "TYPESAFE_MODEL") ?? DEFAULT_MODEL;
    if (!isModelName(model)) {
        throw configurationError(`TYPESAFE_MODEL '${toDisplayValue(model)}' is not a model id -- give a versioned name, as ${DEFAULT_MODEL}`, { key: "TYPESAFE_MODEL" });
    }
    return {
        apiKey,
        baseURL,
        endpointHost,
        model,
        threshold: readProbability(settings, "TYPESAFE_THRESHOLD", DEFAULT_THRESHOLD),
        uncertainBand: readUncertainBand(settings, DEFAULT_UNCERTAIN_BAND),
        timeoutMs: readTimeoutMs(settings, DEFAULT_TIMEOUT_MS),
    };
}
