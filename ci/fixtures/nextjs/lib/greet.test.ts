import { test } from "node:test";
import assert from "node:assert/strict";
import { greet } from "./greet.ts";

test("greets by name", () => {
  assert.equal(greet("koorikla"), "hello, koorikla");
});

test("defaults to world", () => {
  assert.equal(greet(), "hello, world");
});
