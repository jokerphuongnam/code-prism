#!/usr/bin/env node
import { createBackend } from "../../core/src/index.mjs";

const backend = createBackend({
  id: "rust",
  extensions: ['rs'],
  markers: ['Cargo.toml'],

});

backend.main();
