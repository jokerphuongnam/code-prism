#!/usr/bin/env node
import { createBackend } from "../../core/src/index.mjs";

const backend = createBackend({
  id: "objc",
  extensions: ['m', 'mm', 'h'],
  markers: [],
  cacheFolder: "objective-c-prism",
});

backend.main();
