// SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
// SPDX-License-Identifier: MIT
// src/errors.mts
// Every failure the decide command reports, as one class carrying a code, so the caller (an agent reading stderr,
// a test reading the exit status) tells a configuration refusal from a provider error from a malformed answer
// without parsing prose. The code decides the exit status; the message is for the reader.
//
// A message may quote what it refused -- a line of the listing, a snippet of a provider body -- and that text is
// untrusted. `describe` therefore renders the whole line through `oneLine`, so nothing a message carries can add a
// second line to stderr or style the terminal, whatever the caller of a constructor put in it.
/** `text` with every control character (C0, DEL, C1) and Unicode line separator replaced by a space. */
export const oneLine = (text) => text.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ");
/** The failure classes, each with the exit status it maps to. */
export const ErrorCode = {
    /** The command line or the stdin listing is unusable (empty, over a bound, a bad id). */
    input: "input",
    /** The integration is not enabled in this session, or its configuration file is missing or invalid. */
    configuration: "configuration",
    /** The provider answered with an error status, or could not be reached. */
    provider: "provider",
    /** The provider answered 2xx with a body that does not hold the documented answer shape. */
    contract: "contract",
    /** The invocation's deadline passed, or the caller cancelled it. */
    deadline: "deadline",
};
/** Exit statuses by code. 1 is reserved for an unexpected exception, 0 for success. */
export const EXIT_STATUS = {
    input: 2,
    configuration: 3,
    provider: 4,
    contract: 5,
    deadline: 6,
};
export class DecideError extends Error {
    code;
    /** Machine-readable detail beside the message: an HTTP status, a request id, the contract problems. */
    detail;
    constructor(code, message, detail = {}, options) {
        super(message, options);
        this.name = "DecideError";
        this.code = code;
        this.detail = detail;
    }
    get exitStatus() {
        return EXIT_STATUS[this.code];
    }
    /**
     * One stderr line: `decide: <code>: <message> [key=value ...]`, with no body content beyond what detail names,
     * and no control character however the message or a detail came by one.
     */
    describe() {
        const detailText = Object.entries(this.detail)
            .map(([key, value]) => `${key}=${Array.isArray(value) ? value.join(";") : String(value)}`)
            .join(" ");
        return oneLine(`decide: ${this.code}: ${this.message}${detailText === "" ? "" : ` [${detailText}]`}`);
    }
}
export const inputError = (message, detail) => new DecideError(ErrorCode.input, message, detail);
export const configurationError = (message, detail) => new DecideError(ErrorCode.configuration, message, detail);
