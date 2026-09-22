#!/usr/bin/env node
import { createBackend } from "../../core/src/index.mjs";

const backend = createBackend({
  id: "js",
  extensions: ['js', 'jsx', 'ts', 'tsx', 'mjs', 'cjs'],
  markers: ['package.json', 'tsconfig.json'],

});

backend.main();
