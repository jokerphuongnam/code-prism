#!/usr/bin/env node
import { createBackend } from "../../core/src/index.mjs";

const backend = createBackend({
  id: "cpp",
  extensions: ['c', 'cc', 'cpp', 'cxx', 'h', 'hh', 'hpp', 'hxx'],
  markers: ['CMakeLists.txt', 'compile_commands.json'],

});

backend.main();
