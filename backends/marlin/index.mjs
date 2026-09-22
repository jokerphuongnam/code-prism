#!/usr/bin/env node
import { createBackend } from "../../core/src/index.mjs";

const backend = createBackend({
  id: "marlin",
  extensions: ['marlin'],
  markers: ['Application.marlin'],

});

backend.main();
