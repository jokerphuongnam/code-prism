#!/usr/bin/env node
import { createBackend } from "../../core/src/index.mjs";

const backend = createBackend({
  id: "kotlin",
  extensions: ['kt', 'kts'],
  markers: ['build.gradle.kts', 'build.gradle'],

});

backend.main();
