#!/usr/bin/env node
import { createBackend } from "../../core/src/index.mjs";

const backend = createBackend({
  id: "go",
  extensions: ['go'],
  markers: ['go.mod'],

});

backend.main();
