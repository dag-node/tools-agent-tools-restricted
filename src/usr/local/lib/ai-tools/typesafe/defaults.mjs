// SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
// SPDX-License-Identifier: MIT
// src/defaults.mts
// The values the configuration file overrides, gathered in one module so what an operator may change is one file
// rather than a search. Each one is the fallback for the key named beside it, and config.mts states the form that
// key accepts.
//
// The request bounds are NOT here. They are a consistent set -- the chunk size, the item cut and the state budget
// are chosen against each other and against what the provider documents -- so they live in core.mts with the code
// that reads them, and changing one alone can produce a request the provider refuses.
/** TYPESAFE_BASE_URL -- the API origin, https, no path. */
export const DEFAULT_BASE_URL = "https://api.typesafe.ai";
/** TYPESAFE_ENDPOINT_HOST -- the host the base URL must resolve to, named twice so a typo cannot redirect the key. */
export const DEFAULT_ENDPOINT_HOST = "api.typesafe.ai";
/** TYPESAFE_MODEL -- a versioned model, not the moving alias: the vendor documents that `jev-latest` changes
 * answers on a release. */
export const DEFAULT_MODEL = "jev-1.13.0";
/** TYPESAFE_THRESHOLD -- the least P(true) that keeps an item. */
export const DEFAULT_THRESHOLD = 0.5;
/** TYPESAFE_UNCERTAIN_BAND -- the inclusive band of P(true) reported as uncertain beside the kept set. */
export const DEFAULT_UNCERTAIN_BAND = [0.35, 0.65];
/** TYPESAFE_TIMEOUT_MS -- one attempt. Sized under core.mts's total budget, which bounds a whole invocation. */
export const DEFAULT_TIMEOUT_MS = 15_000;
