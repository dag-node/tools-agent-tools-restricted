// SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
// SPDX-License-Identifier: MIT
// src/validation.mts
// The value checks more than one module applies: config.mts to what an operator writes, transport.mts to what the
// provider sends back, core.mts to the projected answer, decide.mts to the command line. Each rule is stated once,
// so a model name config.mts accepts is the model name transport.mts admits.
/** A model id is at most this long wherever it is read. */
const MODEL_NAME_MAX_CHARS = 128;
/** A model id as the vendor spells one: a letter or digit, then letters, digits, dot, underscore or dash. */
const MODEL_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
/** A plain object: not null and not an array. */
export const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
/** A finite number in [0, 1]. */
export const isProbability = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
/** An integer of 0 or more. */
export const isNonNegativeInteger = (value) => typeof value === "number" && Number.isInteger(value) && value >= 0;
/** A model id in the vendor's spelling, at most MODEL_NAME_MAX_CHARS long. */
export const isModelName = (value) => typeof value === "string" && value.length <= MODEL_NAME_MAX_CHARS && MODEL_NAME_PATTERN.test(value);
